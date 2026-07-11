# frozen_string_literal: true

module Placet
  # Ruby DSL（docs/rails-usage.md 2.2）。評価結果は正規形と等価な Definition になる
  class PolicyBuilder
    attr_reader :statements

    def initialize = @statements = []
    def allow(*actions) = @statements << Statement.new(effect: "allow", actions: actions.flatten)
    def deny(*actions)  = @statements << Statement.new(effect: "deny",  actions: actions.flatten)
  end

  class DefinitionBuilder
    def initialize(definition, registry)
      @definition = definition
      @registry = registry
    end

    def actions(resource, operations) = @registry.add(resource, operations)

    def policy(name, attach_to: nil, &block)
      builder = PolicyBuilder.new
      builder.instance_eval(&block)
      @definition.add_policy(name, builder.statements)
      Array(attach_to).each { |principal| @definition.add_attachment(principal, [name]) }
    end

    def attach(principal, *names) = @definition.add_attachment(principal, names.flatten)
  end

  # relation は check（個体判定）と scope（一覧用の逆写像）を必ずペアで宣言する
  Relation = Struct.new(:name, :check, :scope, keyword_init: true)

  class RelationBuilder
    attr_reader :check_block, :scope_block

    def check(&block) = @check_block = block
    def scope(&block) = @scope_block = block
  end
end
