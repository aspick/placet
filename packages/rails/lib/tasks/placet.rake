# frozen_string_literal: true

namespace :placet do
  desc "コンパイル済みの正規形（canonical form）を JSON で出力する"
  task export: :environment do
    require "json"
    puts JSON.pretty_generate(Placet.export)
  end

  desc "コントローラの宣言から エンドポイント → 必要権限 の一覧を出力する"
  task endpoints: :environment do
    Rails.application.eager_load!
    controllers = ActionController::Base.descendants
                                        .select { |c| c.respond_to?(:placet_declarations) }
                                        .sort_by(&:name)
    controllers.each do |controller|
      controller.placet_declarations.sort.each do |action_name, declarations|
        declarations.each do |decl|
          mode = decl[:via] == :scope ? "(scoped)" : "(403)"
          puts format("%-40s %-30s %s", "#{controller.name}##{action_name}", decl[:actions].join(" AND "), mode)
        end
      end
      controller.placet_public_actions.each do |action_name|
        puts format("%-40s %-30s %s", "#{controller.name}##{action_name}", "-", "(public)")
      end
    end
  end
end
