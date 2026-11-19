# frozen_string_literal: true

require "psych"

module GraphQL
  module LintCore
    class TypeSystem
      Nodes = GraphQL::Language::Nodes
      CHECKS = (1..16).map { |number| format("TS-%02d", number) }.freeze
      INPUT_KINDS = %i[scalar enum input_object].freeze
      OUTPUT_KINDS = %i[scalar enum object interface union].freeze
      DIRECTIVE_LOCATIONS = GraphQL::Schema::Directive::LOCATIONS.map(&:to_s).freeze
      MESSAGES = %w[en ja].to_h do |locale|
        path = File.expand_path("../../../locales/#{locale}.yml", __dir__)
        [locale, Psych.safe_load_file(path).fetch("type_system").freeze]
      end.freeze

      def initialize(document, index, skip: [], locale: "en")
        @document = document
        @index = index
        @skipped = Array(skip)
        @locale = locale
        @diagnostics = []
        unknown = @skipped - CHECKS
        raise InputError, "Unknown schema checks: #{unknown.join(", ")}." unless unknown.empty?
      end

      def validate
        definitions
        roots
        @index.types.each_value { |type| validate_type(type) unless type.builtin? }
        @index.directives.each_value { |directive| validate_directive(directive) unless directive.builtin? }
        applications(@index.schema_directives, "SCHEMA")
        cycles(:interface, "TS-16") { |type| type.interfaces }
        cycles(:input_object, "TS-14") do |type|
          type.input_fields.values.filter_map { |field| field.type.named if field.type.non_null? && !field.type.list? }
        end
        @diagnostics
      end

      private

      def definitions
        types = Hash.new { |hash, key| hash[key] = [] }
        extensions = []
        directives = []
        @document.definitions.each do |node|
          if node.is_a?(Nodes::DirectiveDefinition)
            directives << node
          elsif SchemaIndex.kind(node)
            if node.class.name.end_with?("Extension")
              extensions << node
            else
              types[node.name] << node
            end
          elsif !node.is_a?(Nodes::SchemaDefinition) && !node.is_a?(Nodes::SchemaExtension)
            report("TS-01", :executable_definition, node)
          end
        end
        types.each_value do |nodes|
          duplicates(nodes, "TS-01")
          if SchemaIndex::SCALARS.include?(nodes.first.name)
            report("TS-15", :builtin_scalar, nodes.first, name: nodes.first.name)
          end
        end
        duplicates(directives)
        directives.each do |node|
          duplicates(node.arguments)
          if SchemaIndex::STANDARD_DIRECTIVES.any? { |directive| directive.name == node.name }
            report("TS-15", :builtin_directive, node, name: node.name)
          end
        end
        extensions.each do |node|
          base = types[node.name].first
          unless base && SchemaIndex.kind(base) == SchemaIndex.kind(node)
            report("TS-04", :invalid_extension, node, name: node.name)
          end
        end
        (types.values.flatten + extensions).group_by(&:name).each_value do |nodes|
          %i[fields values interfaces types].each do |key|
            items = nodes.flat_map { |node| node.respond_to?(key) ? node.public_send(key) : [] }
            duplicates(items, key == :types ? "TS-07" : "TS-02")
            items.each { |item| duplicates(item.arguments) if item.respond_to?(:arguments) }
          end
        end
      end

      def roots
        schemas = @document.definitions.grep(Nodes::SchemaDefinition)
        extensions = @document.definitions.grep(Nodes::SchemaExtension)
        schemas.drop(1).each { |node| report("TS-08", :duplicate_schema, node) }
        SchemaIndex::ROOTS.each do |root|
          nodes = (schemas + extensions).select { |node| node.public_send(root) }
          nodes.drop(1).each { |node| report("TS-08", :duplicate_root, node, root: root) }
        end
        roots = @index.roots
        report("TS-08", :missing_query_root, schemas.first) unless roots.key?("query")
        unless roots.values.uniq.size == roots.size
          report("TS-08", :shared_root_type, schemas.first)
        end
        roots.each do |operation, name|
          unless @index.types[name]&.kind == :object
            report("TS-08", :invalid_root_type, @index.types[name]&.node || schemas.first, operation: operation, name: name)
          end
        end
      end

      def validate_type(type)
        validate_name(type)
        location = type.kind == :input_object ? "INPUT_OBJECT" : type.kind.to_s.upcase
        applications(type.directives, location)
        case type.kind
        when :object, :interface
          nonempty(type, type.fields)
          type.fields.each_value { |field| validate_field(field) }
          validate_interfaces(type)
        when :input_object
          nonempty(type, type.input_fields)
          type.input_fields.each_value do |field|
            validate_input(field, "INPUT_FIELD_DEFINITION")
            if type.one_of? && (field.type.non_null? || field.default_value.present?)
              report("TS-12", :invalid_one_of_field, field.node, field.coordinate, coordinate: field.coordinate)
            end
          end
        when :enum
          nonempty(type, type.values)
          type.values.each_value do |member|
            validate_name(member)
            if %w[true false null].include?(member.name)
              report("TS-11", :reserved_enum_value, member.node, name: member.name)
            end
            applications(member.directives, "ENUM_VALUE")
          end
        when :union
          report("TS-07", :empty_union, type.node, name: type.name) if type.possible_types.empty?
          type.possible_types.each do |name|
            target = @index.types[name]
            if target.nil?
              report("TS-03", :unknown_type, type.node, type.coordinate, name: name)
            elsif target.kind != :object
              report("TS-07", :invalid_union_member, type.node, type.coordinate, name: name)
            end
          end
        end
      end

      def validate_directive(directive)
        validate_name(directive)
        if directive.locations.empty? || directive.locations.uniq != directive.locations || (directive.locations - DIRECTIVE_LOCATIONS).any?
          report("TS-09", :invalid_directive_locations, directive.node, coordinate: directive.coordinate)
        end
        directive.arguments.each_value { |arg| validate_input(arg, "ARGUMENT_DEFINITION") }
      end

      def validate_field(field)
        validate_name(field)
        type_position(field, OUTPUT_KINDS)
        applications(field.directives, "FIELD_DEFINITION")
        field.arguments.each_value { |arg| validate_input(arg, "ARGUMENT_DEFINITION") }
      end

      def validate_input(field, location)
        validate_name(field)
        type_position(field, INPUT_KINDS)
        applications(field.directives, location)
        if field.required? && field.deprecation
          report("TS-13", :deprecated_required_input, field.node, field.coordinate, coordinate: field.coordinate)
        end
        if field.default_value.present? && !valid_value?(field.node.default_value, field.type.named, field.type.wrappers)
          report("TS-15", :invalid_default, field.node, field.coordinate, coordinate: field.coordinate, type: field.type)
        end
      end

      def type_position(field, kinds)
        type = @index.types[field.type.named]
        if type.nil?
          report("TS-03", :unknown_type, field.node, field.coordinate, name: field.type.named)
        elsif !kinds.include?(type.kind)
          report("TS-06", :invalid_type_position, field.node, field.coordinate, name: field.type.named)
        end
      end

      def validate_interfaces(type)
        type.interfaces.each do |name|
          interface = @index.types[name]
          unless interface&.kind == :interface
            report(interface ? "TS-05" : "TS-03", :invalid_interface, type.node, type.coordinate, name: name)
            next
          end
          (interface.interfaces - type.interfaces).each do |ancestor|
            report("TS-05", :missing_ancestor, type.node, type.coordinate, name: type.name, ancestor: ancestor)
          end
          interface.fields.each_value do |expected|
            actual = type.fields[expected.name]
            unless actual && subtype?(actual.type.named, actual.type.wrappers, expected.type.named, expected.type.wrappers)
              report("TS-05", :invalid_implementation, actual&.node || type.node, type.coordinate, name: type.name, coordinate: expected.coordinate)
              next
            end
            expected.arguments.each_value do |arg|
              unless actual.arguments[arg.name]&.type&.to_s == arg.type.to_s
                report("TS-05", :missing_interface_argument, actual.node, actual.coordinate, coordinate: actual.coordinate, name: arg.name, type: arg.type)
              end
            end
            actual.arguments.each_value do |arg|
              if arg.required? && !expected.arguments.key?(arg.name)
                report("TS-05", :required_extra_argument, arg.node, arg.coordinate, coordinate: arg.coordinate)
              end
            end
          end
        end
      end

      def subtype?(actual, left, expected, right)
        if right.first == :non_null
          left.first == :non_null && subtype?(actual, left.drop(1), expected, right.drop(1))
        elsif left.first == :non_null
          subtype?(actual, left.drop(1), expected, right)
        elsif right.first == :list
          left.first == :list && subtype?(actual, left.drop(1), expected, right.drop(1))
        elsif left.empty?
          actual == expected || @index.implementations.fetch(expected, []).include?(actual) ||
            @index.types[expected]&.possible_types&.include?(actual)
        end
      end

      def applications(items, location)
        items.group_by(&:name).each do |name, group|
          definition = @index.directives[name]
          group.each_with_index do |application, index|
            node = application.node
            if !definition
              report("TS-09", :unknown_directive, node, name: name)
              next
            end
            unless definition.locations.include?(location)
              report("TS-09", :invalid_directive_position, node, name: name, location: location)
            end
            if index.positive? && !definition.repeatable?
              report("TS-09", :duplicate_application, node, name: name)
            end
            check_application_arguments(application, definition)
          end
        end
      end

      def check_application_arguments(application, definition)
        node = application.node
        duplicates(node.arguments, "TS-09")
        node.arguments.each do |arg|
          expected = definition.arguments[arg.name]
          unless expected && valid_value?(arg.value, expected.type.named, expected.type.wrappers)
            report("TS-09", :invalid_directive_argument, arg, name: arg.name, coordinate: definition.coordinate)
          end
        end
        definition.arguments.each_value do |arg|
          if arg.required? && !application.arguments.key?(arg.name)
            report("TS-09", :missing_directive_argument, node, coordinate: definition.coordinate, name: arg.name)
          end
        end
      end

      def valid_value?(value, name, wrappers)
        if wrappers.first == :non_null
          return !value.is_a?(Nodes::NullValue) && valid_value?(value, name, wrappers.drop(1))
        end
        return true if value.is_a?(Nodes::NullValue)
        if wrappers.first == :list
          return (value.is_a?(Array) ? value : [value]).all? { |item| valid_value?(item, name, wrappers.drop(1)) }
        end

        case name
        when "Int" then value.is_a?(Integer) && (-2**31...2**31).cover?(value)
        when "Float" then value.is_a?(Numeric) && value.finite?
        when "String" then value.is_a?(String)
        when "Boolean" then value == true || value == false
        when "ID" then value.is_a?(String) || value.is_a?(Integer)
        else
          type = @index.types[name]
          case type&.kind
          when :enum then value.is_a?(Nodes::Enum) && type.values.key?(value.name)
          when :input_object then valid_input_object?(value, type)
          else true
          end
        end
      end

      def valid_input_object?(value, type)
        return false unless value.is_a?(Nodes::InputObject)
        args = value.arguments.to_h { |arg| [arg.name, arg.value] }
        return false unless args.size == value.arguments.size && (args.keys - type.input_fields.keys).empty?
        if type.one_of?
          return false unless args.size == 1 && !args.values.first.is_a?(Nodes::NullValue)
        end
        type.input_fields.each_value.all? do |field|
          if args.key?(field.name)
            valid_value?(args[field.name], field.type.named, field.type.wrappers)
          else
            !field.required?
          end
        end
      end

      def cycles(kind, check)
        finished = {}
        @index.types.each_value do |root|
          next unless root.kind == kind
          active = {}
          stack = [[root, false]]
          until stack.empty?
            type, leaving = stack.pop
            if leaving
              active.delete(type.name)
              finished[type.name] = true
            elsif active[type.name]
              report(check, :cycle, type.node, type.coordinate, name: type.name)
            elsif !finished[type.name]
              active[type.name] = true
              stack << [type, true]
              yield(type).reverse_each do |name|
                target = @index.types[name]
                stack << [target, false] if target&.kind == kind
              end
            end
          end
        end
      end

      def nonempty(type, members)
        report("TS-11", :empty_type, type.node, type.coordinate, name: type.name) if members.empty?
      end

      def validate_name(member)
        if member.name.start_with?("__")
          report("TS-10", :reserved_name, member.node, member.coordinate, name: member.name)
        end
      end

      def duplicates(nodes, check = "TS-02")
        nodes.group_by(&:name).each do |name, group|
          group.drop(1).each { |node| report(check, :duplicate_definition, node, name: name) }
        end
      end

      def report(check, key, node, target = nil, **values)
        return if @skipped.include?(check)

        template = MESSAGES.fetch(@locale, MESSAGES.fetch("en")).fetch(key.to_s)
        message = values.empty? ? template : template % values
        @diagnostics << Diagnostic.new(rule_id: "core/invalid-schema", severity: :error, message: message,
          coordinate: target, location: @index.source(node)&.location(node), fatal: true,
          message_key: key, data: { check: check })
      end
    end
  end
end
