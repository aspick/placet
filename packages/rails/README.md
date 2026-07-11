# placet-rails

> placet の Rails アダプタ — 宣言的な per-action 認可と ActiveRecord への scope 合成

[placet](../../README.md) を Rails に統合するアダプタ gem。設計の全体像は [docs/rails-usage.md](../../docs/rails-usage.md) を参照。

**RubyGems には未公開です。** 現時点で試す場合は `gem "placet-rails", path: ...` を使用してください。

## 提供するもの

- **コントローラ統合（PEP ヘルパー）** — `placet_permit`（check / scope の 2 モード、複数 action は AND）、`placet_resource`（RESTful 規約の展開）、`placet_public`（明示オプトアウト）、`placet_verify!`（enforcement 漏れの検知）、`placet_scope` / `placet_permit?` ヘルパー
- **ActiveRecord への scope 写像** — コアの ScopePlan（empty / all / union ± exclude）を主キーのサブクエリとして `ActiveRecord::Relation` に合成する。返るのは素の Relation なので、ページネーション・ORDER・`count` がそのまま動く
- **Railtie** — `config/placet/**/*.rb` の定義を起動時にロード（不備は起動エラー）。`rails placet:export` / `rails placet:endpoints` タスク

## 使い方の骨子

```ruby
class ApplicationController < ActionController::Base
  include Placet::Rails::Controller
  placet_verify!

  rescue_from Placet::Denied do |error|
    Rails.logger.info(error.decision.to_h)  # 根拠は監査ログへ
    head :forbidden                          # ユーザーには理由を出さない
  end
end

class PostsController < ApplicationController
  before_action :set_post, only: %i[update destroy]
  placet_resource Post
  placet_permit "post:publish", only: :publish, resource: -> { @post }

  def index = render(json: placet_scope.order(created_at: :desc).page(params[:page]))
  def show  = render(json: placet_scope.find(params[:id]))   # 見えなければ 404
end
```

## テストの実行

```sh
cd packages/rails
bundle install
for f in test/*_test.rb; do bundle exec ruby -Ilib -Itest "$f"; done
```
