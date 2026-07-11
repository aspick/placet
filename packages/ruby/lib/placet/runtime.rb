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

    # principal 集合の導出。戻り値は { principal => 由来の連鎖 (Array) }
    def principals_for(user, resource = nil)
      base = Array(@resolver&.call(user))
      out = {}
      base.each { |p| out[p] = [] }
      base.each do |p|                                       # derive の展開は 1 段のみ
        type, id = p.split(":", 2)
        derive_hooks(type).each do |hook|
          Array(hook.call(id)).each { |derived| out[derived] ||= [p] }
        end
      end
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
      Array(actions).each do |action|
        d = engine.decide(principals_for(user, resource), action)
        raise Denied.new(action, d) unless d.permit?
      end
      true
    end

    def permit?(user, actions, resource = nil) = decide(user, actions, resource).permit?

    # 一覧の scope 合成。Engine の plan をインメモリコレクションへ写像する
    # （ActiveRecord 等の ORM への写像はアダプタ gem の責務）
    def scoped(user, action, model:)
      rels = relations_for(model)
      plan = engine.scope_plan(principals_for(user).keys, action, relations: rels.map(&:name))
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

    def export = definition.to_canonical

    # テスト・再読み込み用: すべての定義と登録を破棄する
    def reset!
      @definition = nil
      @engine = nil
      @resolver = nil
      @derives = nil
      @relations = nil
    end

    private

    def derive_hooks(type) = @derives ? @derives.fetch(type, []) : []
    def relations_for(klass) = @relations ? @relations.fetch(klass, []) : []
  end
end
