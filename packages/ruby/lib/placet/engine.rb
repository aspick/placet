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

  # コア評価エンジン（PDP）。純粋関数として動作し、適合性テストの対象となる
  class Engine
    def initialize(definition)
      @definition = definition
      @grant_cache = {}
    end

    # principals: Array<String> または Hash{principal => via 連鎖}
    def decide(principals, action)
      validate_action!(action)
      principals = principals.to_h { |p| [p, []] } unless principals.is_a?(Hash)

      matched = []
      principals.each do |principal, via|
        @definition.attachments.fetch(principal, []).each do |policy_name|
          @definition.policies[policy_name].each_with_index do |st, index|
            next unless st.actions.any? { |pattern| ActionMatch.match?(pattern, action) }

            matched << Determinant.new(principal: principal, policy: policy_name, statement: index,
                                       effect: st.effect, via: via.nil? || via.empty? ? nil : via)
          end
        end
      end

      denies = matched.select { |m| m.effect == "deny" }
      return Decision.new(decision: :deny, basis: :explicit_deny, determinants: denies) if denies.any?

      allows = matched.select { |m| m.effect == "allow" }
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

    private

    # 決定要求・scope 合成の action は具体的（ワイルドカード不可）かつ
    # レジストリ宣言済み（使用時）でなければならない。typo は静かな全拒否 /
    # 空 scope になるため、ここで即エラーにする
    def validate_action!(action)
      unless action.is_a?(String) && action =~ CONCRETE_ACTION_RE
        raise ArgumentError, "決定要求の action は具体的でなければならない: #{action.inspect}"
      end
      unless @definition.known_action?(action)
        raise Error, "未知の action: #{action}（レジストリに未宣言）"
      end
    end

    # action → allow / deny を与える principal 集合の逆引き（起動時コンパイル相当）
    def grants(action)
      @grant_cache[action] ||= begin
        allow = Set.new
        deny = Set.new
        @definition.attachments.each do |principal, names|
          names.each do |name|
            @definition.policies[name].each do |st|
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
