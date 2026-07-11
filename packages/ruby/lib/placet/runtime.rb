# frozen_string_literal: true

module Placet
  # モジュールレベルのランタイム API（docs/rails-usage.md）。
  # 定義（静的）と principal 導出（動的）をつなぎ、Engine に決定を委譲する
  class << self
    def definition = (@definition ||= Definition.new)
    def registry = (@registry ||= ActionRegistry.new)
    def engine = (@engine ||= Engine.new(definition, registry: registry))

    def define(&block)
      DefinitionBuilder.new(definition, registry).instance_eval(&block)
      definition.validate!(registry)
      @engine = nil
    end

    def resolver(&block) = @resolver = block

    def derive(type_pattern, &block)
      type = type_pattern.delete_suffix(":*").delete_suffix(":")
      ((@derives ||= {})[type] ||= []) << block
    end

    def relation(name, resource:, &block)
      builder = RelationBuilder.new
      builder.instance_eval(&block)
      unless builder.check_block && builder.scope_block
        raise DefinitionError, "relation は check と scope をペアで宣言する: #{name}"
      end

      ((@relations ||= {})[resource] ||= []) <<
        Relation.new(name: name.to_s, check: builder.check_block, scope: builder.scope_block)
    end

    # 与えられた principal 集合に derive の 1 段展開を適用する。
    # 戻り値は { principal => 由来の連鎖 (Array) }
    def expand_principals(base)
      out = {}
      base.each { |p| out[p] = [] }
      base.each do |p|
        type, id = p.split(":", 2)
        derive_hooks(type).each do |hook|
          Array(hook.call(id)).each { |derived| out[derived] ||= [p] }
        end
      end
      out
    end

    # principal 集合の導出。戻り値は { principal => 由来の連鎖 (Array) }
    def principals_for(user, resource = nil)
      with_relation_principals(expand_principals(Array(@resolver&.call(user))), user, resource)
    end

    # 複数 action は AND（fail-fast）。docs/rails-usage.md 4.2
    def decide(user, actions, resource = nil)
      last = nil
      decide_each(user, actions, resource) do |_action, decision|
        last = decision
        return decision unless decision.permit?
      end
      last
    end

    def authorize!(user, actions, resource = nil)
      count_enforcement!
      decide_each(user, actions, resource) do |action, decision|
        raise Denied.new(action, decision) unless decision.permit?
      end
      true
    end

    def permit?(user, actions, resource = nil) = decide(user, actions, resource).permit?

    # 由来つきの principal 集合（Hash）で判定し、determinants に由来（via）を付与する。
    # Engine は仕様どおり principal の配列のみを受けるため、via の装飾はこの層で行う
    def decide_with_provenance(principals, action)
      decision = engine.decide(principals.keys, action)
      decision.determinants.each do |determinant|
        via = principals[determinant.principal]
        determinant.via = via unless via.nil? || via.empty?
      end
      decision
    end

    # action 検証の公開入口（Engine に委譲）。アダプタの宣言時 fail-fast にも使う
    def validate_action!(action, error_class: Error)
      engine.validate_action!(action, error_class: error_class)
    end

    # 一覧の scope 合成。Engine の plan を、登録された materializer（ORM アダプタ）
    # またはインメモリの既定実装でコレクションへ写像する
    def scoped(user, action, model:)
      count_enforcement!
      rels = relations_for(model)
      plan = engine.scope_plan(principals_for(user).keys, action, relations: rels.map(&:name))
      materializer_for(model).call(plan, rels, user, model)
    end

    # ORM アダプタが ScopePlan の実体化を登録する。matcher が true を返した
    # model に materializer が適用される（後着優先。どれにもマッチしなければ
    # インメモリの既定実装）。定義状態とは独立した登録なので reset! では消えない
    def register_scope_materializer(matcher, materializer)
      (@scope_materializers ||= []).unshift([matcher, materializer])
    end

    # relation 名の集合を scope 呼び出し結果へ写像する共通ヘルパー
    # （インメモリ実装と ORM アダプタで共有）
    def relation_scopes(relations, names, user)
      relations.select { |r| names.include?(r.name) }.map { |r| r.scope.call(user) }
    end

    # このスレッドで enforcement（authorize! / scoped）が行われた回数。
    # PEP ヘルパーの呼び忘れ検知（docs/rails-usage.md 4.4）が参照する
    def enforcements = Thread.current[:placet_enforcements] || 0

    # scope 合成の結果（通常は 1 ページ分）へ個体判定を再適用する二段構え。
    # check / scope に乖離バグがあっても「見えてはいけないものが見える」方向には
    # 倒れない（concept.md 11.5）。乖離レコードは on_recheck_divergence に通知して除外する。
    # 静的 principal の導出（resolver + derive）はレコードに依存しないため 1 回だけ行う
    def recheck(user, action, records)
      base = expand_principals(Array(@resolver&.call(user)))
      records.select do |record|
        principals = with_relation_principals(base, user, record)
        next true if engine.decide(principals.keys, action).permit?

        if (handler = @on_recheck_divergence)
          handler.call(user, action, record)
        else
          warn "placet: scope と check の乖離を検出: action=#{action} record=#{record.inspect}"
        end
        false
      end
    end

    # 乖離検出時のハンドラ（user, action, record を受け取る）。既定は警告出力
    attr_accessor :on_recheck_divergence

    def export = definition.to_canonical

    # テスト・再読み込み用: 定義と登録を破棄する（materializer は定義状態ではないため対象外）
    def reset!
      @definition = nil
      @registry = nil
      @engine = nil
      @resolver = nil
      @derives = nil
      @relations = nil
      @on_recheck_divergence = nil
    end

    # モデルに登録された relation の一覧（テストヘルパー・アダプタが参照する）
    def relations_for(klass) = @relations ? @relations.fetch(klass, []) : []

    private

    def derive_hooks(type) = @derives ? @derives.fetch(type, []) : []
    def count_enforcement! = Thread.current[:placet_enforcements] = enforcements + 1

    # principals_for / decide / authorize! で共有する評価ループ。
    # principal 導出は action に依存しないため、複数 action の AND でも 1 回で済ませる
    def decide_each(user, actions, resource)
      principals = principals_for(user, resource)
      Array(actions).each do |action|
        yield action, decide_with_provenance(principals, action)
      end
    end

    # 由来つき principal 集合（base）に、resource との関係の面を追加する
    def with_relation_principals(base, user, resource)
      return base unless resource

      out = base.dup
      relations_for(resource.class).each do |rel|
        out["rel:#{rel.name}"] ||= [] if rel.check.call(user, resource)
      end
      out
    end

    def materializer_for(model)
      (@scope_materializers || []).each do |matcher, materializer|
        return materializer if matcher.call(model)
      end
      method(:materialize_in_memory)
    end

    # 既定の実体化: インメモリコレクション（Array）に対する集合演算
    def materialize_in_memory(plan, rels, user, model)
      excluded = relation_scopes(rels, plan.exclude_relations, user).flatten(1)
      case plan.kind
      when "empty" then []
      when "all"   then model.all.to_a - excluded
      else
        relation_scopes(rels, plan.include_relations, user).flatten(1).uniq - excluded
      end
    end
  end
end
