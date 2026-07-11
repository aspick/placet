# spec — コア仕様（言語非依存）

placet の 3 層構造（[docs/concept.md](../docs/concept.md) Section 9）のうち、レイヤ 1 にあたるコア仕様を置くディレクトリ。

- `schema/` — Policy 定義の正規形（JSON 互換データモデル）を定義する JSON Schema
- `conformance/` — 全言語ランタイムが共有する適合性テスト fixture（Policy 定義 + principal 集合 + 要求 action → 期待される決定）

いずれも未着手。各言語ランタイム（`packages/*`）は、ここに置かれた fixture をすべてパスすることが準拠の条件となる。
