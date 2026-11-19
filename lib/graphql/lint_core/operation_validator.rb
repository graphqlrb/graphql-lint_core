# frozen_string_literal: true

module GraphQL
  module LintCore
    class OperationValidator
      CODE_MAP = {
        "undefinedField" => "fields-on-correct-type",
        "argumentNotAccepted" => "known-argument-names",
        "argumentNotUnique" => "unique-argument-names",
        "argumentLiteralsIncompatible" => "value-literals-of-correct-type",
        "missingRequiredInputObjectAttribute" => "value-literals-of-correct-type",
        "defaultValueInvalidType" => "value-literals-of-correct-type",
        "defaultValueInvalidOnNonNullVariable" => "value-literals-of-correct-type",
        "missingRequiredArguments" => "provided-required-arguments",
        "undefinedDirective" => "known-directives",
        "directiveCannotBeApplied" => "known-directives",
        "directiveNotUniqueForLocation" => "unique-directives-per-location",
        "selectionMismatch" => "scalar-leafs",
        "fieldConflict" => "overlapping-fields-can-be-merged",
        "cannotSpreadFragment" => "possible-fragment-spread",
        "undefinedType" => "known-type-names",
        "infiniteLoop" => "no-fragment-cycles",
        "anonymousFragment" => "executable-definitions",
        "fragmentOnNonCompositeType" => "fragments-on-composite-type",
        "inputFieldNotUnique" => "unique-input-field-names",
        "missingQueryConfiguration" => "known-operation-types",
        "missingMutationConfiguration" => "known-operation-types",
        "missingSubscriptionConfiguration" => "known-operation-types",
        "queryContainsSchemaDefinitions" => "executable-definitions",
        "notSingleSubscription" => "one-field-subscriptions",
        "invalidOneOfInputObject" => "one-of-input-objects",
        "uniquelyNamedOperations" => "lone-anonymous-operation",
        "variableNotUnique" => "unique-variable-names",
        "variableMismatch" => "variables-in-allowed-position",
        "variableRequiresValidType" => "variables-are-input-types",
        "variableNotUsed" => "no-unused-variables",
        "variableNotDefined" => "no-undefined-variables"
      }.freeze
      DOCUMENT_RULES = %w[spec/known-fragment-names spec/no-fragment-cycles spec/executable-definitions spec/lone-anonymous-operation].freeze
      RULE_IDS = ((CODE_MAP.values.uniq + ["other"]).map { |name| "spec/#{name}" } | DOCUMENT_RULES).freeze

      EXCLUDED_RULES = [
        GraphQL::StaticValidation::FragmentNamesAreUnique,
        GraphQL::StaticValidation::FragmentsAreUsed,
        GraphQL::StaticValidation::FragmentsAreFinite
      ].freeze

      module OneOfVariableGuard
        include GraphQL::StaticValidation::OneOfInputObjectsAreValid

        private

        def validate_one_of_input_object(ast_node, context, parent_type)
          value = ast_node.arguments.first.value if ast_node.arguments.one?
          if value.is_a?(GraphQL::Language::Nodes::VariableIdentifier) && !@declared_variables.key?(value.name)
            # Older graphql-ruby dereferences the missing variable before the variable rule can report it.
            return
          end

          super
        end
      end

      VALIDATION_RULES = (GraphQL::StaticValidation::ALL_RULES - EXCLUDED_RULES).map do |rule|
        if rule == GraphQL::StaticValidation::OneOfInputObjectsAreValid &&
            Gem::Version.new(GraphQL::VERSION) < Gem::Version.new("2.6.16")
          OneOfVariableGuard
        else
          rule
        end
      end.freeze

      def initialize(loaded_schema, timeout: 5, max_errors: 100)
        @schema = loaded_schema.schema
        @timeout = timeout
        @max_errors = max_errors
        @validator = GraphQL::StaticValidation::Validator.new(schema: @schema,
          rules: VALIDATION_RULES)
      end

      def validate(document_set)
        groups = document_set.units.flat_map { |unit| validate_unit(unit) }.group_by do |diagnostic|
          [diagnostic.rule_id, diagnostic.location&.path, diagnostic.location&.line,
            diagnostic.location&.column, diagnostic.message]
        end
        groups.values.map do |diagnostics|
          first = diagnostics.first
          Diagnostic.new(rule_id: first.rule_id, severity: first.severity, message: first.message,
            message_key: first.message_key, location: first.location, related: first.related,
            operations: diagnostics.flat_map(&:operations).uniq, data: first.data, suggestion: first.suggestion)
        end.sort_by(&:sort_key)
      end

      def validate_unit(unit)
        query = GraphQL::Query.new(@schema, document: unit.document)
        @validator.validate(query, timeout: @timeout, max_errors: @max_errors).fetch(:errors).map do |error|
          diagnostic(error.to_h, unit)
        end
      end

      private

      def restore_fragment_names(value, matcher, aliases)
        case value
        when String then value.gsub(matcher) { |label| aliases.fetch(label) }
        when Array then value.map { |item| restore_fragment_names(item, matcher, aliases) }
        when Hash then value.transform_values { |item| restore_fragment_names(item, matcher, aliases) }
        else value
        end
      end

      def diagnostic(error, unit)
        unless unit.fragment_aliases.empty?
          aliases = unit.fragment_aliases
          matcher = /\b(?:#{Regexp.union(aliases.keys)})\b/
          error = restore_fragment_names(error, matcher, aliases)
        end
        extensions = error.fetch("extensions", {})
        code = extensions["code"]
        timeout = code == "validationTimeout"
        locations = error.fetch("locations", []).map do |position|
          filename = position["filename"] || unit.definition.path
          source = unit.sources[filename]
          source&.location(position["line"], position["column"]) ||
            Location.new(path: filename, line: position["line"], column: position["column"])
        end
        location, *related = locations.uniq
        Diagnostic.new(rule_id: timeout ? "core/validation-timeout" : "spec/#{CODE_MAP.fetch(code, 'other')}",
          severity: timeout ? :warning : :error, message: error.fetch("message"),
          message_key: code || "other", location: location || unit.definition.location,
          related: related.map { |other| { location: other, message: "Related document location" } },
          operations: unit.operation ? [unit.operation.display_name] : [],
          data: { code: code, path: error["path"], extensions: extensions },
          suggestion: timeout ? "Increase the validation timeout." : "Update the document to satisfy the GraphQL validation rule.")
      end
    end
  end
end
