# frozen_string_literal: true

require_relative "test_helper"

# ランタイム層（resolver / derive / relation / scoped / AND）のテスト
class RuntimeTest < Minitest::Test
  TestUser = Struct.new(:id, :tenant, :roles, keyword_init: true)
  TestPost = Struct.new(:id, :author_id, :tenant, keyword_init: true)

  POSTS = [
    TestPost.new(id: 1, author_id: 1, tenant: "acme"),
    TestPost.new(id: 2, author_id: 2, tenant: "acme"),
    TestPost.new(id: 3, author_id: 3, tenant: "umbrella")
  ].freeze

  def TestPost.all = POSTS

  ALICE = TestUser.new(id: 1, tenant: "acme", roles: %w[member]).freeze
  ADMIN = TestUser.new(id: 9, tenant: "acme", roles: %w[admin]).freeze

  def setup
    Placet.reset!
    Placet.define do
      policy("tenant-view", attach_to: "rel:tenant_member") { allow "post:view" }
      policy("owner-edit", attach_to: "rel:owner") { allow "post:update" }
      policy("member-base", attach_to: "role:member") { allow "comment:create" }
      policy("admin", attach_to: "role:admin") { allow "*" }
      policy("premium-report", attach_to: "feature:analytics") { allow "report:export" }
    end
    Placet.resolver do |user|
      ["user:#{user.id}", "tenant:#{user.tenant}"] + user.roles.map { |r| "role:#{r}" }
    end
    Placet.derive "tenant:*" do |tenant|
      tenant == "acme" ? ["feature:analytics"] : []
    end
    Placet.relation :owner, resource: TestPost do
      check { |user, post| post.author_id == user.id }
      scope { |user| TestPost.all.select { |p| p.author_id == user.id } }
    end
    Placet.relation :tenant_member, resource: TestPost do
      check { |user, post| post.tenant == user.tenant }
      scope { |user| TestPost.all.select { |p| p.tenant == user.tenant } }
    end
  end

  def teardown = Placet.reset!

  def test_relation_check_feeds_instance_decision
    assert Placet.permit?(ALICE, "post:update", POSTS[0])   # 自分の投稿
    refute Placet.permit?(ALICE, "post:update", POSTS[1])   # 他人の投稿
  end

  def test_derive_adds_inherited_facet_with_provenance
    decision = Placet.decide(ALICE, "report:export")
    assert decision.permit?
    determinant = decision.determinants.first
    assert_equal "feature:analytics", determinant.principal
    assert_equal ["tenant:acme"], determinant.via
  end

  def test_scoped_unions_relation_scopes
    assert_equal [1, 2], Placet.scoped(ALICE, "post:view", model: TestPost).map(&:id)
  end

  def test_scoped_returns_all_for_static_allow
    assert_equal [1, 2, 3], Placet.scoped(ADMIN, "post:view", model: TestPost).map(&:id)
  end

  def test_multiple_actions_are_anded
    assert Placet.permit?(ALICE, %w[post:update comment:create], POSTS[0])
    refute Placet.permit?(ALICE, %w[post:update comment:create], POSTS[1])
  end

  def test_authorize_bang_raises_with_decision
    error = assert_raises(Placet::Denied) { Placet.authorize!(ALICE, "post:update", POSTS[1]) }
    assert_equal "post:update", error.action
    assert_equal :implicit_deny, error.decision.basis
  end

  def test_recheck_filters_divergent_records_and_notifies
    divergent = []
    Placet.on_recheck_divergence = ->(_user, _action, record) { divergent << record.id }

    # scope が「過剰に」全件を返してしまった、という乖離を想定
    rechecked = Placet.recheck(ALICE, "post:view", TestPost.all)

    assert_equal [1, 2], rechecked.map(&:id)   # 見えてはいけない p3 は除外される
    assert_equal [3], divergent                # 乖離はハンドラに通知される
  end

  def test_verify_relation_consistency_passes_for_consistent_relation
    extend Placet::TestHelpers
    assert verify_relation_consistency(:owner, resource: TestPost,
                                               users: [ALICE, ADMIN], records: TestPost.all)
  end

  def test_verify_relation_consistency_detects_divergence
    extend Placet::TestHelpers
    buggy_model = Class.new
    Placet.relation :buggy, resource: buggy_model do
      check { |_user, _record| false }          # 個体判定では常に不可なのに
      scope { |_user| TestPost.all }            # 一覧には全件出る、という乖離
    end

    error = assert_raises(Placet::Error) do
      verify_relation_consistency(:buggy, resource: buggy_model,
                                          users: [ALICE], records: TestPost.all)
    end
    assert_match(/乖離/, error.message)
  end
end
