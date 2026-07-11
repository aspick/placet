# placet サンプルアプリ（Sinatra）

[concept.md](../../docs/concept.md) と [rails-usage.md](../../docs/rails-usage.md) の設計を、動かして体験できるサンプル。多テナントのブログ的なアプリを題材に、placet の主要コンセプトを一通り盛り込んである。

placet 本体は [packages/ruby](../../packages/ruby) のリファレンス実装を `path:` 指定で参照している（当初は簡易ランタイムを同梱していたが、本実装の完成に伴い require の差し替えだけで移行済み——アプリコードは 1 行も変わっていない）。

## 起動

```sh
cd examples/sinatra
bundle install
bundle exec ruby app.rb -p 4567
```

認証は `X-User` ヘッダで代用する。登場人物:

| ユーザー | テナント（プラン） | 面（principal） |
|---|---|---|
| alice | acme (premium) | member + editor |
| bob   | acme (premium) | member |
| carol | umbrella (free) | member |
| dave  | acme (premium) | member・**凍結中**（flag:suspended） |
| erin  | acme (premium) | auditor（全件閲覧可・変更は明示 deny） |
| frank | umbrella (free) | admin（allow `*`） |

投稿: #1 alice@acme、#2 bob@acme、#3 carol@umbrella。

## ツアー

```sh
B=http://127.0.0.1:4567

# --- 一覧の scope 合成（concept.md 8.4） ---
curl -H "X-User: bob"   $B/posts   # 自テナントの 2 件（rel:tenant_member の scope）
curl -H "X-User: erin"  $B/posts   # 全 3 件（静的 allow *:view → 全件）
curl -H "X-User: dave"  $B/posts   # 空（静的 deny → 空集合。凍結は一覧にも効く）

# --- 404 と 403 の使い分け（rails-usage.md 4.5） ---
curl -H "X-User: bob" $B/posts/3                          # 404: 他テナント。存在自体を隠す
curl -H "X-User: bob" -X PATCH "$B/posts/2?title=hi"      # 200: 自分の投稿（rel:owner）
curl -H "X-User: bob" -X PATCH "$B/posts/1?title=hi"      # 403: 見えるが更新権限なし

# --- deny-overrides（concept.md 6） ---
curl -H "X-User: erin" -X PATCH "$B/posts/1?title=x"      # 403: allow *:view を持っていても deny *:update が勝つ
curl -H "X-User: dave" -X POST "$B/posts?title=x"         # 403: member の allow より deny * が勝つ

# --- feature principal パターン（rails-usage.md 5） ---
curl -H "X-User: bob"   $B/reports/export   # 200: premium → feature:analytics が導出される
curl -H "X-User: carol" $B/reports/export   # 403: free プラン → implicit deny

# --- 複数 action の AND（rails-usage.md 4.2） ---
curl -H "X-User: alice" -X POST "$B/posts/1/annotate?text=lgtm"  # 200: post:update + comment:create
curl -H "X-User: erin"  -X POST "$B/posts/1/annotate?text=x"     # 403: post:update で fail-fast

# --- 根拠つき決定と由来の連鎖（concept.md 3.6 / rails placet:explain 相当） ---
curl "$B/debug/decision?user=erin&action=post:update&post=1"
#  => explicit_deny / determinant: readonly-auditor（「権限がない」ではなく「明示的に禁止」と分かる）
curl "$B/debug/decision?user=bob&action=report:export"
#  => permit / via: ["tenant:acme"]（feature:analytics ← tenant:acme の導出連鎖）
curl "$B/debug/decision?user=carol&action=report:export"
#  => implicit_deny / determinants: []（そもそも何もマッチしていない）

# --- DSL → 正規形（rails placet:export 相当） ---
curl $B/debug/policies
#  => コンパイル済みの正規形 JSON。spec/schema/policy-document.schema.json に適合する
```

## 盛り込まれている設計要素

| 設計要素 | サンプルでの場所 |
|---|---|
| Policy の Ruby DSL（policy / allow / deny / attach_to:） | app.rb の `Placet.define` |
| action レジストリ（typo は起動時エラー） | `actions "post", %w[...]` |
| resolver（主体の面） / derive（所属から継承する面・由来記録） | `Placet.resolver` / `Placet.derive "tenant:*"` |
| relation の check / scope ペア | `Placet.relation :owner` ほか |
| 役割 × 所属の合成を関係名にする | `rel:tenant_editor` |
| deny-overrides・implicit deny・凍結（deny-all） | erin / dave の各操作 |
| ワイルドカード 4 形式 | `*`（admin, suspended）・`*:view` / `*:update` 等（auditor） |
| 一覧の scope 合成（静的 deny → 空 / 静的 allow → 全件 / rel の和） | `GET /posts` |
| 404（存在秘匿）と 403 の使い分け | `find_visible_post!` と `authorize!` |
| 複数 action の AND（fail-fast） | `POST /posts/:id/annotate` |
| feature principal（プラン → 機能。placet 定義はデータに触れない） | `PLAN_FEATURES` と `policy "analytics"` |
| 根拠つき決定（basis / determinants / via）・監査ログ・理由の秘匿 | `error Placet::Denied` / `/debug/decision` |
| 正規形へのコンパイルと export | `/debug/policies` |
