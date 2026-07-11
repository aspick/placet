# frozen_string_literal: true

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
      @policies = {}     # name => [Statement]
      @attachments = {}  # principal => [policy names]
    end

    # 正規形（JSON 互換 Hash・文字列キー）からの読み込み
    def self.from_canonical(doc)
      raise DefinitionError, "ドキュメントが Hash ではない" unless doc.is_a?(Hash)

      version = doc["version"]
      raise DefinitionError, "未対応の version: #{version.inspect}" unless version == 1

      definition = new
      Array(doc["policies"]).each do |policy|
        statements = Array(policy["statements"]).map do |st|
          effect = st["effect"]
          raise DefinitionError, "effect が不正: #{effect.inspect}" unless %w[allow deny].include?(effect)

          Statement.new(effect: effect, actions: Array(st["actions"]))
        end
        definition.add_policy(policy["name"], statements)
      end
      Array(doc["attachments"]).each do |attachment|
        definition.add_attachment(attachment["principal"], Array(attachment["policies"]))
      end
      definition.validate!
      definition
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

      @attachments[principal] = (@attachments[principal] || []) | names
    end

    # registry を渡すと、action パターンのレジストリ照合（lint）もあわせて行う
    def validate!(registry = nil)
      @attachments.each do |principal, names|
        names.each do |name|
          unless @policies.key?(name)
            raise DefinitionError, "attachment が未定義の policy を参照: #{name} (principal: #{principal})"
          end
        end
      end
      @policies.each do |name, statements|
        statements.each { |st| st.actions.each { |pattern| validate_pattern!(pattern, name, registry) } }
      end
      self
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

    def validate_pattern!(pattern, policy_name, registry)
      unless pattern.is_a?(String) && pattern =~ ACTION_PATTERN_RE
        raise DefinitionError, "action パターンが不正: #{pattern.inspect} (policy: #{policy_name})"
      end
      return if registry.nil? || registry.known_pattern?(pattern)

      raise DefinitionError, "未知の action: #{pattern} (policy: #{policy_name})"
    end
  end
end
