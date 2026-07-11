# frozen_string_literal: true

require_relative "test_helper"

class ControllerIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    Post.delete_all
    @p1 = Post.create!(id: 1, title: "acme roadmap", author_id: 1, tenant: "acme")
    @p2 = Post.create!(id: 2, title: "bob's memo", author_id: 2, tenant: "acme")
    @p3 = Post.create!(id: 3, title: "umbrella note", author_id: 3, tenant: "umbrella")
  end

  def as(name) = { headers: { "X-User" => name } }

  # --- scope モード（index / show） ---

  def test_index_is_scoped_to_tenant
    get "/posts", **as("bob")
    assert_response :success
    assert_equal [1, 2], response.parsed_body
  end

  def test_index_returns_all_for_static_allow
    get "/posts", **as("frank")
    assert_equal [1, 2, 3], response.parsed_body
  end

  def test_index_is_empty_for_suspended_user
    get "/posts", **as("dave")
    assert_equal [], response.parsed_body
  end

  def test_show_returns_404_for_invisible_resource
    get "/posts/3", **as("bob")
    assert_response :not_found
  end

  # --- check モード（create / update / destroy） ---

  def test_create_is_permitted_for_member
    post "/posts", params: { title: "new" }, **as("bob")
    assert_response :created
  end

  def test_create_is_denied_for_suspended_user
    post "/posts", params: { title: "x" }, **as("dave")
    assert_response :forbidden
  end

  def test_update_own_post_via_owner_relation
    patch "/posts/2", params: { title: "mine" }, **as("bob")
    assert_response :success
    assert_equal "mine", @p2.reload.title
  end

  def test_update_others_post_is_forbidden
    patch "/posts/1", params: { title: "x" }, **as("bob")
    assert_response :forbidden
    assert_equal "acme roadmap", @p1.reload.title
  end

  def test_editor_updates_tenant_post_via_tenant_editor_relation
    patch "/posts/2", params: { title: "edited" }, **as("alice")
    assert_response :success
  end

  def test_destroy_own_post
    delete "/posts/2", **as("bob")
    assert_response :no_content
    assert_nil Post.find_by(id: 2)
  end

  # --- placet_public と placet_verify! ---

  def test_public_action_skips_verification
    get "/health", **as("bob")
    assert_response :success
  end

  def test_verify_raises_when_no_enforcement_happened
    error = assert_raises(Placet::Rails::VerificationError) { get "/leaky", **as("bob") }
    assert_match(/LeakyController#show/, error.message)
  end
end
