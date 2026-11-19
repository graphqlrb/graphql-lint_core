# frozen_string_literal: true

module GraphQL
  module LintCore
    class UsageIndex
      Reference = Data.define(:coordinate, :kind, :via, :return_type, :operation, :fragment_chain, :location, :node,
        :operation_definition, :definition, :path, :parent_type)
      EVENTS = {
        enter_fragment_definition: [:type, :type_condition],
        enter_inline_fragment: [:type, :type_condition],
        enter_variable_definition: [:type, :variable_type],
        enter_input_object: [:type, :literal],
        enter_field: [:field, :selection],
        enter_argument: [:argument, :literal],
        enter_input_object_field: [:input_field, :literal],
        enter_enum_literal: [:enum_value, :literal],
        enter_directive: [:directive, :selection]
      }.freeze

      attr_reader :references

      def initialize(schema_index, document_set)
        @references = []
        @coordinates = Hash.new { |hash, key| hash[key] = [] }
        walker = TypedWalker.new(schema_index, document_set)
        document_set.operations.each { |definition| collect(walker, definition, expand: true) }
        document_set.fragments.each do |definition|
          collect(walker, definition, expand: false) if document_set.operations_for(definition).empty?
        end
      end

      def for_coordinate(coordinate)
        @coordinates.fetch(coordinate, [])
      end

      private

      def collect(walker, definition, expand:)
        walker.walk(definition, expand_fragments: expand) do |event_type, event|
          kind, via = EVENTS[event_type]
          next unless kind && event.coordinate

          kind = :directive_argument if kind == :argument && event.coordinate.start_with?("@")
          reference = Reference.new(coordinate: event.coordinate, kind: kind, via: via,
            return_type: kind == :field ? event.definition.type.named : nil,
            operation: event.operation, fragment_chain: event.fragment_chain,
            location: event.location, node: event.node, operation_definition: definition.operation? ? definition : nil,
            definition: event.definition, path: event.path, parent_type: event.parent_type)
          @references << reference
          @coordinates[reference.coordinate] << reference
        end
      end
    end
  end
end
