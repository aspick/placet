# frozen_string_literal: true

module Placet
  class Error < StandardError; end

  # 定義（Policy / attachment / relation）の不備。起動時に検出される
  class DefinitionError < Error; end

  # authorize! が拒否されたときに送出される。decision に根拠が入る
  class Denied < Error
    attr_reader :action, :decision

    def initialize(action, decision)
      @action = action
      @decision = decision
      super("denied: #{action} (#{decision.basis})")
    end
  end
end
