# frozen_string_literal: true

module Placet
  module Rails
    class Railtie < ::Rails::Railtie
      config.placet = ActiveSupport::OrderedOptions.new

      # config/placet/**/*.rb（1 ファイル 1 ポリシー + actions.rb 等）を起動時にロードする。
      # 定義の不備は DefinitionError となり、起動が失敗する（fail fast）
      initializer "placet.load_definitions", after: :load_config_initializers do |app|
        paths = app.config.placet.definition_paths ||
                [app.root.join("config", "placet", "**", "*.rb").to_s]
        paths.flat_map { |pattern| Dir[pattern.to_s].sort }.each { |file| load file }
      end

      # 再チェック（Placet.recheck / placet_recheck）で乖離を検出したときの既定通知
      initializer "placet.recheck_divergence_logging" do
        Placet.on_recheck_divergence ||= lambda do |_user, action, record|
          ::Rails.logger.warn(
            "placet: scope と check の乖離を検出 action=#{action} " \
            "record=#{record.class}##{record.respond_to?(:id) ? record.id : record.inspect}"
          )
        end
      end

      rake_tasks do
        load File.expand_path("../../tasks/placet.rake", __dir__)
      end
    end
  end
end
