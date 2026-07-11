# frozen_string_literal: true

require "set"

# ============================================================================
# placet 簡易ランタイム（プロトタイプ）
#
# docs/rails-usage.md で設計した将来の public API と同じ形を、インメモリで
# 動く最小実装として提供する。本実装（packages/ruby）が完成したら、この
# ファイルへの require を gem に差し替えるだけでサンプルアプリが動くことを
# 意図している。
#
# 実装しているもの:
#   - Placet.define: policy / allow / deny / attach / attach_to: / actions
#   - 意味的検証（policy 名の一意性・参照整合性・記法・action レジストリ）
#   - Placet.resolver / Placet.derive（1 段展開・由来記録）/ Placet.relation
#   - Placet.decide / authorize! / permit?（deny-overrides・根拠つき決定・AND）
#   - Placet.scoped（scope 合成: 静的 deny → 空 / 静的 allow → 全件 /
#     rel scope の和集合 − deny scope。concept.md 8.4）
#   - Placet.export（コンパイル済み正規形の出力）
# ============================================================================

module Placet
  ACTION_PATTERN_RE  = /\A(\*|(\*|[a-z][a-z0-9_]*):(\*|[a-z][a-z0-9_]*))\z/
  CONCRETE_ACTION_RE = /\A[a-z][a-z0-9_]*:[a-z][a-z0-9_]*\z/
  PRINCIPAL_RE       = /\A[a-z][a-z0-9_-]*:[^\s*]+\z/
  POLICY_NAME_RE     = /\A[a-z][a-z0-9_-]*\z/

  class Error < StandardError; end
  class DefinitionError < Error; end

  class Denied < Error
    attr_reader :action, :decision

    def initialize(action, decision)
      @action = action
      @decision = decision
      super("denied: #{action} (#{decision.basis})")
    end
  end

  Determinant = Struct.new(:principal, :policy, :statement, :effect, :via, keyword_init: true) do
    def to_h = super.compact
  end

  Decision = Struct.new(:decision, :basis, :determinants, keyword_init: true) do
    def permit? = decision == :permit
    def to_h = { decision: decision, basis: basis, determinants: determinants.map(&:to_h) }
  end

  Statement = Struct.new(:effect, :actions, keyword_init: true)
  Relation  = Struct.new(:name, :resource_class, :check, :scope, keyword_init: true)

  # action パターンのマッチング（concept.md 3.3: セグメント単位で literal か *）
  module ActionMatch
    def self.match?(pattern, action)
      return true if pattern == "*"

      p_res, p_op = pattern.split(":", 2)
      a_res, a_op = action.split(":", 2)
      (p_res == "*" || p_res == a_res) && (p_op == "*" || p_op == a_op)
    end
  end

  # 定義の保持と検証。正規形（spec/schema/policy-document.schema.json）と 1:1
  class Definition
    attr_reader :policies, :attachments

    def initialize
      @policies = {}                                # name => [Statement]
      @attachments = Hash.new { |h, k| h[k] = [] }  # principal => [policy names]
      @registry = nil                               # nil = action レジストリ未使用
    end

    def add_actions(resource, operations)
      @registry ||= {}
      (@registry[resource] ||= Set.new).merge(operations)
    end

    def add_policy(name, statements)
      raise DefinitionError, "policy 名が不正: #{name}" unless name =~ POLICY_NAME_RE
      raise DefinitionError, "policy 名が重複: #{name}" if @policies.key?(name)
      raise DefinitionError, "statements が空: #{name}" if statements.empty?

      @policies[name] = statements
    end

    def add_attachment(principal, names)
      raise DefinitionError, "principal が不正（type:id 形式・* 不可）: #{principal}" unless principal =~ PRINCIPAL_RE

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
    end

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
      unless pattern =~ ACTION_PATTERN_RE
        raise DefinitionError, "action パターンが不正: #{pattern} (policy: #{policy_name})"
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

  # --- DSL ---
  class PolicyBuilder
    attr_reader :statements

    def initialize = @statements = []
    def allow(*actions) = @statements << Statement.new(effect: "allow", actions: actions.flatten)
    def deny(*actions)  = @statements << Statement.new(effect: "deny",  actions: actions.flatten)
  end

  class DefinitionBuilder
    def initialize(definition) = @definition = definition

    def actions(resource, operations) = @definition.add_actions(resource, operations)

    def policy(name, attach_to: nil, &block)
      builder = PolicyBuilder.new
      builder.instance_eval(&block)
      @definition.add_policy(name, builder.statements)
      Array(attach_to).each { |principal| @definition.add_attachment(principal, [name]) }
    end

    def attach(principal, *names) = @definition.add_attachment(principal, names.flatten)
  end

  class RelationBuilder
    attr_reader :check_block, :scope_block

    def check(&block) = @check_block = block
    def scope(&block) = @scope_block = block
  end

  class << self
    def definition = (@definition ||= Definition.new)

    def define(&block)
      DefinitionBuilder.new(definition).instance_eval(&block)
      definition.validate!
      @grant_cache = {}
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
      @grant_cache = {}
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
        last = decide_one(user, action, resource)
        return last unless last.permit?
      end
      last
    end

    def authorize!(user, actions, resource = nil)
      Array(actions).each do |action|
        d = decide_one(user, action, resource)
        raise Denied.new(action, d) unless d.permit?
      end
      true
    end

    def permit?(user, actions, resource = nil) = decide(user, actions, resource).permit?

    # 一覧の scope 合成（concept.md 8.4）
    def scoped(user, action, model:)
      allow_ps, deny_ps = principals_granting(action)
      static = principals_for(user).keys
      return [] if static.any? { |p| deny_ps.include?(p) }   # 1. 静的 deny → 空集合

      rels = relations_for(model)
      denied = rels.select { |r| deny_ps.include?("rel:#{r.name}") }
                   .flat_map { |r| r.scope.call(user) }
      base =
        if static.any? { |p| allow_ps.include?(p) }          # 2. 静的 allow → 全件
          model.all.to_a
        else                                                 # 3. allow 元 rel scope の和集合
          rels.select { |r| allow_ps.include?("rel:#{r.name}") }
              .flat_map { |r| r.scope.call(user) }.uniq
        end
      base - denied                                          # 4. deny 元 rel scope の差し引き
    end

    def export = definition.to_canonical

    private

    def derive_hooks(type) = @derives ? @derives.fetch(type, []) : []
    def relations_for(klass) = @relations ? @relations.fetch(klass, []) : []

    def decide_one(user, action, resource)
      unless action =~ CONCRETE_ACTION_RE
        raise ArgumentError, "決定要求の action は具体的でなければならない: #{action}"
      end
      unless definition.known_action?(action)
        raise Error, "未知の action: #{action}（レジストリに未宣言）"
      end

      matched = []
      principals_for(user, resource).each do |principal, via|
        definition.attachments.fetch(principal, []).each do |policy_name|
          definition.policies[policy_name].each_with_index do |st, index|
            next unless st.actions.any? { |pattern| ActionMatch.match?(pattern, action) }

            matched << Determinant.new(principal: principal, policy: policy_name, statement: index,
                                       effect: st.effect, via: via.empty? ? nil : via)
          end
        end
      end

      denies = matched.select { |m| m.effect == "deny" }
      return Decision.new(decision: :deny, basis: :explicit_deny, determinants: denies) if denies.any?

      allows = matched.select { |m| m.effect == "allow" }
      return Decision.new(decision: :permit, basis: :explicit_allow, determinants: allows) if allows.any?

      Decision.new(decision: :deny, basis: :implicit_deny, determinants: [])
    end

    # action → allow / deny を与える principal 集合の逆引き（起動時コンパイル相当）
    def principals_granting(action)
      @grant_cache ||= {}
      @grant_cache[action] ||= begin
        allow = Set.new
        deny = Set.new
        definition.attachments.each do |principal, names|
          names.each do |name|
            definition.policies[name].each do |st|
              next unless st.actions.any? { |pattern| ActionMatch.match?(pattern, action) }

              (st.effect == "deny" ? deny : allow) << principal
            end
          end
        end
        [allow, deny]
      end
    end
  end
end
