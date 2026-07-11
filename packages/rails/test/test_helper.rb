# frozen_string_literal: true

require "minitest/autorun"
require "logger"
require "rails"
require "action_controller/railtie"
require "active_record"
require "placet"
require "placet/rails"

# --- DB とモデル -------------------------------------------------------------

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :posts, force: true do |t|
    t.string :title
    t.integer :author_id
    t.string :tenant
  end
end

class Post < ActiveRecord::Base; end

TestUser = Struct.new(:id, :tenant, :roles, :suspended, keyword_init: true)

TEST_USERS = {
  "alice" => TestUser.new(id: 1, tenant: "acme", roles: %w[member editor], suspended: false),
  "bob"   => TestUser.new(id: 2, tenant: "acme", roles: %w[member], suspended: false),
  "carol" => TestUser.new(id: 3, tenant: "umbrella", roles: %w[member], suspended: false),
  "dave"  => TestUser.new(id: 4, tenant: "acme", roles: %w[member], suspended: true),
  "frank" => TestUser.new(id: 6, tenant: "umbrella", roles: %w[admin], suspended: false)
}.freeze

# --- placet 定義 -------------------------------------------------------------

Placet.define do
  actions "post", %w[view create update delete]
  actions "report", %w[export]

  policy("tenant-view", attach_to: "rel:tenant_member") { allow "post:view" }
  policy("member-base", attach_to: "role:member") { allow "post:create" }
  policy("post-owner", attach_to: "rel:owner") { allow "post:update", "post:delete" }
  policy("tenant-editor", attach_to: "rel:tenant_editor") { allow "post:update", "post:delete" }
  policy("premium-report", attach_to: "feature:analytics") { allow "report:export" }
  policy("admin", attach_to: "role:admin") { allow "*" }
  policy("suspended", attach_to: "flag:suspended") { deny "*" }
end

Placet.derive "tenant:*" do |tenant|
  tenant == "acme" ? ["feature:analytics"] : []
end

Placet.resolver do |user|
  principals = ["user:#{user.id}", "tenant:#{user.tenant}"] + user.roles.map { |r| "role:#{r}" }
  principals << "flag:suspended" if user.suspended
  principals
end

Placet.relation :owner, resource: Post do
  check { |user, post| post.author_id == user.id }
  scope { |user| Post.where(author_id: user.id) }
end

Placet.relation :tenant_member, resource: Post do
  check { |user, post| post.tenant == user.tenant }
  scope { |user| Post.where(tenant: user.tenant) }
end

Placet.relation :tenant_editor, resource: Post do
  check { |user, post| user.roles.include?("editor") && post.tenant == user.tenant }
  scope { |user| user.roles.include?("editor") ? Post.where(tenant: user.tenant) : Post.none }
end

# --- 最小 Rails アプリ --------------------------------------------------------

class TestApp < Rails::Application
  config.eager_load = false
  config.hosts.clear
  config.secret_key_base = "test"
  config.logger = Logger.new(nil)
  config.action_dispatch.show_exceptions = :none
end
Rails.application.initialize!

class ApplicationController < ActionController::Base
  include Placet::Rails::Controller
  placet_verify!

  rescue_from Placet::Denied do
    head :forbidden
  end
  rescue_from ActiveRecord::RecordNotFound do
    head :not_found
  end

  private

  def current_user = TEST_USERS.fetch(request.headers["X-User"])
end

class PostsController < ApplicationController
  before_action :set_post, only: %i[update destroy]
  placet_resource Post

  def index = render(json: placet_recheck(placet_scope.order(:id)).map(&:id))
  def show = render(json: { id: placet_scope.find(params[:id]).id })

  def create
    post = Post.create!(title: params[:title], author_id: placet_user.id, tenant: placet_user.tenant)
    render json: { id: post.id }, status: :created
  end

  def update
    @post.update!(title: params[:title])
    render json: { id: @post.id, title: @post.title }
  end

  def destroy
    @post.destroy!
    head :no_content
  end

  private

  def set_post = @post = Post.find(params[:id])
end

class HealthController < ApplicationController
  placet_public only: :show
  def show = head(:ok)
end

# placet_verify! の検知対象: 宣言も enforcement も無いアクション
class LeakyController < ApplicationController
  def show = head(:ok)
end

Rails.application.routes.draw do
  resources :posts, only: %i[index show create update destroy]
  get "/health", to: "health#show"
  get "/leaky", to: "leaky#show"
end

# 両テストファイルで共有する Post fixture（作成した post の配列を返す）
def create_fixture_posts!
  Post.delete_all
  [
    Post.create!(id: 1, title: "acme roadmap", author_id: 1, tenant: "acme"),
    Post.create!(id: 2, title: "bob's memo", author_id: 2, tenant: "acme"),
    Post.create!(id: 3, title: "umbrella note", author_id: 3, tenant: "umbrella")
  ]
end
