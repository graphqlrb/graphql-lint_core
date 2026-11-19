# frozen_string_literal: true

require "digest"
require "json"

module GraphQL
  module LintCore
    # @api public
    Location = Struct.new(:path, :line, :column, :end_line, :end_column, keyword_init: true)

    # @api public
    class Diagnostic
      attr_reader :rule_id, :severity, :message, :suggestion, :coordinate, :subject,
        :location, :related, :data, :message_key, :fingerprint, :fatal
      attr_accessor :operations, :suppressed_by

      def initialize(rule_id:, severity:, message:, suggestion: nil, coordinate: nil, subject: nil,
        location: nil, related: [], operations: [], data: {}, message_key: nil, fingerprint: nil,
        fatal: false, suppressed_by: nil, fingerprint_keys: [], path: nil)
        @rule_id, @severity, @message = rule_id.to_s, severity.to_sym, message
        @suggestion, @coordinate, @subject, @location = suggestion, coordinate, subject, location
        @related, @operations, @data = related, operations, data
        @message_key, @fatal, @suppressed_by = (message_key || rule_id).to_s, fatal, suppressed_by
        target = coordinate || [location&.path, operations.map { |op| operation_name(op) }, path || data[:path] || data["path"]]
        selected = fingerprint_keys.map { |key| data.fetch(key) { data[key.to_s] } }
        @fingerprint = fingerprint || "sha256:#{Digest::SHA256.hexdigest(JSON.generate([@rule_id, @message_key, target, subject, selected]))}"
      end

      alias fatal? fatal

      def sort_key
        [location&.path.to_s, location&.line.to_i, location&.column.to_i, rule_id, coordinate.to_s, message]
      end

      def operation_names
        operations.map { |op| operation_name(op) }
      end

      def to_h
        {
          rule: rule_id, severity: severity, message: message, suggestion: suggestion, coordinate: coordinate,
          subject: subject, location: location&.to_h, related: serialize(related), operations: serialize(operations),
          data: data, fingerprint: fingerprint, fatal: fatal, suppressed_by: suppressed_by
        }
      end

      private

      def operation_name(operation)
        if operation.is_a?(Hash)
          operation[:name] || operation["name"] || operation[:id] || operation["id"]
        elsif operation.respond_to?(:name)
          operation.name
        else
          operation.to_s
        end
      end

      def serialize(value)
        case value
        when nil then nil
        when Array then value.map { |item| serialize(item) }
        when Hash then value.transform_values { |item| serialize(item) }
        when Location then value.to_h
        else value.respond_to?(:to_h) ? serialize(value.to_h) : value
        end
      end
    end
  end
end
