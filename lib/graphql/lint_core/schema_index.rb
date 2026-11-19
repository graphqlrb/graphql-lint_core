# frozen_string_literal: true

module GraphQL
  module LintCore
    # @api public
    class SchemaMember
      attr_reader :name, :node, :owner, :coordinate, :location, :description,
        :description_style, :directives, :name_location

      def initialize(index, name:, node: nil, owner: nil, coordinate: name, nodes: [node], builtin: false)
        @index, @node, @owner, @name, @coordinate = index, node, owner, name, coordinate
        @builtin = builtin
        source = index.source(node)
        @location = source&.location(node)
        @name_location = source&.name_location(node)
        @description = node.description if node.respond_to?(:description)
        @description_style = source&.description_style(node)
        applications = nodes.compact.flat_map(&:directives)
        @directives = applications.each_with_index.map do |directive, position|
          DirectiveApplication.new(name: directive.name,
            arguments: directive.arguments.to_h { |arg| [arg.name, Value.new(arg.value)] },
            target: self, index: position, location: index.source(directive)&.location(directive), node: directive)
        end.freeze
      end

      def builtin? = @builtin || owner&.builtin? || false
      def prelude? = @index.source(node)&.prelude? || owner&.prelude? || false
      def graphql_member = @index.schema&.find(coordinate)

      def deprecation
        directive = directives.find { |item| item.name == "deprecated" }
        return unless directive

        reason = directive.arguments.fetch("reason", nil)
        Deprecation.new(reason: reason.nil? ? "No longer supported" : reason.value,
          location: directive.location, explicit: directive.arguments.key?("reason"))
      end

      Deprecation = Struct.new(:reason, :location, :explicit, keyword_init: true) do
        def explicit? = explicit
      end
    end

    # @api public
    DirectiveApplication = Struct.new(:name, :arguments, :target, :index, :location, :node, keyword_init: true)

    # @api public
    class TypeInfo < SchemaMember
      attr_reader :kind, :fields, :input_fields, :values, :interfaces, :extension_locations, :root_kind
      attr_accessor :position, :possible_types

      def initialize(index, name:, kind:, node: nil, extensions: [], builtin: false)
        nodes = [node, *extensions].compact
        super(index, name: name, node: node, nodes: nodes, builtin: builtin)
        @kind = kind
        @root_kind = index.roots.key(name)&.to_sym
        @interfaces = collect(nodes, :interfaces).map(&:name).freeze
        @possible_types = collect(nodes, :types).map(&:name).freeze
        members = collect(nodes, :fields)
        @fields = kind == :input_object ? {}.freeze : build_members(index, members, FieldInfo)
        @input_fields = kind == :input_object ? build_members(index, members, InputValueInfo) : {}.freeze
        @values = build_members(index, collect(nodes, :values), EnumValueInfo)
        @extension_locations = extensions.filter_map { |ext| index.source(ext)&.location(ext) }.freeze
        @position = :unreachable
      end

      def one_of? = directives.any? { |directive| directive.name == "oneOf" }
      def specified_by_url = directives.find { |item| item.name == "specifiedBy" }&.arguments&.fetch("url", nil)&.value
      def reachable? = position != :unreachable
      def field(name) = fields[name]

      private

      def collect(nodes, attribute)
        nodes.flat_map { |node| node.respond_to?(attribute) ? node.public_send(attribute) : [] }
      end

      def build_members(index, members, klass)
        members.to_h { |node| [node.name, klass.new(index, name: node.name, node: node, owner: self, coordinate: "#{name}.#{node.name}")] }.freeze
      end
    end

    # @api public
    class FieldInfo < SchemaMember
      attr_reader :type, :arguments

      def initialize(index, **attributes)
        super
        @type = TypeRef.from(node.type, index: index)
        @arguments = node.arguments.to_h do |arg|
          [arg.name, InputValueInfo.new(index, name: arg.name, node: arg, owner: self, coordinate: "#{coordinate}(#{arg.name}:)")]
        end.freeze
      end

      def root_kind = owner.root_kind
    end

    # @api public
    class InputValueInfo < SchemaMember
      attr_reader :type, :default_value

      def initialize(index, **attributes)
        super
        @type = TypeRef.from(node.type, index: index)
        @default_value = DefaultValue.new(node.default_value)
      end

      def required? = type.non_null? && !default_value.present?
    end

    # @api public
    class EnumValueInfo < SchemaMember; end

    # @api public
    class DirectiveInfo < SchemaMember
      EXECUTABLE = %w[QUERY MUTATION SUBSCRIPTION FIELD FRAGMENT_DEFINITION FRAGMENT_SPREAD INLINE_FRAGMENT VARIABLE_DEFINITION].freeze
      attr_reader :locations, :arguments

      def initialize(index, node:, builtin: false)
        super(index, name: node.name, node: node, coordinate: "@#{node.name}", nodes: [], builtin: builtin)
        @locations = node.locations.map(&:name).freeze
        @arguments = node.arguments.to_h do |arg|
          [arg.name, InputValueInfo.new(index, name: arg.name, node: arg, owner: self, coordinate: "#{coordinate}(#{arg.name}:)")]
        end.freeze
      end

      def repeatable? = !!node.repeatable
      def executable? = locations.intersect?(EXECUTABLE)
      def type_system? = (locations - EXECUTABLE).any?
    end

    # @api public
    class SchemaIndex
      Nodes = GraphQL::Language::Nodes
      ROOTS = %w[query mutation subscription].freeze
      SCALARS = %w[Int Float String Boolean ID].freeze
      KINDS = %i[object interface union enum input_object scalar].to_h do |kind|
        prefix = kind.to_s.split("_").map(&:capitalize).join
        [prefix + "Type", kind]
      end.freeze
      STANDARD_DIRECTIVES = GraphQL.parse(<<~GRAPHQL).definitions.freeze
        directive @skip(if: Boolean!) on FIELD | FRAGMENT_SPREAD | INLINE_FRAGMENT
        directive @include(if: Boolean!) on FIELD | FRAGMENT_SPREAD | INLINE_FRAGMENT
        directive @deprecated(reason: String = "No longer supported") on FIELD_DEFINITION | ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION | ENUM_VALUE
        directive @specifiedBy(url: String!) on SCALAR
        directive @oneOf on INPUT_OBJECT
      GRAPHQL
      INTROSPECTION_TYPES = GraphQL::Language::DocumentFromSchemaDefinition.new(
        GraphQL::Schema, include_introspection_types: true
      ).document.definitions.select { |node| node.respond_to?(:name) && node.name.start_with?("__") }.freeze

      attr_reader :types, :directives, :roots, :schema_location, :schema_description,
        :schema_directives, :reverse_references, :implementations
      attr_accessor :schema

      def self.kind(node)
        KINDS[node.class.name.split("::").last.sub(/(?:Definition|Extension)\z/, "")]
      end

      def initialize(document, sources)
        @sources = sources.to_h { |file| [file.path, file] }
        definitions = document.definitions
        schema_definitions = definitions.grep(Nodes::SchemaDefinition)
        schema_extensions = definitions.grep(Nodes::SchemaExtension)
        type_definitions = definitions.select { |node| self.class.kind(node) && !extension?(node) }
        extension_groups = definitions.select { |node| self.class.kind(node) && extension?(node) }.group_by(&:name)
        @roots = root_names(schema_definitions, schema_extensions, type_definitions)
        schema_nodes = schema_definitions + schema_extensions
        schema_node = schema_nodes.first
        schema_member = SchemaMember.new(self, name: "schema", node: schema_node, coordinate: nil, nodes: schema_nodes)
        @schema_location, @schema_directives = schema_member.location, schema_member.directives
        @schema_description = source(schema_node)&.schema_description(schema_node)
        @types = SCALARS.to_h { |name| [name, TypeInfo.new(self, name: name, kind: :scalar, builtin: true)] }
        INTROSPECTION_TYPES.each do |node|
          @types[node.name] = TypeInfo.new(self, name: node.name, kind: self.class.kind(node), node: node, builtin: true)
        end
        type_definitions.each do |node|
          kind = self.class.kind(node)
          extensions = extension_groups.fetch(node.name, []).select { |extension| self.class.kind(extension) == kind }
          @types[node.name] = TypeInfo.new(self, name: node.name, kind: kind, node: node, extensions: extensions)
        end
        @directives = STANDARD_DIRECTIVES.to_h { |node| [node.name, DirectiveInfo.new(self, node: node, builtin: true)] }
        definitions.grep(Nodes::DirectiveDefinition).each { |node| @directives[node.name] = DirectiveInfo.new(self, node: node) }
        @coordinates = {}
        index_members
        index_relationships
        @types.freeze
        @directives.freeze
      end

      def source(node) = @sources[node&.filename]

      def find(coordinate)
        @coordinates[coordinate]
      end

      private

      def extension?(node) = node.class.name.end_with?("Extension")

      def root_names(definitions, extensions, types)
        names = if definitions.empty?
          ROOTS.filter_map { |root| [root, root.capitalize] if types.any? { |node| node.name == root.capitalize } }.to_h
        else
          {}
        end
        (definitions + extensions).each do |node|
          ROOTS.each { |root| names[root] = node.public_send(root) if node.public_send(root) }
        end
        names.freeze
      end

      def index_members
        types.each_value do |type|
          @coordinates[type.coordinate] = type
          type.fields.each_value do |field|
            @coordinates[field.coordinate] = field
            field.arguments.each_value { |arg| @coordinates[arg.coordinate] = arg }
          end
          type.input_fields.each_value { |field| @coordinates[field.coordinate] = field }
          type.values.each_value { |value| @coordinates[value.coordinate] = value }
        end
        directives.each_value do |directive|
          @coordinates[directive.coordinate] = directive
          directive.arguments.each_value { |arg| @coordinates[arg.coordinate] = arg }
        end
      end

      def index_relationships
        @reverse_references = Hash.new { |hash, key| hash[key] = [] }
        @implementations = Hash.new { |hash, key| hash[key] = [] }
        types.each_value do |type|
          seen = {}
          pending = type.interfaces.dup
          until pending.empty?
            name = pending.pop
            next if seen[name]
            seen[name] = true
            @implementations[name] << type.name
            pending.concat(types[name]&.interfaces || [])
          end
          type_dependencies(type).each { |name, _, member| @reverse_references[name] << member }
        end
        @implementations.each do |name, implementations|
          types[name].possible_types = implementations.select { |other| types[other].kind == :object }.freeze if types[name]&.kind == :interface
        end
        mark_reachable
      end

      def type_dependencies(type)
        members = (type.interfaces + type.possible_types).map { |name| [name, :output, type] }
        type.fields.each_value do |field|
          members << [field.type.named, :output, field]
          field.arguments.each_value { |arg| members << [arg.type.named, :input, arg] }
        end
        type.input_fields.each_value { |field| members << [field.type.named, :input, field] }
        members
      end

      def mark_reachable
        work = roots.values.map { |name| [name, :output] }
        directives.each_value do |directive|
          if directive.executable?
            directive.arguments.each_value { |arg| work << [arg.type.named, :input] }
          end
        end
        @coordinates.each_value do |member|
          member.directives.each do |application|
            directives[application.name]&.arguments&.each_value { |arg| work << [arg.type.named, :input] }
          end
        end
        schema_directives.each do |application|
          directives[application.name]&.arguments&.each_value { |arg| work << [arg.type.named, :input] }
        end
        until work.empty?
          name, side = work.pop
          type = types[name]
          next if !type || type.position == side || type.position == :both
          type.position = type.reachable? ? :both : side
          type_dependencies(type).each { |target, position, _| work << [target, position] }
        end
      end
    end
  end
end
