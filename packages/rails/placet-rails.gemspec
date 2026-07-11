# frozen_string_literal: true

require_relative "lib/placet/rails/version"

Gem::Specification.new do |spec|
  spec.name    = "placet-rails"
  spec.version = Placet::Rails::VERSION
  spec.authors = ["Yugo TERADA"]

  spec.summary     = "Rails adapter for placet — declarative per-action authorization " \
                     "and ActiveRecord scope composition"
  spec.description = "placet-rails integrates the placet authorization library with Rails: " \
                     "per-action permission declarations (placet_permit / placet_resource), " \
                     "an enforcement verification hook, and mapping of placet scope plans " \
                     "onto ActiveRecord relations for list filtering."
  spec.homepage = "https://github.com/aspick/placet"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files         = Dir["lib/**/*.{rb,rake}"] + ["README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "placet", ">= 0.0.1"
  spec.add_dependency "actionpack", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "railties", ">= 7.1"
end
