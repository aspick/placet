# frozen_string_literal: true

module Placet
  # モジュールレベルのランタイム API（docs/rails-usage.md）。
  # 定義（静的）と principal 導出（動的）をつなぎ、Engine に決定を委譲する
  class << self
    def definition = (@definition ||= Definition.new)
    def engine = (@engine ||= Engine.new(definition))

    def define(&block)
      DefinitionBuilder.new(definition).instance_eval(&block)
      definition.validate!
      @engine = nil
    end

    def resolver(&block) = @resolver = block

    def derive(type_pattern, &block)
      type = type_pattern.delete_suffix(":*").delete_suffix(":")
      (@derives ||= Hash.new { |h, k| h[k] = [] })[type] << block
    end

    def relation(name, resource:, &block)
      builder = RelationBuilder.new
      builder.instance_eval(&block)
      unless builder.check_block && builder.scope_block
        raise DefinitionError, "relation は check と scope をペアで宣言する: #{name}"
      end

      (@relations ||= Hash.new { |h, k| h[k] = [] })[resource] <<
        Relation.new(name: name.to_s, resource_class: resource,
                     check: builder.check_block, scope: builder.scope_block)
      @engine = nil
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
      out = expand_principals(Array(@resolver&.call(user)))
      if resource
        relations_for(resource.class).each do |rel|
          out["rel:#{rel.name}"] ||= [] if rel.check.call(user, resource)
        end
      end
      out
    end

    # 複数 action は AND（fail-fast）。docs/rails-usage.md 4.2
    def decide(user, actions, resource = nil)
      last = nil
      Array(actions).each do |action|
        last = engine.decide(principals_for(user, resource), action)
        return last unless last.permit?
      end
      last
    end

    def authorize!(user, actions, resource = nil)
      count_enforcement!
      Array(actions).each do |action|
        d = engine.decide(principals_for(user, resource), action)
        raise Denied.new(action, d) unless d.permit?
      end
      true
    end

    def permit?(user, actions, resource = nil) = decide(user, actions, resource).permit?

    # 一覧の scope 合成。Engine の plan を materialize_scope でコレクションへ写像する。
    # 既定はインメモリ配列で、ActiveRecord 等の ORM への写像はアダプタ gem が
    # materialize_scope を prepend で差し替えて提供する
    def scoped(user, action, model:)
      count_enforcement!
      rels = relations_for(model)
      plan = engine.scope_plan(principals_for(user).keys, action, relations: rels.map(&:name))
      materialize_scope(plan, rels, user, model)
    end

    # このスレッドで enforcement（authorize! / scoped）が行われた回数。
    # PEP ヘルパーの呼び忘れ検知（docs/rails-usage.md 4.4）が参照する
    def enforcements = Thread.current[:placet_enforcements] || 0

    # scope 合成の結果（通常は 1 ページ分）へ個体判定を再適用する二段構え。
    # check / scope に乖離バグがあっても「見えてはいけないものが見える」方向には
    # 倒れない（concept.md 11.5）。乖離レコードは on_recheck_divergence に通知して除外する
    def recheck(user, action, records)
      records.select do |record|
        next true if permit?(user, action, record)

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

    # テスト・再読み込み用: すべての定義と登録を破棄する
    def reset!
      @definition = nil
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

    def materialize_scope(plan, rels, user, model)
      excluded = rels.select { |r| plan.exclude_relations.include?(r.name) }
                     .flat_map { |r| r.scope.call(user) }
      case plan.kind
      when "empty" then []
      when "all"   then model.all.to_a - excluded
      else
        rels.select { |r| plan.include_relations.include?(r.name) }
            .flat_map { |r| r.scope.call(user) }.uniq - excluded
      end
    end
  end
end
