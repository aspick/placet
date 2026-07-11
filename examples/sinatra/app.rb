# frozen_string_literal: true

require "sinatra"
require "json"
require "placet"

# ============================================================================
# placet サンプルアプリ（Sinatra）
#
# 多テナントのブログ的なアプリを題材に、docs/concept.md と
# docs/rails-usage.md の設計を一通り体験できる。起動と試し方は README.md。
# 認証は X-User ヘッダで代用する（値: alice / bob / carol / dave / erin / frank）。
# ============================================================================

# ---------------------------------------------------------------------------
# モデルとシードデータ（インメモリ。実アプリでは ActiveRecord 等）
# ---------------------------------------------------------------------------

# plan → features の対応はビジネスデータ（DB マスタ相当）。
# placet の定義ではないので、料金改定はこのデータの変更だけで済む。
PLAN_FEATURES = { "premium" => %w[analytics], "free" => [] }.freeze

Tenant = Struct.new(:key, :plan, keyword_init: true) do
  def features = PLAN_FEATURES.fetch(plan, [])
end

User = Struct.new(:id, :name, :tenant_key, :roles, :suspended, keyword_init: true)

Post = Struct.new(:id, :title, :author_id, :tenant_key, :comments, keyword_init: true) do
  def self.all = POSTS
end

TENANTS = {
  "acme"     => Tenant.new(key: "acme", plan: "premium"),
  "umbrella" => Tenant.new(key: "umbrella", plan: "free")
}.freeze

USERS = {
  "alice" => User.new(id: 1, name: "alice", tenant_key: "acme",     roles: %w[member editor], suspended: false),
  "bob"   => User.new(id: 2, name: "bob",   tenant_key: "acme",     roles: %w[member],        suspended: false),
  "carol" => User.new(id: 3, name: "carol", tenant_key: "umbrella", roles: %w[member],        suspended: false),
  "dave"  => User.new(id: 4, name: "dave",  tenant_key: "acme",     roles: %w[member],        suspended: true),
  "erin"  => User.new(id: 5, name: "erin",  tenant_key: "acme",     roles: %w[auditor],       suspended: false),
  "frank" => User.new(id: 6, name: "frank", tenant_key: "umbrella", roles: %w[admin],         suspended: false)
}.freeze

POSTS = [
  Post.new(id: 1, title: "acme roadmap",  author_id: 1, tenant_key: "acme",     comments: []),
  Post.new(id: 2, title: "bob's memo",    author_id: 2, tenant_key: "acme",     comments: []),
  Post.new(id: 3, title: "umbrella note", author_id: 3, tenant_key: "umbrella", comments: [])
]

# ---------------------------------------------------------------------------
# placet: action レジストリと Policy 定義（静的・デプロイ周期）
# 実アプリでは config/placet/policies/*.rb に 1 ファイル 1 ポリシーで置く
# ---------------------------------------------------------------------------

Placet.define do
  actions "post",    %w[view create update delete]
  actions "comment", %w[view create]
  actions "report",  %w[view export]

  # 同一テナントの投稿が見える（一覧の scope は relation :tenant_member から合成される）
  policy "tenant-member", attach_to: "rel:tenant_member" do
    allow "post:view", "comment:view"
  end

  # メンバーの基本操作（リソース個体を伴わない action）
  policy "member-base", attach_to: "role:member" do
    allow "post:create", "comment:create"
  end

  # 自分の投稿は編集・削除できる（関係 principal）
  policy "post-owner", attach_to: "rel:owner" do
    allow "post:update", "post:delete"
  end

  # 編集者は自テナントの投稿を編集・削除できる（役割 × 所属の合成は relation 側で名前にする）
  policy "tenant-editor", attach_to: "rel:tenant_editor" do
    allow "post:update", "post:delete"
  end

  # 監査ロール: 全リソース閲覧可・変更系は明示 deny（ワイルドカード *:view / *:update）
  policy "readonly-auditor", attach_to: "role:auditor" do
    allow "*:view"
    deny  "*:create", "*:update", "*:delete"
  end

  # 機能の定義: analytics 機能とは report が読めて export できること。
  # 「誰に有効か」はここに書かない（plan → features は DB マスタ、割当は契約データ）
  policy "analytics", attach_to: "feature:analytics" do
    allow "report:view", "report:export"
  end

  policy "admin", attach_to: "role:admin" do
    allow "*"
  end

  # 凍結: principal の一つの面に deny-all を貼るだけで全操作が止まる（deny-overrides）
  policy "suspended", attach_to: "flag:suspended" do
    deny "*"
  end
end

# ---------------------------------------------------------------------------
# placet: principal の導出（動的・データ周期）
# ---------------------------------------------------------------------------

# 主体から直接導出される面
Placet.resolver do |user|
  principals = ["user:#{user.id}", "tenant:#{user.tenant_key}"]
  principals += user.roles.map { |role| "role:#{role}" }
  principals << "flag:suspended" if user.suspended
  principals
end

# 所属から継承する面（tenant についての規則、と層が明示される）。
# プラン変更・機能の有効化はデータ変更だけで次のリクエストから効く
Placet.derive "tenant:*" do |tenant_key|
  tenant = TENANTS.fetch(tenant_key)
  ["plan:#{tenant.plan}"] + tenant.features.map { |f| "feature:#{f}" }
end

# リソースとの関係の面: check（個体判定）と scope（一覧用の逆写像）を必ずペアで
Placet.relation :owner, resource: Post do
  check { |user, post| post.author_id == user.id }
  scope { |user| Post.all.select { |post| post.author_id == user.id } }
end

Placet.relation :tenant_member, resource: Post do
  check { |user, post| post.tenant_key == user.tenant_key }
  scope { |user| Post.all.select { |post| post.tenant_key == user.tenant_key } }
end

Placet.relation :tenant_editor, resource: Post do
  check { |user, post| user.roles.include?("editor") && post.tenant_key == user.tenant_key }
  scope { |user| user.roles.include?("editor") ? Post.all.select { |post| post.tenant_key == user.tenant_key } : [] }
end

# ---------------------------------------------------------------------------
# Sinatra アプリ（PEP）
# ---------------------------------------------------------------------------

configure do
  set :show_exceptions, false
  set :raise_errors, false
  enable :logging
end

before { content_type :json }

helpers do
  def current_user
    name = request.env["HTTP_X_USER"]
    USERS[name] || halt(401, JSON.generate(error: "unknown user: set X-User header (alice/bob/carol/dave/erin/frank)"))
  end

  # 閲覧系は scoped 経由 → 見えないものは 404（存在秘匿）
  def find_visible_post!(user)
    Placet.scoped(user, "post:view", model: Post).find { |post| post.id == params[:id].to_i } ||
      halt(404, JSON.generate(error: "not found"))
  end

  def post_json(post)
    { id: post.id, title: post.title, author: USERS.values.find { |u| u.id == post.author_id }&.name,
      tenant: post.tenant_key, comments: post.comments }
  end
end

# 認可されなかった操作は 403。理由はエンドユーザーに返さず、監査ログにだけ残す
error Placet::Denied do
  denied = env["sinatra.error"]
  logger.info "placet denied: action=#{denied.action} decision=#{JSON.generate(denied.decision.to_h)}"
  halt 403, JSON.generate(error: "forbidden")
end

error Placet::Error do
  halt 400, JSON.generate(error: env["sinatra.error"].message)
end

# 一覧: Policy から合成された scope（静的 deny → 空 / 静的 allow → 全件 / rel scope の和）
get "/posts" do
  posts = Placet.scoped(current_user, "post:view", model: Post)
  JSON.generate(posts.map { |post| post_json(post) })
end

# 詳細: 見えなければ 404
get "/posts/:id" do
  JSON.generate(post_json(find_visible_post!(current_user)))
end

# 作成: リソース個体を伴わない action
post "/posts" do
  user = current_user
  Placet.authorize!(user, "post:create")
  post = Post.new(id: POSTS.map(&:id).max + 1, title: params[:title] || "untitled",
                  author_id: user.id, tenant_key: user.tenant_key, comments: [])
  POSTS << post
  status 201
  JSON.generate(post_json(post))
end

# 更新: 見えないものは 404、見えていて権限がなければ 403
patch "/posts/:id" do
  user = current_user
  post = find_visible_post!(user)
  Placet.authorize!(user, "post:update", post)
  post.title = params[:title] if params[:title]
  JSON.generate(post_json(post))
end

delete "/posts/:id" do
  user = current_user
  post = find_visible_post!(user)
  Placet.authorize!(user, "post:delete", post)
  POSTS.delete(post)
  status 204
end

# 複数 action の AND: 投稿を更新しつつ監査コメントを残す複合操作
post "/posts/:id/annotate" do
  user = current_user
  post = find_visible_post!(user)
  Placet.authorize!(user, %w[post:update comment:create], post)
  post.comments << (params[:text] || "annotated by #{user.name}")
  JSON.generate(post_json(post))
end

# feature principal パターン: analytics 機能（premium プランのみ）
get "/reports/export" do
  user = current_user
  Placet.authorize!(user, "report:export")
  JSON.generate(report: "exported", tenant: user.tenant_key)
end

# --- デバッグ / 運用ツール相当 -----------------------------------------------

# rails placet:explain 相当: なぜできる / できないか（由来の連鎖つき）
get "/debug/decision" do
  user = USERS[params[:user]] || halt(400, JSON.generate(error: "user param required"))
  action = params[:action] || halt(400, JSON.generate(error: "action param required"))
  resource = params[:post] && Post.all.find { |post| post.id == params[:post].to_i }
  JSON.generate(Placet.decide(user, action, resource).to_h)
end

# rails placet:export 相当: コンパイル済みの正規形（DSL → canonical form）
get "/debug/policies" do
  JSON.pretty_generate(Placet.export)
end
