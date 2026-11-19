# frozen_string_literal: true

require "graphql"
require_relative "lint_core/version"

module GraphQL
  module LintCore
    class InputError < StandardError; end

    ConfigError = InputError

    autoload :SchemaLoader, "graphql/lint_core/schema_loader"
    autoload :SchemaIndex, "graphql/lint_core/schema_index"
    autoload :TypeSystem, "graphql/lint_core/type_system"
    autoload :Config, "graphql/lint_core/config"
    autoload :Rule, "graphql/lint_core/rule"
    autoload :Result, "graphql/lint_core/result"
    autoload :Formatter, "graphql/lint_core/formatter"
    autoload :CLI, "graphql/lint_core/cli"
    autoload :Documents, "graphql/lint_core/documents"
    autoload :DocumentSet, "graphql/lint_core/documents"
    autoload :OperationValidator, "graphql/lint_core/operation_validator"
    autoload :TypedWalker, "graphql/lint_core/typed_walker"
    autoload :UsageIndex, "graphql/lint_core/usage_index"
    autoload :Naming, "graphql/lint_core/naming"
  end
end

require_relative "lint_core/diagnostic"
require_relative "lint_core/source_file"
require_relative "lint_core/coordinate"
require_relative "lint_core/schema_values"
