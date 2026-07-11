# frozen_string_literal: true

module Placet
  module Rails
    # ScopePlan → ActiveRecord::Relation の写像（concept.md 8.4 の集合演算を SQL に落とす）。
    # relation の scope 同士の構造差（joins の有無など）に依存しないよう、
    # 和集合・差集合は主キーのサブクエリとして合成する
    module ActiveRecordScope
      module_function

      def compose(plan, relations, user, model)
        return model.none if plan.kind == "empty"

        pk = model.primary_key
        base =
          if plan.kind == "all"
            model.all
          else
            Placet.relation_scopes(relations, plan.include_relations, user)
                  .map { |scope| model.where(pk => scope.select(pk)) }
                  .reduce { |a, b| a.or(b) }
          end
        Placet.relation_scopes(relations, plan.exclude_relations, user)
              .reduce(base) { |rel, scope| rel.where.not(pk => scope.select(pk)) }
      end
    end
  end
end

# ActiveRecord モデルに対する ScopePlan の実体化として登録する
Placet.register_scope_materializer(
  ->(model) { defined?(ActiveRecord::Base) && model.is_a?(Class) && model <= ActiveRecord::Base },
  Placet::Rails::ActiveRecordScope.method(:compose)
)
