# frozen_string_literal: true

require "uri"

module GraphQL
  module LintCore
    module Formatter
      LEVELS = { error: "error", warning: "warning", info: "note" }.freeze
      COLORS = { error: 31, warning: 33, info: 36 }.freeze
      MAX_MARKDOWN = 65_536
      module_function

      def render(format, result, quiet: false, color: false, docs: {})
        diagnostics = result.reportable
        diagnostics = diagnostics.select { |record| record.severity == :error } if quiet
        case format.to_s
        when "text" then text(diagnostics, result, color)
        when "compact" then join_lines(diagnostics.map { |record| compact(record) })
        when "json" then JSON.pretty_generate(result.to_h) + "\n"
        when "github" then join_lines(diagnostics.map { |record| github(record) })
        when "sarif" then JSON.pretty_generate(sarif(diagnostics, result, docs)) + "\n"
        when "markdown" then markdown(diagnostics, result)
        else raise InputError, "Unknown format #{format.inspect}."
        end
      end

      def text(diagnostics, result, color)
        lines = diagnostics.group_by { |record| record.location&.path }.flat_map do |path, records|
          rows = records.flat_map do |record|
            level = record.severity.to_s
            level = "\e[#{COLORS.fetch(record.severity)}m#{level}\e[0m" if color
            position = [record.location&.line, record.location&.column].compact.join(":")
            row = ["  #{position}", level, "[#{record.rule_id}]", record.message, coordinate(record)].join(" ").rstrip
            record.suggestion ? [row, "    #{record.suggestion}"] : [row]
          end
          path ? [path, *rows] : rows
        end
        join_lines(lines + [summary(result)])
      end

      def compact(record)
        position = record.location
        prefix = position&.path ? [position.path, position.line, position.column].compact.join(":") + ": " : ""
        message = record.message.gsub(/[\r\n]+/, " ")
        "#{prefix}#{record.severity} [#{record.rule_id}] #{message}#{coordinate(record)}"
      end

      def coordinate(record)
        record.coordinate ? " (#{record.coordinate})" : ""
      end

      def github(record)
        command = record.severity == :info ? "notice" : record.severity.to_s
        position = record.location
        attributes = { file: position&.path, line: position&.line, col: position&.column, title: record.rule_id }
        properties = attributes.compact.map { |key, value| "#{key}=#{github_escape(value, property: true)}" }
        "::#{command} #{properties.join(",")}::#{github_escape(record.message)}"
      end

      def github_escape(value, property: false)
        escaped = value.to_s.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
        property ? escaped.gsub(":", "%3A").gsub(",", "%2C") : escaped
      end

      def log_message(value, github: ENV["GITHUB_ACTIONS"] == "true")
        return value unless github

        "GraphQL lint: #{github_escape(value).gsub("##[", "##%5B").gsub("::", "%3A%3A")}"
      end

      def sarif(diagnostics, result, docs)
        rules = diagnostics.map(&:rule_id).uniq.sort.map do |id|
          description = docs[id]
          definition = { id: id, shortDescription: { text: id } }
          if description.respond_to?(:description) && description.description
            definition[:shortDescription][:text] = description.description
            definition[:helpUri] = description.docs_url if description.respond_to?(:docs_url) && description.docs_url
          end
          definition
        end
        {
          "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
          version: "2.1.0",
          runs: [{
            tool: { driver: { name: result.tool, version: result.version, rules: rules } },
            columnKind: "unicodeCodePoints",
            results: diagnostics.map { |record| sarif_result(record) }
          }]
        }
      end

      def sarif_result(record)
        item = {
          ruleId: record.rule_id, level: LEVELS.fetch(record.severity), message: { text: record.message },
          partialFingerprints: { primaryLocationLineHash: record.fingerprint }
        }
        location = {}
        if record.location&.path
          position = record.location
          uri = URI::DEFAULT_PARSER.escape(position.path.tr("\\", "/"), /[^A-Za-z0-9._~\/-]/)
          physical = { artifactLocation: { uri: uri } }
          if position.line
            physical[:region] = { startLine: position.line, startColumn: position.column,
              endLine: position.end_line, endColumn: position.end_column }.compact
          end
          location[:physicalLocation] = physical
        end
        location[:logicalLocations] = [{ fullyQualifiedName: record.coordinate }] if record.coordinate
        item[:locations] = [location] unless location.empty?
        item
      end

      def markdown(diagnostics, result)
        lines = [summary(result), "", "| Severity | Rule | Location | Message |", "| --- | --- | --- | --- |"]
        length = lines.sum { |line| line.length + 1 }
        diagnostics.each_with_index do |record, index|
          position = record.location
          target = [position&.path, position&.line, position&.column].compact.join(":")
          target = record.coordinate if target.empty?
          cells = [record.severity, record.rule_id, target, record.message].map { |cell| markdown_escape(cell) }
          row = "| #{cells.join(" | ")} |"
          if length + row.length + 1 > MAX_MARKDOWN - 100
            lines << "" << "#{diagnostics.length - index} additional diagnostics were omitted."
            break
          end
          lines << row
          length += row.length + 1
        end
        join_lines(lines)
      end

      def markdown_escape(cell)
        cell.to_s.gsub(/[\r\n]+/, " ").gsub(/[&<>]/, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
          .gsub(/[\\|`*_\[\]~]/) { |character| "\\#{character}" }
      end

      def summary(result)
        counts = result.summary
        "#{counts[:errors]} errors, #{counts[:warnings]} warnings, #{counts[:infos]} infos, " \
          "#{counts[:suppressed].values.sum} suppressed, #{counts[:baseline_resolved]} baseline entries resolved"
      end

      def join_lines(lines)
        lines.empty? ? "" : lines.join("\n") + "\n"
      end
    end
  end
end
