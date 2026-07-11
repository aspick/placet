# frozen_string_literal: true

require_relative "test_helper"

# spec/conformance/ の全 fixture をパスすることが仕様準拠の条件
# （検証規則は spec/conformance/README.md）
class DecisionConformanceTest < Minitest::Test
  extend ConformanceLoader

  define_conformance_tests("decisions") do |engine, kase|
    decision = engine.decide(kase["principals"], kase["action"])
    expect = kase["expect"]

    assert_equal expect["decision"], decision.decision.to_s, "decision mismatch"
    assert_equal expect["basis"], decision.basis.to_s, "basis mismatch"

    reported = decision.determinants.map do |d|
      d.to_h.transform_keys(&:to_s).except("via")
    end
    if expect["basis"] == "implicit_deny"
      assert_empty reported, "implicit_deny の determinants は空でなければならない"
    else
      refute_empty reported, "determinants は最低 1 件必要"
      reported.each do |d|
        assert_includes expect["valid_determinants"], d, "無効な determinant が報告された"
      end
    end
  end
end

class ScopePlanConformanceTest < Minitest::Test
  extend ConformanceLoader

  define_conformance_tests("scopes") do |engine, kase|
    plan = engine.scope_plan(kase["static_principals"], kase["action"],
                             relations: kase["relations"])
    expect = kase["expect"]

    assert_equal expect["kind"], plan.kind, "kind mismatch"
    if expect.key?("include_relations")
      assert_equal expect["include_relations"].sort, plan.include_relations.sort
    end
    if expect.key?("exclude_relations")
      assert_equal expect["exclude_relations"].sort, plan.exclude_relations.sort
    end
  end
end
