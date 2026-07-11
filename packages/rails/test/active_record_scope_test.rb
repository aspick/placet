# frozen_string_literal: true

require_relative "test_helper"

# ScopePlan → ActiveRecord::Relation の写像のユニットテスト
class ActiveRecordScopeTest < Minitest::Test
  def setup
    Post.delete_all
    Post.create!(id: 1, title: "a", author_id: 1, tenant: "acme")
    Post.create!(id: 2, title: "b", author_id: 2, tenant: "acme")
    Post.create!(id: 3, title: "c", author_id: 3, tenant: "umbrella")
  end

  def alice = TEST_USERS["alice"]
  def bob = TEST_USERS["bob"]

  def test_scoped_returns_an_active_record_relation
    assert_kind_of ActiveRecord::Relation, Placet.scoped(bob, "post:view", model: Post)
  end

  def test_union_of_relation_scopes
    # bob: rel:tenant_member の scope（acme）が union される
    assert_equal [1, 2], Placet.scoped(bob, "post:view", model: Post).order(:id).pluck(:id)
  end

  def test_union_across_multiple_relations_deduplicates
    # alice の post:update は rel:owner（author=1）と rel:tenant_editor（acme 全件）の OR
    assert_equal [1, 2], Placet.scoped(alice, "post:update", model: Post).order(:id).pluck(:id)
  end

  def test_static_allow_yields_model_wide_relation
    assert_equal [1, 2, 3], Placet.scoped(TEST_USERS["frank"], "post:view", model: Post).order(:id).pluck(:id)
  end

  def test_static_deny_yields_none
    scope = Placet.scoped(TEST_USERS["dave"], "post:view", model: Post)
    assert_predicate scope, :none?
  end

  def test_relation_chains_compose_with_pagination_and_count
    scope = Placet.scoped(bob, "post:view", model: Post)
    assert_equal 2, scope.count
    assert_equal [2], scope.order(:id).limit(1).offset(1).pluck(:id)
  end
end
