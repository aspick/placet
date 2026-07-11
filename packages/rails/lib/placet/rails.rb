# frozen_string_literal: true

require "placet"
require_relative "rails/version"
require_relative "rails/controller"
require_relative "rails/active_record_scope"
require_relative "rails/explain"
require_relative "rails/railtie" if defined?(::Rails::Railtie)
