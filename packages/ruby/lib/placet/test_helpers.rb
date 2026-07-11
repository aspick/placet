# frozen_string_literal: true

require "placet"

module Placet
  # テストスイートに include して使う検証ヘルパー（require "placet/test_helpers"）。
  # minitest / RSpec のどちらからでも使える
  module TestHelpers
    # relation の check と scope の整合性を property test として検証する:
    #   record ∈ scope(user) ⟺ check(user, record)
    # 乖離（個体判定では見えるのに一覧に出ない / その逆）は「見えてはいけないものが
    # 見える」事故の源泉なので、乖離を見つけた時点で詳細つきの例外を投げる
    def verify_relation_consistency(name, resource:, users:, records:)
      relation = Placet.relations_for(resource).find { |r| r.name == name.to_s }
      raise Placet::Error, "relation が未定義: #{name} (resource: #{resource})" unless relation

      users.each do |user|
        scoped_records = relation.scope.call(user).to_a
        records.each do |record|
          in_scope = scoped_records.include?(record)
          checked  = !!relation.check.call(user, record)
          next if in_scope == checked

          raise Placet::Error,
                "relation #{name} の check と scope が乖離: " \
                "user=#{user.inspect} record=#{record.inspect} scope=#{in_scope} check=#{checked}"
        end
      end
      true
    end
  end
end
