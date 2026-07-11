# frozen_string_literal: true

require_relative "test_helper"

class ExplainTest < Minitest::Test
  def setup
    Placet.reset!
    Placet.define do
      actions "post", %w[create]
      actions "report", %w[export]

      policy("member-base", attach_to: "role:member") { allow "post:create" }
      policy("premium-report", attach_to: "feature:analytics") { allow "report:export" }
    end
    Placet.derive "tenant:*" do |tenant|
      tenant == "acme" ? ["feature:analytics"] : []
    end
  end

  def teardown = Placet.reset!

  def test_principal_report_lists_attached_policies
    report = Placet::Explain.principal_report("role:member")
    assert_includes report, "member-base"
    assert_includes report, "allow post:create"
  end

  def test_principal_report_expands_derived_principals
    report = Placet::Explain.principal_report("tenant:acme")
    assert_includes report, "feature:analytics"
    assert_includes report, "tenant:acme から導出"
    assert_includes report, "premium-report"
  end

  def test_decision_report_shows_provenance_chain
    report = Placet::Explain.decision_report(["tenant:acme"], "report:export")
    assert_includes report, "permit (explicit_allow)"
    assert_includes report, 'policy "premium-report"'
    assert_includes report, "via feature:analytics ← tenant:acme"
  end

  def test_decision_report_explains_implicit_deny
    report = Placet::Explain.decision_report(["tenant:umbrella"], "report:export")
    assert_includes report, "deny (implicit_deny)"
    assert_includes report, "マッチする statement なし"
  end
end
