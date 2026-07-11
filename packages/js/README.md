# placet (JavaScript / TypeScript)

> 宣言的な権限管理ライブラリ — simplified IAM-style authorization（コンセプト策定中）

placet の JavaScript / TypeScript ランタイムです。現在は**コンセプト策定フェーズ**であり、このバージョンは名前確保のためのプレースホルダです。`import` するとその旨のエラーが送出されます。

- プロジェクト全体: https://github.com/aspick/placet
- 設計ドキュメント: https://github.com/aspick/placet/blob/main/docs/concept.md

## モデルの概要

- アクセスユーザーは `user:42` / `role:editor` / `tenant:acme` のような複数の **principal**（主体の「面」）を持つ
- 操作は `post:view` のような **action** で表され、allow / deny の集合が **policy** として principal にアタッチされる
- 決定は **deny-overrides** と **implicit deny** に固定され、常に根拠つきで返される
