# placet Rails アダプタ 設計ドキュメント（利用イメージ）

- Status: Draft（実装前の設計固め。API 名・記法はすべて仮）
- 作成日: 2026-07-11
- 前提: [concept.md](concept.md)（コンセプトと言語非依存仕様）

Ruby ランタイム（gem: `placet`）と Rails アダプタ（gem: `placet-rails`）を Rails アプリケーションから利用するときの姿を定める。実装アーキテクチャ上の位置づけは concept.md Section 9 の 3 層構造に従い、本ドキュメントはレイヤ 2（Ruby ランタイム）とレイヤ 3（Rails アダプタ）の API 設計にあたる。

```ruby
# Gemfile
gem "placet"        # 言語ランタイム（PDP: 評価エンジン）
gem "placet-rails"  # Rails アダプタ（PEP ヘルパー + ActiveRecord への scope 合成）
```

設計の基本姿勢: **アプリケーションコードが書くのは「事実の宣言」だけ**（principal の導出規則、リソースとの関係、機能の定義）。「誰が何をできるか」の判断は Policy 定義に 100% 集約され、コントローラやモデルに認可ロジックの条件分岐は存在しない。

## 1. 起動時の流れ

1. `config/placet/` 配下の定義（Ruby DSL / YAML）をロードし、正規形のデータモデルへコンパイル
2. JSON Schema による構文検証 + 意味的検証（policy 名の一意性、attachment の参照整合性、action レジストリ照合）
3. 逆引きインデックス（action → allow / deny principal）の構築
4. いずれかで失敗したら**起動エラー**。Policy の記述ミスはデプロイ前に必ず落ちる

## 2. Policy 定義（Ruby DSL）

### 2.1 ファイル構成

**1 ファイル 1 ポリシー**を基本とし、policy とその attach を同居させる（「この機能の権限と付与先」が 1 ファイルで読める）。

```
config/placet/
├── actions.rb              # action レジストリ
└── policies/
    ├── base_member.rb
    ├── post_editor.rb
    ├── analytics.rb
    └── suspended.rb
```

ローダーがディレクトリを glob して全定義をマージする。policy 名の重複は意味的検証で即エラー。

### 2.2 DSL

`allow` / `deny` の 1 呼び出しが正規形の 1 statement、`policy` ブロックが 1 policy、`attach` / `attach_to:` が attachment に、それぞれ 1:1 で対応する。

```ruby
# config/placet/policies/post_editor.rb
Placet.define do
  policy "post-editor", attach_to: "role:editor" do
    allow "post:create", "post:update", "post:delete"
  end
end

# config/placet/policies/suspended.rb
Placet.define do
  policy "suspended", attach_to: "flag:suspended" do
    deny "*"
  end
end
```

複数 principal への付与は `attach_to: ["role:editor", "feature:beta"]`。attach を独立に書く形（`attach "role:editor", "post-editor"`）も等価に使える。

### 2.3 正規形との等価性

DSL の評価結果は**正規形のデータモデルにコンパイルされてから**、YAML 由来のドキュメントと同一の経路（検証 → コンパイル）を通る。DSL は入力形式にすぎず、真実は常に正規形にある。

```sh
$ rails placet:export   # コンパイル済みの正規形を JSON / YAML で出力
```

- デプロイされる認可定義の実体を diff・レビューできる
- 他言語ランタイム（TypeScript 等）を併用する場合、export した正規形をそのまま食わせられる。**Ruby の書き心地と多言語対応はこの構造で両立する**

YAML（正規形そのまま）との併用も可能。

### 2.4 静的性の原則

DSL は**起動時に一度だけ評価され、静的な正規形を生成する**。DB を読む・環境変数で実行時分岐するなどの動的な定義は、「静的定義」の設計原則（concept.md Section 2）を骨抜きにするためアンチパターンとする。対称的な Policy をループで生成する程度は許容され、その場合も成果物は `placet:export` で静的に確認できる。

実行時に変化してよいのは principal 導出（Section 3）だけである。

### 2.5 action レジストリ

action は文字列であり、typo（`post:veiw`）は「絶対にマッチしない statement」や「常に拒否される authorize」として静かに死ぬ。これを防ぐため、既知の action を宣言できる。

```ruby
# config/placet/actions.rb
Placet.define do
  actions "post",    %w[view create update delete publish]
  actions "comment", %w[view create]
  actions "report",  %w[view export]
end
```

宣言がある場合、Policy 内・`placet_permit` / `authorize!` 内の未知の action は起動時 / 呼び出し時に即エラーとなる。これは評価セマンティクスに影響しない lint であり、正規形（version 1）には含めない Ruby ランタイム機能（将来、多言語ツーリングで有用なら version 2 でコア仕様入りを検討）。

## 3. Principal の導出

### 3.1 resolver — 主体から直接導出される面

```ruby
# config/initializers/placet.rb
Placet.resolver do |user|
  principals = ["user:#{user.id}", "tenant:#{user.tenant_id}"]
  principals += user.roles.map { |role| "role:#{role.name}" }
  principals << "flag:suspended" if user.suspended?
  principals
end
```

### 3.2 derive — 所属から継承する面（展開ルール）

「テナントのプラン」「テナントに有効化された機能」のような**所属先の属性に由来する面**は、resolver に直接書かず、principal 展開ルールとして宣言する。導出の層構造（主体の面 / 所属の面 / 所属から継承する面）がコードとして読める。

```ruby
Placet.derive "tenant:*" do |tenant_id|
  tenant = Tenant.find(tenant_id)
  ["plan:#{tenant.plan.key}"] +
    tenant.plan.features.map { |f| "feature:#{f.key}" }
end
```

- resolve の最後に展開が適用され、エンジンが見るのは従来どおり**平坦な principal 集合**（コア仕様への影響なし）
- `"tenant:*"` は derive フックの type マッチャであり、正規形ドキュメント内の principal パターン（禁止）とは別物
- **展開は 1 段のみ**。derive の結果にさらに derive は適用しない。多段を許すと Zanzibar 型のグラフ評価（concept.md 8.2 案 C）に近づき、静的に読めば分かる性質が失れるため
- 展開時に**由来（provenance）を記録**し、決定構造体の determinants で `feature:analytics ← plan:premium ← tenant:acme` の連鎖として参照できる
- 展開結果は principal 単位（例: tenant 単位）でキャッシュできる。**キャッシュ失効だけが運用事故の入り込む余地**なので、キーに `updated_at` を含めるか契約変更時に明示的に bust する仕組みをアダプタが提供する

### 3.3 relation — リソースとの関係の面（check / scope ペア）

リソース個体認可（concept.md Section 8）のための関係宣言。個体判定 `check` と、一覧フィルタリングに使う逆写像 `scope` を**必ずペアで**宣言する。

```ruby
Placet.relation :owner, resource: Post do
  check { |user, post| post.author_id == user.id }
  scope { |user| Post.where(author_id: user.id) }
end
```

`authorize` にリソースが渡されると、登録済み relation の `check` が評価され `rel:owner` などが principal 集合に自動追加される。

## 4. コントローラ統合

### 4.1 宣言 DSL

エンドポイント → action の対応は **PEP であるコントローラで宣言する**（Policy はルーティングを知らない。routes.rb はリソース個体を持たない）。宣言には性質の異なる 2 モードがある。

- **check モード（403）** — 許可されていなければ拒否。`create` / `update` / `destroy` 系
- **scope モード（絞り込み / 404）** — 一覧・詳細系。`index` を「`post:view` がなければ 403」と宣言するのは**誤り**（`rel:owner` 経由でしか view できないユーザーが門前払いになる）。クエリへの合成として宣言する

```ruby
class PostsController < ApplicationController
  before_action :set_post, only: %i[show update destroy]  # ロードは従来どおりアプリの責務

  placet_permit "post:view",   only: %i[index show], via: :scope
  placet_permit "post:create", only: :create
  placet_permit "post:update", only: :update,  resource: -> { @post }
  placet_permit "post:delete", only: :destroy, resource: -> { @post }

  def index
    @posts = placet_scope.order(created_at: :desc).page(params[:page])
  end

  def show
    @post = placet_scope.find(params[:id])   # 見えなければ RecordNotFound (404)
  end

  def update
    @post.update!(post_params)   # 宣言が before_action として authorize! 済み
  end
end
```

check モードの宣言は before_action としてコールバックチェーンに入るため、Rails の通常の順序規則に従いローダーの後に宣言すれば `@post` が参照できる。

RESTful な CRUD は短縮形に畳める。

```ruby
class PostsController < ApplicationController
  before_action :set_post, only: %i[show update destroy]
  placet_resource Post
  # index/show → post:view (scope), create → post:create,
  # update → post:update, destroy → post:delete に展開される

  placet_permit "post:publish", only: :publish, resource: -> { @post }  # 標準外だけ個別宣言
end
```

認可不要のエンドポイントは明示的にオプトアウトする（検知フックの対象から外す唯一の方法）。

```ruby
class HealthController < ApplicationController
  placet_public only: :show
end
```

設計上の線引き: CanCanCan の `load_and_authorize_resource` と異なり、**リソースのロードは肩代わりしない**。宣言が持つのは「要求 action」「enforcement モード」「判定対象の参照」だけ。

### 4.2 複数 action の要求 — AND のみ

1 エンドポイントに複数の action を要求できる。意味論は **AND（すべて Permit でなければ拒否）**。

```ruby
placet_permit %w[post:update comment:create], only: :annotate, resource: -> { @post }
```

- 同一アクションへの複数宣言の蓄積と等価。判定は fail-fast で、拒否された action と決定構造体がエラーに載る
- principal 導出は (user, resource) 単位でリクエスト内メモ化されるため、N 個の判定は逆引き参照が N 回になるだけ
- **OR は提供しない**。「A または B があれば許可」を PEP で書けるようにすると、認可判断が Policy とコントローラに分裂する。OR の正しい表現は Policy 側にある: エンドポイントの action は 1 つに定め（必要なら専用 action を切り）、その allow を複数の principal にアタッチする
- AND が正当なのは、エンドポイントが実際に複数種類の操作を行う場合（更新 + 監査コメント作成など）。「publish には update も必要」のような運用ルールの AND は、まず Policy 設計（attachment の規律）で表現できないか検討する
- scope モードは v1 では単一 action のみ（複数の scope は許可集合の INTERSECT として定義可能だが、必要になるまで入れない）

### 4.3 インライン API

宣言に収まらないケース（複数リソースにまたがる操作など）は従来どおりアクション内で呼ぶ。宣言・インラインのどちらでも検知フックは満たされる。

```ruby
Placet.authorize!(current_user, "post:update", @post)
Placet.authorize!(current_user, %w[post:update comment:create], @post)  # AND
posts = Placet.scoped(current_user, "post:view")                        # 素の Relation
decision = Placet.decide(current_user, "post:delete", @post)            # 判定のみ（raise しない）
```

### 4.4 呼び忘れ検知と例外処理

```ruby
class ApplicationController < ActionController::Base
  include Placet::Rails::Controller

  placet_verify!   # authorize も scoped も呼ばれずにアクションが終わると raise（development / test で必ず有効化）

  rescue_from Placet::Denied do |error|
    Rails.logger.info(error.decision.to_h)   # basis / determinants を監査ログへ
    head :forbidden                          # エンドユーザーには理由を出さない（concept.md 3.6）
  end
end
```

新しいエンドポイントを生やして権限指定を忘れる、が通らない構造。`default_scope` による強制は採用しない（リクエスト文脈のグローバル状態依存、ジョブ / rake での破綻、`unscoped` の穴。concept.md 8.5）。

### 4.5 404 と 403 の使い分け

```ruby
# a) scoped 経由 → 見えないものは 404。リソースの存在自体を隠す（閲覧系の既定）
post = placet_scope.find(params[:id])

# b) ロード後に authorize → 403。見えているものへの操作拒否（update / destroy 等）
Placet.authorize!(current_user, "post:update", @post)
```

### 4.6 ビューヘルパー

```erb
<% if placet_permit?("post:update", post) %>
  <%= link_to "編集", edit_post_path(post) %>
<% end %>
```

表示制御と実行時の enforcement が常に同じ判定を共有する。

## 5. プラン・ライセンス・機能フラグ（feature principal パターン）

「選択的な機能有効化」「ユーザー / テナントごとの機能制限」は、attach の動的化ではなく **principal 導出で実現する**（動的な状態は principal 導出で吸収する、の適用）。変更頻度の異なる 3 つの対応関係を、それぞれ適切な場所に置く。

| 対応関係 | 変更の契機 | 変更頻度 | 置き場所 |
|---|---|---|---|
| feature → actions（機能の定義） | 製品のコード変更 | 低（デプロイと同期） | placet の Policy 定義（静的） |
| plan → features（プランの構成） | ビジネス判断・料金改定 | 中 | アプリの DB マスタ（derive が読む） |
| tenant → plan（割当） | 契約・営業 | 高 | アプリの DB（契約テーブル） |

**規律: Policy を attach してよいのは feature principal だけ。plan principal には直接 attach しない。** これを破る（`attach "plan:premium", "analytics"`）と、プラン改定のたびにデプロイが必要になる——変更頻度と置き場所のミスマッチ。

```ruby
# 機能の定義（placet・静的）
Placet.define do
  policy "analytics", attach_to: "feature:analytics" do
    allow "report:view", "report:export"
  end
end

# プラン構成は DB マスタに委譲（derive・規則は静的、データは動的）
Placet.derive "tenant:*" do |tenant_id|
  Tenant.find(tenant_id).plan.features.map { |f| "feature:#{f.key}" }
end
```

- 機能の有効化 = DB の行追加。次のリクエストから権限が流れ込み、**placet の定義には一切触れない**
- ダウングレード = feature が消える = implicit deny で自然に閉じる。「降格したのに allow が残る」事故は構造上起きない
- explicit deny を plan 系 principal に貼るのは打ち消し目的（トライアル中は破壊的操作を禁止等）に限定する
- Flipper 等の既存 feature flag 基盤は derive / resolver から参照するだけで統合できる

## 6. テスト・ジョブでの利用

```ruby
# check / scope の乖離（最大のリスク。concept.md 8.4）を property test で検証
it "owner relation の check と scope が一致する" do
  verify_relation_consistency(:owner, users: User.all, records: Post.all)
end
```

strict モード（scoped の結果に描画直前の `check` 再適用。concept.md 11.5）はオプションとして提供し、既定値は未決。

ジョブ・rake タスクでも同じ API がそのまま動く。`current_user` のようなグローバル状態に依存せず、常に user を明示的に渡す設計のため。

```ruby
Placet.authorize!(report.requested_by, "report:export", report)
```

## 7. 運用ツール

すべての層（Policy・attachment・derive・エンドポイント宣言）が宣言的・機械可読であることを活かし、「何ができるか」を常にツールで答えられるようにする。

```sh
# エンドポイント → 必要権限の一覧（コントローラの宣言とルーティングから生成）
$ rails placet:endpoints
GET    /posts              post:view    (scoped)
GET    /posts/:id          post:view    (scoped, 404)
POST   /posts              post:create
PATCH  /posts/:id          post:update  (403)
DELETE /posts/:id          post:delete  (403)
POST   /posts/:id/publish  post:publish (403)

# コンパイル済み正規形の出力（diff・レビュー・他言語ランタイムへの入力）
$ rails placet:export

# 分類 principal の実効権限（derive を通してデータも参照）
$ rails placet:explain plan:premium
plan:premium
└─ feature:analytics      (plan_features より)
   └─ policy: analytics
      allow report:view
      allow report:export

# 特定の主体について「なぜできる / できないか」（由来の連鎖つき）
$ rails placet:explain user:42 report:export
Permit (explicit_allow)
└─ determinant: policy "analytics" statement 0
   via feature:analytics ← plan:premium ← tenant:acme
```

「このライセンスでは何が使えるのか」という問いが、コード中の条件分岐を grep する作業ではなく、コマンド 1 つで答えられる状態を保つ。

## 8. Pundit との使用感の違い

一番の違いは、**アプリコードに認可の「ロジック」が存在しない**こと。Pundit では PostPolicy クラスに `update?` メソッドと Scope クラスを手書きするが、placet でアプリが書くのは「principal の導出」「関係の check / scope ペア」「機能の定義」という**事実の宣言**だけで、誰が何をできるかの判断はすべて Policy 定義に集約される。

「editor は削除もできるようにしたい」という変更は Ruby コードに触れず Policy の 1 行で済み、その影響は定義を読めば一意に予測できる（deny-overrides 固定・explicit deny 優先・implicit deny）。Scope についても、Pundit が Scope 全体を手書きするのに対し、placet は関係ごとの scope 部品から合成を自動導出する（concept.md 8.4）。
