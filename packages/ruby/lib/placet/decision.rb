# frozen_string_literal: true

module Placet
  # 決め手になった statement。via は derive による導出の連鎖（concept.md 3.6）
  Determinant = Struct.new(:principal, :policy, :statement, :effect, :via, keyword_init: true) do
    def to_h = super.compact
  end

  # 根拠つきの決定。basis は :explicit_allow / :explicit_deny / :implicit_deny
  Decision = Struct.new(:decision, :basis, :determinants, keyword_init: true) do
    def permit? = decision == :permit
    def to_h = { decision: decision, basis: basis, determinants: determinants.map(&:to_h) }
  end
end
