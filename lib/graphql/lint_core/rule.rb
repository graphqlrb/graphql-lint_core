# frozen_string_literal: true

module GraphQL
  module LintCore
    class CoordinatePatterns < Array
      def match?(coordinate)
        any? { |pattern| pattern.match?(coordinate) }
      end
    end

    # @api public
    class Rule
      class << self
        %i[id category description default_severity docs_url].each do |attribute|
          define_method(attribute) do |*values|
            variable = :"@#{attribute}"
            if values.empty?
              instance_variable_get(variable) || (superclass.public_send(attribute) if superclass.respond_to?(attribute))
            else
              instance_variable_set(variable, values.fetch(0))
            end
          end
        end

        def requires_schema(required = true)
          @requires_schema = required
        end

        def requires_schema?
          return @requires_schema if instance_variable_defined?(:@requires_schema)

          superclass.respond_to?(:requires_schema?) && superclass.requires_schema?
        end

        def fingerprint_keys(*keys)
          return @fingerprint_keys || [] if keys.empty?

          @fingerprint_keys = keys.flatten
        end

        def options
          inherited = superclass.respond_to?(:options) ? superclass.options : {}
          inherited.merge(@options || {})
        end

        def option(name, type:, default: nil, values: nil, description: nil, **metadata)
          (@options ||= {})[name.to_sym] = { type: type, default: default, values: values, description: description, **metadata }
        end

        def message(key, text)
          (@messages ||= {})[key.to_s] = text
        end

        def suggestion(key, text)
          (@suggestions ||= {})[key.to_s] = text
        end

        def messages
          inherited = superclass.respond_to?(:messages) ? superclass.messages : {}
          inherited.merge(@messages || {})
        end

        def suggestions
          inherited = superclass.respond_to?(:suggestions) ? superclass.suggestions : {}
          inherited.merge(@suggestions || {})
        end

        def resolve_options(input)
          path = "rules.#{id}.options"
          declared = options
          values = Config.stringify(input)
          Config.unknown_keys(values, declared.keys.map(&:to_s), path)
          declared.to_h do |name, metadata|
            value = values.fetch(name.to_s) { metadata[:default] }
            if value.is_a?(Hash) && metadata[:default].is_a?(Hash)
              value = Config.merge(Config.stringify(metadata[:default]), value)
            end
            resolved = resolve(value, metadata, "#{path}.#{name}") unless value.nil? && !values.key?(name.to_s)
            [name, resolved]
          end
        end

        private

        def resolve(value, definition, path)
          return nil if value.nil? && definition[:nullable]

          type = definition.fetch(:type)
          valid = case type
          when :any then true
          when :string, :regexp then value.is_a?(String)
          when :integer then value.is_a?(Integer)
          when :boolean then [true, false].include?(value)
          when :enum then Array(definition[:values]).map(&:to_s).include?(value)
          when :string_list, :glob_list, :coordinate_patterns then value.is_a?(Array) && value.all?(String)
          when :array then value.is_a?(Array)
          when :hash then value.is_a?(Hash)
          end
          raise InputError, "#{path} must be #{type}." unless valid

          case type
          when :regexp
            Regexp.new(value, timeout: 1.0)
          when :coordinate_patterns
            CoordinatePatterns.new(value.map { |pattern| CoordinatePattern.new(pattern) })
          when :hash
            schema = definition[:schema]
            return value unless schema

            Config.unknown_keys(value, schema.keys.map(&:to_s), path)
            value.to_h do |key, nested_value|
              nested = schema[key] || schema.fetch(key.to_sym)
              [key, resolve(nested_value, nested.is_a?(Hash) ? nested : { type: nested }, "#{path}.#{key}")]
            end
          else value
          end
        rescue RegexpError => error
          raise InputError, "#{path}: #{error.message}"
        end
      end

      attr_reader :options, :context

      def initialize(options: {}, severity: nil, diagnostics: [])
        @options, @diagnostics = options, diagnostics
        @severity = severity || self.class.default_severity || :warning
      end

      def setup(context)
        @context = context
      end

      def finish; end

      # @api public
      def report(member, key, location: :start, data: {}, related: [], coordinate: nil, subject: nil,
        severity: nil, operations: nil, suggestion: nil, **values)
        label = key.to_s
        coordinate ||= member.coordinate if member.respond_to?(:coordinate)
        position = member_location(member, location)
        operations ||= member.respond_to?(:operations) ? member.operations : []
        values = { coordinate: coordinate }.merge(values)
        path = member.path if member.respond_to?(:path) && !member.is_a?(Location)
        @diagnostics << Diagnostic.new(
          rule_id: self.class.id, severity: severity || @severity, message_key: label,
          message: interpolate(self.class.messages[label] || label, values),
          suggestion: interpolate(suggestion || self.class.suggestions[label], values),
          coordinate: coordinate, subject: subject, location: position, related: related,
          operations: operations, data: data, fingerprint_keys: self.class.fingerprint_keys, path: path
        )
      end

      private

      def member_location(member, location)
        case location
        when :start, :description
          member.is_a?(Location) ? member : (member.location if member.respond_to?(:location))
        when :name
          member.respond_to?(:name_location) ? member.name_location : member_location(member, :start)
        when :deprecation
          member.deprecation&.location if member.respond_to?(:deprecation)
        else location
        end
      end

      def interpolate(text, values)
        text&.gsub(/%\{([a-zA-Z0-9_]+)\}/) do |placeholder|
          values.fetch(Regexp.last_match(1).to_sym, placeholder).to_s
        end
      end
    end
  end
end
