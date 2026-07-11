# frozen_string_literal: true

require "set"

module Placet
  ACTION_PATTERN_RE  = /\A(\*|(\*|[a-z][a-z0-9_]*):(\*|[a-z][a-z0-9_]*))\z/
  CONCRETE_ACTION_RE = /\A[a-z][a-z0-9_]*:[a-z][a-z0-9_]*\z/
  PRINCIPAL_RE       = /\A[a-z][a-z0-9_-]*:[^\s*]+\z/
  POLICY_NAME_RE     = /\A[a-z][a-z0-9_-]*\z/

  Statement = Struct.new(:effect, :actions, keyword_init: true)

  # Policy 定義の保持と検証。正規形（spec/schema/policy-document.schema.json）と 1:1
  class Definition
    attr_reader :policies, :attachments

    def initialize
      @policies = {}                                # name => [Statement]
      @attachments = Hash.new { |h, k| h[k] = [] }  # principal => [policy names]
      @registry = nil                               # nil = action レジストリ未使用
    end

    # 正規形（JSON 互換 Hash）からの読み込み
    def self.from_canonical(doc)
      raise DefinitionError, "ドキュメントが Hash ではない" unless doc.is_a?(Hash)

      version = doc["version"] || doc[:version]
      raise DefinitionError, "未対応の version: #{version.inspect}" unless version == 1

      definition = new
      Array(doc["policies"] || doc[:policies]).each do |policy|
        statements = Array(policy["statements"]).map do |st|
          effect = st["effect"]
          raise DefinitionError, "effect が不正: #{effect.inspect}" unless %w[allow deny].include?(effect)

          Statement.new(effect: effect, actions: Array(st["actions"]))
        end
        definition.add_policy(policy["name"], statements)
      end
      Array(doc["attachments"] || doc[:attachments]).each do |attachment|
        definition.add_attachment(attachment["principal"], Array(attachment["policies"]))
      end
      definition.validate!
      definition
    end

    def add_actions(resource, operations)
      @registry ||= {}
      (@registry[resource] ||= Set.new).merge(operations)
    end

    def add_policy(name, statements)
      raise DefinitionError, "policy 名が不正: #{name.inspect}" unless name.is_a?(String) && name =~ POLICY_NAME_RE
      raise DefinitionError, "policy 名が重複: #{name}" if @policies.key?(name)
      raise DefinitionError, "statements が空: #{name}" if statements.empty?

      @policies[name] = statements
    end

    def add_attachment(principal, names)
      unless principal.is_a?(String) && principal =~ PRINCIPAL_RE
        raise DefinitionError, "principal が不正（type:id 形式・* 不可）: #{principal.inspect}"
      end

      @attachments[principal] |= names
    end

    def validate!
      @attachments.each do |principal, names|
        names.each do |name|
          unless @policies.key?(name)
            raise DefinitionError, "attachment が未定義の policy を参照: #{name} (principal: #{principal})"
          end
        end
      end
      @policies.each do |name, statements|
        statements.each { |st| st.actions.each { |pattern| validate_pattern!(pattern, name) } }
      end
      self
    end

    # action レジストリ照合（レジストリ未使用なら常に true）
    def known_action?(action)
      return true if @registry.nil?

      resource, operation = action.split(":", 2)
      @registry.key?(resource) && @registry[resource].include?(operation)
    end

    def to_canonical
      {
        "version" => 1,
        "policies" => @policies.map do |name, statements|
          { "name" => name,
            "statements" => statements.map { |s| { "effect" => s.effect, "actions" => s.actions } } }
        end,
        "attachments" => @attachments.map do |principal, names|
          { "principal" => principal, "policies" => names }
        end
      }
    end

    private

    def validate_pattern!(pattern, policy_name)
      unless pattern.is_a?(String) && pattern =~ ACTION_PATTERN_RE
        raise DefinitionError, "action パターンが不正: #{pattern.inspect} (policy: #{policy_name})"
      end
      return if @registry.nil? || pattern == "*"

      resource, operation = pattern.split(":", 2)
      if resource != "*" && !@registry.key?(resource)
        raise DefinitionError, "未知のリソース: #{pattern} (policy: #{policy_name})"
      end
      if operation != "*"
        known =
          if resource == "*"
            @registry.values.any? { |ops| ops.include?(operation) }
          else
            @registry[resource].include?(operation)
          end
        raise DefinitionError, "未知の action: #{pattern} (policy: #{policy_name})" unless known
      end
    end
  end
end
