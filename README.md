# placet

> 宣言的な権限管理ライブラリ — simplified IAM-style authorization（コンセプト策定中）

placet は、AWS IAM の権限モデル（principal への policy アタッチ、explicit deny の優先、implicit deny）を簡略化し、一般のアプリケーションに導入できるようにすることを目指す権限管理ライブラリです。評価器の内部構造は XACML のアーキテクチャ（PEP / PDP / PIP / PAP の役割分離）を参考にしています。

現在は**コンセプト策定フェーズ**であり、実装はまだありません。設計の全体と各判断の経緯は [docs/concept.md](docs/concept.md) にまとまっています。

## モデルの概要

- アクセスユーザーは、`user:42` / `role:editor` / `tenant:acme` のような複数の **principal**（主体の「面」）を持ち、アプリケーション DB の情報から導出される
- 操作は `post:view` のような **action** で表され、action に対する allow / deny の集合が **policy** として principal にアタッチされる
- 決定は **deny-overrides**（1 つでも deny があれば拒否）と **implicit deny**（どこにもマッチしなければ拒否）に固定され、常に「どの policy のどの statement が決め手か」という根拠つきで返される

```yaml
policies:
  - name: post-editor
    statements:
      - effect: allow
        actions: [post:create, post:update, post:delete]

  - name: suspended
    statements:
      - effect: deny
        actions: ["*"]

attachments:
  - principal: role:editor
    policies: [post-editor]
  - principal: flag:suspended
    policies: [suspended]
```

`role:editor` を持つユーザーの `post:update` は許可され、凍結されたユーザー（`flag:suspended` の面を持つユーザー）は allow の有無にかかわらず全操作が拒否されます。

## 設計上の特徴

- **結合則は deny-overrides のみ** — 設定による差し替えを提供しない。Policy を読めば結果が一意に予測できる
- **動的な状態は principal 導出で吸収する** — Policy と attachment は静的でデプロイ時に固定。実行時に変わるのはユーザーの principal 集合だけ
- **リソース個体認可は関係 principal（簡易 ReBAC）** — 「作成者本人のみ編集可」を `rel:owner` のような関係の面として表現し、評価器の仕様は変えない
- **一覧フィルタリングを仕様に含む** — 「閲覧できるものだけを返す」を、関係ごとの scope の和・差として DB クエリに合成する
- **言語非依存の 3 層構造** — コア仕様（フォーマット + 評価セマンティクス + 適合性テスト）/ 言語ランタイム / ORM・フレームワークアダプタ

## ステータス

- [x] コンセプトと設計判断の整理（[docs/concept.md](docs/concept.md)）
- [ ] 正規形の JSON Schema
- [ ] リファレンス実装（Ruby ランタイム + 適合性 fixture）

## リポジトリ構成

3 層構造（[docs/concept.md](docs/concept.md) Section 9）をディレクトリに反映しています。

- `docs/` — コンセプトと設計判断の記録
- `spec/` — コア仕様（正規形の JSON Schema・適合性テスト fixture、言語非依存）
- `packages/ruby/` — Ruby ランタイム（gem: [placet](https://rubygems.org/gems/placet)）
- `packages/js/` — JavaScript / TypeScript ランタイム（npm: [placet](https://www.npmjs.com/package/placet)）

## 名前について

placet はラテン語で「可とする」。大学や教会の採決で用いられる placet / non placet（可 / 否）に由来します。読みは「プラケット」です。
