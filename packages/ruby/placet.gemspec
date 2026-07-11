# frozen_string_literal: true

require_relative "lib/placet/version"

Gem::Specification.new do |spec|
  spec.name    = "placet"
  spec.version = Placet::VERSION
  spec.authors = ["Yugo TERADA"]

  spec.summary     = "Declarative authorization library — simplified IAM-style policy evaluation " \
                     "(concept phase; placeholder release)"
  spec.description = "placet is a declarative authorization library that brings a simplified " \
                     "AWS IAM-style model (principals, policy attachments, deny-overrides, " \
                     "implicit deny) to ordinary applications. This version is a placeholder " \
                     "to reserve the gem name while the specification is being designed."
  spec.homepage = "https://github.com/aspick/placet"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files         = ["lib/placet.rb", "lib/placet/version.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
