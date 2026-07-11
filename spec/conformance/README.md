# conformance — 適合性テスト fixture

全言語ランタイムが共有する適合性テスト。各ランタイムは、ここにあるすべての fixture をパスすることが仕様準拠の条件となる（concept.md 10.3）。

fixture はコア仕様の**純粋関数としての振る舞い**だけを検証する。principal の導出（resolver / derive / relation の check）はアプリケーション側の責務なので対象外であり、fixture では principal 集合を入力として直接与える。

## decisions/ — 決定の fixture

`(Policy ドキュメント, principal 集合, action) → 決定` を検証する。

```json
{
  "name": "fixture 名",
  "document": { "version": 1, "policies": [...], "attachments": [...] },
  "cases": [
    {
      "name": "ケース名",
      "principals": ["user:1", "role:member"],
      "action": "post:view",
      "expect": {
        "decision": "permit",
        "basis": "explicit_allow",
        "valid_determinants": [
          { "principal": "role:member", "policy": "base-member", "statement": 0, "effect": "allow" }
        ]
      }
    }
  ]
}
```

ランナーの検証規則:

1. `decision` と `basis` は完全一致
2. determinants は次を満たす（実装は最初の Deny で短絡してよいため、完全一致は要求しない。concept.md 3.6）:
   - `basis` が `implicit_deny` のとき: 空でなければならない
   - それ以外のとき: **1 件以上**であり、報告された各 determinant が `valid_determinants` の**部分集合**であること（via など実装依存の追加フィールドは比較から除外する）

## scopes/ — scope 合成（plan）の fixture

一覧フィルタリング（concept.md 8.4）の合成規則を、SQL ではなく**集合演算の計画（scope plan）**として検証する。ランタイムは `(Policy ドキュメント, 静的 principal 集合, action, 利用可能な relation 名) → plan` を返す関数を持たなければならない。plan は ORM アダプタが WHERE 句へ写像する中間表現である。

```json
{
  "cases": [
    {
      "name": "ケース名",
      "action": "post:view",
      "static_principals": ["user:1", "role:member"],
      "relations": ["tenant_member", "owner", "banned"],
      "expect": { "kind": "union", "include_relations": ["tenant_member"], "exclude_relations": ["banned"] }
    }
  ]
}
```

plan の意味論（適用は上から順）:

| kind | 意味 | 条件 |
|---|---|---|
| `empty` | 空集合 | 静的 principal に deny 元がある。または allow 元となる静的 principal も relation も存在しない |
| `all` | 全件から `exclude_relations` の scope を差し引く | 静的 principal に allow 元がある |
| `union` | `include_relations` の scope の和集合から `exclude_relations` の scope を差し引く | 上記以外 |

`include_relations` / `exclude_relations` は順序を持たない（ランナーはソートして比較する）。
