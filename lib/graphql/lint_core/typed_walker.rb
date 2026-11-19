# frozen_string_literal: true


module GraphQL
  module LintCore
    class TypedWalker
      Nodes = GraphQL::Language::Nodes
      Frame = Data.define(:document_definition, :parent_type, :path, :ancestors, :active_fragments)
      Event = Data.define(:node, :location, :definition, :parent_type, :type, :operations, :path,
        :depth, :fragment_chain, :document_definition, :operation, :ancestors) do
        def coordinate = (definition.coordinate if definition.respond_to?(:coordinate))
        def name_location = document_definition.source.name_location(node)
        def response_key = node.alias || node.name
      end

      def initialize(index, document_set)
        @index = index
        @set = document_set
      end

      def walk(definition, expand_fragments: false, &callback)
        return enum_for(__method__, definition, expand_fragments: expand_fragments) unless callback

        traversal = Traversal.new(@index, @set, definition, expand_fragments, callback)
        traversal.run
      end

      class Traversal
        def initialize(index, set, definition, expand, callback)
          @index = index
          @set = set
          @definition = definition
          @expand = expand
          @callback = callback
        end

        def run
          node = @definition.node
          parent = @definition.operation? ? root_type(node.operation_type) : type(node.type.name)
          frame = Frame.new(document_definition: @definition, parent_type: parent,
            path: ["#{@definition.kind} #{@definition.display_name}"], ancestors: [],
            active_fragments: @definition.fragment? ? [@definition] : [])
          walk_definition(frame)
        end

        private

        def walk_definition(frame, incoming_type: frame.parent_type)
          definition = frame.document_definition
          node = definition.node
          kind = definition.operation? ? :operation : :fragment_definition
          visit(kind, node, frame, definition: frame.parent_type, type: frame.parent_type, parent_type: incoming_type) do
            Array(node.respond_to?(:variables) ? node.variables : nil).each do |variable|
              reference = TypeRef.from(variable.type)
              variable_frame = frame.with(path: frame.path + ["$#{variable.name}"])
              visit(:variable_definition, variable, variable_frame, definition: type(reference.named), type: reference) do
                walk_directives(variable, variable_frame)
                walk_value(variable.default_value, reference, variable_frame)
              end
            end
            walk_directives(node, frame)
            walk_selections(node.selections, frame)
          end
        end

        def walk_selections(selections, frame)
          selections.each do |selection|
            case selection
            when Nodes::Field then walk_field(selection, frame)
            when Nodes::InlineFragment then walk_inline_fragment(selection, frame)
            when Nodes::FragmentSpread then walk_spread(selection, frame)
            end
          end
        end

        def walk_field(node, frame)
          definition = frame.parent_type&.fields&.[](node.name) || introspection_field(node, frame)
          output = definition ? type(definition.type.named) : nil
          current = frame.with(path: frame.path + [node.alias || node.name], ancestors: frame.ancestors + [node])
          visit(:field, node, current, definition: definition, type: output) do
            walk_arguments(node.arguments, definition&.arguments, current)
            walk_directives(node, current)
            walk_selections(node.selections, current.with(parent_type: output))
          end
        end

        def introspection_field(node, frame)
          return unless @index && frame.parent_type

          case node.name
          when "__typename"
            TypeRef.new(named: "String", wrappers: [:non_null]).then do |reference|
              IntrospectionField.new(type: reference, arguments: {})
            end
          when "__schema", "__type"
            return unless frame.parent_type == root_type("query")

            name = node.name == "__schema" ? "__Schema" : "__Type"
            IntrospectionField.new(type: TypeRef.new(named: name), arguments: {})
          end
        end

        def walk_inline_fragment(node, frame)
          condition = node.type ? type(node.type.name) : frame.parent_type
          current = frame.with(parent_type: condition)
          visit(:inline_fragment, node, frame, definition: node.type ? condition : nil, type: condition) do
            walk_directives(node, current)
            walk_selections(node.selections, current)
          end
        end

        def walk_spread(node, frame)
          target = @set.resolve(node)
          current = frame.with(path: frame.path + ["...#{node.name}"])
          visit(:fragment_spread, node, current, definition: target) do
            walk_directives(node, current)
            if @expand && target && !frame.active_fragments.include?(target)
              walk_definition(current.with(document_definition: target, parent_type: type(target.node.type.name),
                active_fragments: frame.active_fragments + [target]), incoming_type: frame.parent_type)
            end
          end
        end

        def walk_directives(node, frame)
          return unless node.respond_to?(:directives)

          node.directives.each do |directive|
            definition = @index&.directives&.[](directive.name)
            current = frame.with(path: frame.path + ["@#{directive.name}"])
            visit(:directive, directive, current, definition: definition) do
              walk_arguments(directive.arguments, definition&.arguments, current)
            end
          end
        end

        def walk_arguments(arguments, definitions, frame)
          arguments.each do |argument|
            definition = definitions&.[](argument.name)
            current = frame.with(path: frame.path + [argument.name])
            visit(:argument, argument, current, definition: definition, type: definition&.type) do
              walk_value(argument.value, definition&.type, current)
            end
          end
        end

        def walk_value(value, expected, frame)
          wrappers = expected&.wrappers&.drop_while { |wrapper| wrapper == :non_null }
          if wrappers&.first == :list
            element = TypeRef.new(named: expected.named, wrappers: wrappers.drop(1))
            items = value.is_a?(Array) ? value : [value]
            items.each_with_index do |item, index|
              walk_value(item, element, frame.with(path: frame.path + [index]))
            end
            return
          end

          value_type = type(expected&.named)
          case value
          when Array
            value.each_with_index { |item, index| walk_value(item, nil, frame.with(path: frame.path + [index])) }
          when Nodes::InputObject
            visit(:input_object, value, frame, definition: value_type, type: value_type) do
              value.arguments.each do |member|
                definition = value_type&.input_fields&.[](member.name)
                current = frame.with(path: frame.path + [member.name])
                visit(:input_object_field, member, current, definition: definition, type: definition&.type) do
                  walk_value(member.value, definition&.type, current)
                end
              end
            end
          when Nodes::Enum
            visit(:enum_literal, value, frame, definition: value_type&.values&.[](value.name), type: value_type)
          end
        end

        def visit(kind, node, frame, definition: nil, type: nil, parent_type: frame.parent_type)
          document_definition = frame.document_definition
          source = document_definition.source
          operation = @definition.operation? ? @definition.display_name : nil
          event = Event.new(node: node, location: source.location(node),
            definition: definition, parent_type: parent_type, type: type,
            operations: @expand && operation ? [operation] : @set.operations_for(document_definition),
            path: frame.path, depth: frame.ancestors.size, fragment_chain: frame.active_fragments.map(&:name),
            document_definition: document_definition, operation: operation, ancestors: frame.ancestors)
          @callback.call(:"enter_#{kind}", event)
          yield if block_given?
          @callback.call(:"leave_#{kind}", event)
        end

        def type(name)
          @index&.types&.[](name)
        end

        def root_type(kind)
          type(@index&.roots&.[](kind) || @index&.roots&.[](kind.to_sym))
        end
      end

      IntrospectionField = Data.define(:type, :arguments)
      private_constant :Frame, :Traversal, :IntrospectionField
    end
  end
end
