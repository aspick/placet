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

      rake_tasks do
        load File.expand_path("../../tasks/placet.rake", __dir__)
      end
    end
  end
end
