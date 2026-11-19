# frozen_string_literal: true

module GraphQL
  module LintCore
    # @api public
    class TypeRef
      attr_reader :named, :wrappers

      def self.from(node, index: nil)
        wrappers = []
        while node.respond_to?(:of_type)
          kind = node.is_a?(GraphQL::Language::Nodes::NonNullType) ? :non_null : :list
          wrappers << kind
          node = node.of_type
        end
        new(named: node&.name, wrappers: wrappers, index: index)
      end

      def initialize(named:, wrappers: [], index: nil)
        @named, @wrappers = named, wrappers.freeze
        @index = index
        freeze
      end

      def non_null? = wrappers.first == :non_null
      def list? = wrappers.include?(:list)
      def named_type_info = @index&.types&.[](named)

      def to_s
        wrappers.reverse_each.reduce(named.to_s) { |type, wrapper| wrapper == :list ? "[#{type}]" : "#{type}!" }
      end
    end

    # @api public
    class Value
      Nodes = GraphQL::Language::Nodes
      attr_reader :literal, :value

      def initialize(node)
        @literal, @value = canonical(node)
      end

      def to_s = literal.to_s

      private

      def canonical(node)
        case node
        when Nodes::InputObject
          entries = node.arguments.sort_by(&:name).map { |arg| [arg.name, *canonical(arg.value)] }
          ["{#{entries.map { |name, literal, _| "#{name}: #{literal}" }.join(", ")}}",
            entries.to_h { |name, _, value| [name, value] }]
        when Array
          entries = node.map { |value| canonical(value) }
          ["[#{entries.map(&:first).join(", ")}]", entries.map(&:last)]
        when Nodes::Enum then [node.name, node.name]
        when Nodes::NullValue then ["null", nil]
        when Float then [node.finite? ? JSON.generate(node) : node.to_s, node]
        else [JSON.generate(node), node]
        end
      end
    end

    # @api public
    class DefaultValue < Value
      def initialize(node = nil)
        @present = !node.nil?
        super if @present
        freeze
      end

      def present? = @present
    end
  end
end
