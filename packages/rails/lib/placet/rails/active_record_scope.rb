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
            scopes_for(plan.include_relations, relations, user)
              .map { |scope| model.where(pk => scope.select(pk)) }
              .reduce { |a, b| a.or(b) }
          end
        scopes_for(plan.exclude_relations, relations, user)
          .reduce(base) { |rel, scope| rel.where.not(pk => scope.select(pk)) }
      end

      def scopes_for(names, relations, user)
        relations.select { |r| names.include?(r.name) }.map { |r| r.scope.call(user) }
      end
    end

    # Placet.scoped の実体化を ActiveRecord モデルのときだけ差し替える
    module ScopedOverride
      private

      def materialize_scope(plan, rels, user, model)
        if defined?(ActiveRecord::Base) && model.is_a?(Class) && model <= ActiveRecord::Base
          ActiveRecordScope.compose(plan, rels, user, model)
        else
          super
        end
      end
    end
  end
end

Placet.singleton_class.prepend(Placet::Rails::ScopedOverride)
