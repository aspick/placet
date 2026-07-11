# spec — コア仕様（言語非依存）

placet の 3 層構造（[docs/concept.md](../docs/concept.md) Section 9）のうち、レイヤ 1 にあたるコア仕様を置くディレクトリ。

- `schema/policy-document.schema.json` — Policy 定義の正規形（JSON 互換データモデル）を定義する JSON Schema（draft 2020-12）
- `schema/examples/` — スキーマに適合するドキュメントの例
- `conformance/` — 全言語ランタイムが共有する適合性テスト fixture。決定（`decisions/`）と scope 合成の計画（`scopes/`）の 2 種があり、fixture 形式とランナーの検証規則は [conformance/README.md](conformance/README.md) を参照

各言語ランタイム（`packages/*`）は、ここに置かれた fixture をすべてパスすることが準拠の条件となる。

## スキーマで表現できない意味的制約

JSON Schema による構文検証に加えて、実装はドキュメントの読み込み時に次を検証しなければならない。

1. **policy 名の一意性** — `policies[].name` はドキュメント内で一意でなければならない
2. **参照整合性** — `attachments[].policies` の各要素は、定義されている policy 名を参照しなければならない
3. **同一 principal の重複 attachment** — エラーではない。意味は和集合（アタッチされた policy 集合のマージ）とする。deny-overrides は可換・結合的・冪等（concept.md 6.2）なので、重複や順序は決定に影響しない

## バージョニング

正規形にはトップレベルの `version` フィールドがあり、現行は `1` のみ。スキーマは `additionalProperties: false` で未知のキーを拒否するため、フィールド追加を伴う拡張（例: statement への `condition` 追加）は `version` の更新として行う。

## 検証方法

```sh
npx ajv-cli@5 validate --spec=draft2020 \
  -s spec/schema/policy-document.schema.json \
  -d spec/schema/examples/basic.json
```
