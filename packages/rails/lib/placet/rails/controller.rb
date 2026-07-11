# frozen_string_literal: true

require "active_support/concern"

module Placet
  module Rails
    # placet_verify! が enforcement 漏れを検出したときに送出される
    class VerificationError < Placet::Error; end

    # コントローラ統合（PEP ヘルパー。docs/rails-usage.md Section 4）
    #
    #   class ApplicationController < ActionController::Base
    #     include Placet::Rails::Controller
    #     placet_verify!
    #   end
    #
    #   class PostsController < ApplicationController
    #     before_action :set_post, only: %i[update destroy]
    #     placet_resource Post
    #     placet_permit "post:publish", only: :publish, resource: -> { @post }
    #   end
    module Controller
      extend ActiveSupport::Concern

      included do
        class_attribute :placet_declarations, default: {}, instance_writer: false
        class_attribute :placet_public_actions, default: [], instance_writer: false
        class_attribute :placet_verify_enabled, default: false, instance_writer: false
        helper_method :placet_permit?, :placet_user if respond_to?(:helper_method)
      end

      class_methods do
        # action ごとの権限宣言。
        # via: :check  — before_action として authorize! を実行（403）
        # via: :scope  — placet_scope で合成済みコレクションを取得（絞り込み / 404）
        # 複数 action は AND。via: :scope は単一 action のみ（docs/rails-usage.md 4.2）
        def placet_permit(actions, only:, via: :check, resource: nil, model: nil)
          actions = Array(actions).map(&:to_s)
          if via == :scope && actions.size > 1
            raise Placet::DefinitionError, "via: :scope の宣言は単一 action のみ: #{actions.inspect}"
          end

          declaration = { actions: actions, via: via, resource: resource, model: model }
          merged = Array(only).map(&:to_s).to_h { |name| [name, (placet_declarations[name] || []) + [declaration]] }
          self.placet_declarations = placet_declarations.merge(merged)

          return unless via == :check

          before_action(only: only) do
            target = resource && instance_exec(&resource)
            Placet.authorize!(placet_user, actions, target)
          end
        end

        # RESTful CRUD の規約展開（docs/rails-usage.md 4.1）。
        # index/show → <resource>:view (scope)、create/update/destroy → check。
        # リソースのロードは肩代わりしない: update/destroy は @<resource> を参照する
        def placet_resource(model)
          name = model.name.underscore
          ref = -> { instance_variable_get(:"@#{name}") }
          placet_permit "#{name}:view",   only: %i[index show], via: :scope, model: model
          placet_permit "#{name}:create", only: :create
          placet_permit "#{name}:update", only: :update,  resource: ref
          placet_permit "#{name}:delete", only: :destroy, resource: ref
        end

        # 認可不要のエンドポイントを明示的にオプトアウトする（verify の対象から外す唯一の方法）
        def placet_public(only:)
          self.placet_public_actions = placet_public_actions + Array(only).map(&:to_s)
        end

        # enforcement（authorize! / scoped）が一度も行われずにアクションが終わったら raise。
        # development / test で必ず有効化することを推奨（docs/rails-usage.md 4.4）
        def placet_verify!
          return if placet_verify_enabled

          self.placet_verify_enabled = true
          prepend_before_action { @_placet_enforcements_before = Placet.enforcements }
          after_action :placet_verify_enforcement!
        end
      end

      # アプリ側で上書き可能。既定は current_user
      def placet_user = current_user

      # via: :scope の宣言から合成済みコレクション（AR なら Relation）を返す
      def placet_scope(model = nil)
        declaration = (placet_declarations[action_name] || []).find { |d| d[:via] == :scope }
        raise Placet::Error, "#{self.class.name}##{action_name} に via: :scope の宣言がない" unless declaration

        action = declaration[:actions].first
        target = model || declaration[:model] || action.split(":", 2).first.camelize.constantize
        Placet.scoped(placet_user, action, model: target)
      end

      # 表示制御用。enforcement にはカウントされない
      def placet_permit?(actions, resource = nil) = Placet.permit?(placet_user, actions, resource)

      private

      def placet_verify_enforcement!
        return if placet_public_actions.include?(action_name)
        return if Placet.enforcements > (@_placet_enforcements_before || 0)

        raise VerificationError,
              "#{self.class.name}##{action_name} で認可が行われていない。" \
              "placet_permit / placet_resource で宣言するか、placet_scope / Placet.authorize! を呼ぶか、" \
              "認可不要なら placet_public で明示すること"
      end
    end
  end
end
