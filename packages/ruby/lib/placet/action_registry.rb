# frozen_string_literal: true

require "set"

module Placet
  # 既知の action を宣言して typo を検出するレジストリ（docs/rails-usage.md 2.5）。
  # 評価セマンティクスに影響しない lint であり、正規形（version 1）には含まれない
  # ランタイム機能なので、Definition（正規形と 1:1）ではなくランタイムが所有する
  class ActionRegistry
    def initialize
      @by_resource = {}
    end

    def add(resource, operations)
      (@by_resource[resource] ||= Set.new).merge(operations)
    end

    # 宣言が 1 つもない場合、レジストリは未使用（lint 無効）として扱う
    def empty? = @by_resource.empty?

    # 具体的な action の照合
    def known_action?(action)
      return true if empty?

      resource, operation = action.split(":", 2)
      @by_resource.key?(resource) && @by_resource[resource].include?(operation)
    end

    # パターン（ワイルドカード可）の照合
    def known_pattern?(pattern)
      return true if empty? || pattern == "*"

      resource, operation = pattern.split(":", 2)
      return false if resource != "*" && !@by_resource.key?(resource)
      return true if operation == "*"

      if resource == "*"
        @by_resource.values.any? { |ops| ops.include?(operation) }
      else
        @by_resource[resource].include?(operation)
      end
    end
  end
end
