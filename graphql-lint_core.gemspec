# frozen_string_literal: true

require_relative "lib/graphql/lint_core/version"

Gem::Specification.new do |spec|
  spec.name = "graphql-lint_core"
  spec.version = GraphQL::LintCore::VERSION
  spec.authors = ["Yudai Takada"]
  spec.summary = "Shared infrastructure for the GraphQL lint suite."
  spec.homepage = "https://github.com/ydah/graphql-lint"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir.glob(["lib/**/*.rb", "exe/*", "presets/*.yml", "examples/*.yml", "LICENSE.txt", "README.md", "docs/*.md"], base: __dir__).sort
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}).map { |file| File.basename(file) }
  spec.require_paths = ["lib"]
  spec.add_dependency "graphql", ">= 2.5", "< 3.0"
end
