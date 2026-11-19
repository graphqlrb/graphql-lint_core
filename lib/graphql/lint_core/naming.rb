# frozen_string_literal: true

module GraphQL
  module LintCore
    module Naming
      STYLES = {
        "PascalCase" => /\A[A-Z][A-Za-z0-9]*\z/,
        "camelCase" => /\A[a-z][A-Za-z0-9]*\z/,
        "UPPER_CASE" => /\A[A-Z][A-Z0-9_]*\z/,
        "snake_case" => /\A[a-z][a-z0-9_]*\z/,
        "any" => /\A.*\z/
      }.freeze
      RULE_OPTIONS = {
        style: { type: :enum, values: STYLES.keys },
        prefix: { type: :string },
        suffix: { type: :string },
        forbidden_prefixes: { type: :string_list },
        forbidden_suffixes: { type: :string_list },
        pattern: { type: :regexp },
        forbidden_names: { type: :string_list },
        allow_leading_underscore: { type: :boolean }
      }.freeze

      module_function

      def validate(rules)
        raise ConfigError, "A naming rule must be a mapping." unless rules.is_a?(Hash)

        rules.each_with_object({}) do |(name, value), normalized|
          key = name.to_s.to_sym
          option = RULE_OPTIONS[key]
          raise ConfigError, "Unknown naming option `#{name}`." unless option

          valid = case option.fetch(:type)
          when :enum then option.fetch(:values).include?(value)
          when :string then value.is_a?(String)
          when :string_list then value.is_a?(Array) && value.all?(String)
          when :boolean then value == true || value == false
          when :regexp then value.is_a?(String) || value.is_a?(Regexp)
          end
          raise ConfigError, "Invalid naming option `#{name}`." unless valid

          normalized[key] = if key == :pattern
            pattern = value.is_a?(Regexp) ? value : Regexp.new(value, timeout: 1.0)
            Regexp.new("\\A(?:#{pattern.source})\\z", pattern.options, timeout: 1.0)
          else
            value
          end
        end
      rescue RegexpError => error
        raise ConfigError, "Invalid naming pattern: #{error.message}"
      end

      def valid?(name, rules)
        rule = rules.transform_keys(&:to_sym)
        checked_name = rule[:allow_leading_underscore] ? name.sub(/\A_+/, "") : name
        pattern = rule[:pattern]
        pattern = validate(pattern: pattern).fetch(:pattern) if pattern.is_a?(String)
        STYLES.fetch(rule[:style] || "any").match?(checked_name) &&
          (rule[:allow_leading_underscore] || !name.start_with?("_")) &&
          (!rule[:prefix] || name.start_with?(rule[:prefix])) &&
          (!rule[:suffix] || name.end_with?(rule[:suffix])) &&
          !Array(rule[:forbidden_prefixes]).any? { |prefix| name.start_with?(prefix) } &&
          !Array(rule[:forbidden_suffixes]).any? { |suffix| name.end_with?(suffix) } &&
          !Array(rule[:forbidden_names]).include?(name) &&
          (!pattern || pattern.match?(name))
      end

      def replacement(name, rules)
        rule = rules.transform_keys(&:to_sym)
        result = convert(name, rule[:style] || "any")
        result = rule[:prefix] + result if rule[:prefix] && !result.start_with?(rule[:prefix])
        result = result + rule[:suffix] if rule[:suffix] && !result.end_with?(rule[:suffix])
        result
      end

      def convert(name, style)
        case style
        when "PascalCase", "camelCase"
          words = split_words(name)
          result = words.map(&:capitalize).join
          style == "camelCase" ? result.sub(/\A[A-Z]/, &:downcase) : result
        when "UPPER_CASE" then split_words(name).join("_").upcase
        when "snake_case" then split_words(name).join("_").downcase
        when "kebab-case" then split_words(name).join("-").downcase
        else name
        end
      end

      def split_words(name)
        name.gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2').gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').split(/[_-]+/).reject(&:empty?)
      end
      private_class_method :split_words
    end
  end
end
