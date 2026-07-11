# frozen_string_literal: true

require "set"

module Placet
  # action パターンのマッチング（concept.md 3.3: セグメント単位で literal か *）
  module ActionMatch
    def self.match?(pattern, action)
      return true if pattern == "*"

      p_res, p_op = pattern.split(":", 2)
      a_res, a_op = action.split(":", 2)
      (p_res == "*" || p_res == a_res) && (p_op == "*" || p_op == a_op)
    end
  end

  # 一覧フィルタリングの集合演算の計画（concept.md 8.4 / spec/conformance/README.md）。
  # ORM アダプタはこの plan を WHERE 句へ写像する
  ScopePlan = Struct.new(:kind, :include_relations, :exclude_relations, keyword_init: true)

  # コア評価エンジン（PDP）。純粋関数として動作し、適合性テストの対象となる。
  # 入力は principal 文字列の配列のみで、derive の由来（via）などランタイム層の
  # 拡張は関知しない
  class Engine
    def initialize(definition, registry: nil)
      @definition = definition
      @registry = registry
      @grant_cache = {}
      @match_cache = {}
      @valid_actions = Set.new
    end

    def decide(principals, action)
      validate_action!(action)
      matches = matches_for(action)

      matched = []
      principals.each do |principal|
        @definition.attachments.fetch(principal, []).each do |policy_name|
          matches.fetch(policy_name, []).each do |index, effect|
            matched << Determinant.new(principal: principal, policy: policy_name,
                                       statement: index, effect: effect)
          end
        end
      end

      denies, allows = matched.partition { |m| m.effect == "deny" }
      return Decision.new(decision: :deny, basis: :explicit_deny, determinants: denies) if denies.any?
      return Decision.new(decision: :permit, basis: :explicit_allow, determinants: allows) if allows.any?

      Decision.new(decision: :deny, basis: :implicit_deny, determinants: [])
    end

    # 一覧フィルタリングの計画を返す。
    # static_principals: 静的 principal（rel: を含まない導出結果）
    # relations: 対象モデルに定義された relation 名のリスト
    def scope_plan(static_principals, action, relations:)
      validate_action!(action)
      allow_ps, deny_ps = grants(action)
      static = static_principals.to_a

      if static.any? { |p| deny_ps.include?(p) }
        return ScopePlan.new(kind: "empty", include_relations: [], exclude_relations: [])
      end

      exclude = relations.select { |name| deny_ps.include?("rel:#{name}") }

      if static.any? { |p| allow_ps.include?(p) }
        return ScopePlan.new(kind: "all", include_relations: [], exclude_relations: exclude)
      end

      include_ = relations.select { |name| allow_ps.include?("rel:#{name}") }
      if include_.empty?
        ScopePlan.new(kind: "empty", include_relations: [], exclude_relations: [])
      else
        ScopePlan.new(kind: "union", include_relations: include_, exclude_relations: exclude)
      end
    end

    # action 検証の一元的な入口。決定要求・scope 合成の action は具体的
    # （ワイルドカード不可）かつレジストリ宣言済み（使用時）でなければならない。
    # typo は静かな全拒否 / 空 scope になるため即エラーにする。
    # 宣言時 fail-fast には error_class に DefinitionError を渡して使う
    def validate_action!(action, error_class: Error)
      return if @valid_actions.include?(action)

      unless action.is_a?(String) && action =~ CONCRETE_ACTION_RE
        raise error_class, "action は具体的でなければならない: #{action.inspect}"
      end
      unless @registry.nil? || @registry.known_action?(action)
        raise error_class, "未知の action: #{action}（レジストリに未宣言）"
      end

      @valid_actions << action
    end

    private

    # action ごとの「マッチ済み statement 索引」（policy 名 => [[index, effect]]）。
    # 定義は Engine 生成後に不変なのでキャッシュできる。decide の毎回の
    # 全 statement 走査と action 文字列の split 繰り返しを避ける
    def matches_for(action)
      @match_cache[action] ||= @definition.policies.each_with_object({}) do |(name, statements), out|
        hits = statements.each_with_index.filter_map do |st, index|
          [index, st.effect] if statement_matches?(st, action)
        end
        out[name] = hits unless hits.empty?
      end
    end

    def statement_matches?(statement, action)
      statement.actions.any? { |pattern| ActionMatch.match?(pattern, action) }
    end

    # action → allow / deny を与える principal 集合の逆引き（起動時コンパイル相当）
    def grants(action)
      @grant_cache[action] ||= begin
        allow = Set.new
        deny = Set.new
        @definition.attachments.each do |principal, names|
          names.each do |name|
            @definition.policies[name].each do |st|
              (st.effect == "deny" ? deny : allow) << principal if statement_matches?(st, action)
            end
          end
        end
        [allow, deny]
      end
    end
  end
end
