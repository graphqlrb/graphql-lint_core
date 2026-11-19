# frozen_string_literal: true

module GraphQL
  module LintCore
    # @api public
    class Result
      attr_reader :tool, :version, :diagnostics, :exit_status, :stats, :baseline_resolved

      def initialize(diagnostics:, tool:, version:, config: {}, sources: [], stats: {}, exit_status: nil)
        @tool, @version = tool, version
        @baseline_resolved = 0
        @diagnostics = diagnostics.map(&:dup).sort_by(&:sort_key)
        suppress(sources, config)
        @diagnostics.sort_by!(&:sort_key)
        @exit_status = exit_status || calculate_status(config)
        @stats = stats.merge(summary).freeze
      end

      def reportable
        diagnostics.reject(&:suppressed_by)
      end

      def fatal? = exit_status == 2

      def summary
        counts = reportable.map(&:severity).tally
        {
          errors: counts.fetch(:error, 0), warnings: counts.fetch(:warning, 0), infos: counts.fetch(:info, 0),
          suppressed: %i[comment config baseline].to_h { |kind| [kind, diagnostics.count { |d| d.suppressed_by == kind }] },
          baseline_resolved: baseline_resolved, exit_status: exit_status
        }
      end

      def to_h
        { format_version: 1, tool: { name: tool, version: version }, summary: summary, diagnostics: diagnostics.map(&:to_h) }
      end

      def to_json(*args) = JSON.generate(to_h, *args)

      private

      def calculate_status(config)
        return 2 if reportable.any?(&:fatal?)

        levels = %i[info warning error]
        minimum = levels.index(config.fetch("fail_level", "error").to_sym)
        return 1 if reportable.any? { |record| levels.index(record.severity) >= minimum }

        limit = config["max_warnings"]
        limit && reportable.count { |record| record.severity == :warning } > limit ? 1 : 0
      end

      def suppress(sources, config)
        options = config.fetch("suppression", {})
        by_path = @diagnostics.group_by { |diagnostic| diagnostic.location&.path }
        sources.compact.each do |source|
          @diagnostics.concat(Suppression.new(source, options).apply(by_path.fetch(source.path, [])))
        end
        Array(config["ignore"]).each { |entry| apply_ignore(entry) }
        path = config["baseline"]
        return unless path && File.file?(path)

        counts = Baseline.read(path, tool).to_h { |entry| [entry.fetch("fingerprint"), entry.fetch("count")] }
        @diagnostics.each do |record|
          next if record.suppressed_by || record.fatal? || counts.fetch(record.fingerprint, 0).zero?

          record.suppressed_by = :baseline
          counts[record.fingerprint] -= 1
        end
        @baseline_resolved = counts.values.sum
      end

      def apply_ignore(entry)
        coordinate = CoordinatePattern.new(entry["coordinate"]) if entry["coordinate"]
        @diagnostics.each do |record|
          next if record.fatal? || record.suppressed_by
          next unless File.fnmatch?(entry.fetch("rule"), record.rule_id)
          next if coordinate && !coordinate.match?(record.coordinate)
          next if entry["path"] && !match_path?(entry["path"], record.location&.path)
          next if entry["operation"] && !record.operation_names.any? { |name| name && File.fnmatch?(entry["operation"], name) }

          record.suppressed_by = :config
        end
      end

      def match_path?(pattern, path)
        return false unless path
        path = File.expand_path(path) if pattern.start_with?("/")

        File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end
    end

    module Baseline
      module_function

      def read(path, tool)
        baseline = JSON.parse(File.binread(path))
        unless baseline.is_a?(Hash) && baseline["format_version"] == 1 && baseline["tool"] == tool && baseline["entries"].is_a?(Array)
          raise InputError, "Invalid baseline for #{tool}: #{path}."
        end
        entries = baseline["entries"]
        unless entries.all? { |entry| valid_entry?(entry) } && entries.map { |entry| entry["fingerprint"] }.uniq.size == entries.size
          raise InputError, "Invalid or duplicate baseline entries in #{path}."
        end

        entries
      rescue JSON::ParserError, SystemCallError => error
        raise InputError, "Cannot read baseline #{path}: #{error.message}"
      end

      def valid_entry?(entry)
        entry.is_a?(Hash) && entry["fingerprint"].is_a?(String) &&
          entry["count"].is_a?(Integer) && entry["count"].positive?
      end

      def write(path, result, prune: false)
        current = result.reportable.reject(&:fatal?).group_by(&:fingerprint)
        entries = if prune
          read(path, result.tool).filter_map do |entry|
            matches = current[entry.fetch("fingerprint")]
            entry.merge("count" => [entry.fetch("count"), matches.size].min) if matches
          end
        else
          current.map do |fingerprint, group|
            diagnostic = group.first
            { "fingerprint" => fingerprint, "rule" => diagnostic.rule_id, "coordinate" => diagnostic.coordinate, "count" => group.size }
          end
        end
        contents = { format_version: 1, tool: result.tool, entries: entries.sort_by { |entry| entry["fingerprint"] } }
        require "tempfile"
        Tempfile.create(".graphql-lint-baseline", File.dirname(File.expand_path(path))) do |file|
          file.write(JSON.pretty_generate(contents) + "\n")
          file.close
          File.rename(file.path, path)
        end
      end
    end

    class Suppression
      COMMAND = /\Agraphql-lint-(disable-next-line|disable-file|disable|enable)(?:\s+(.*))?\z/
      Entry = Struct.new(:comment, :rules, :except, :first, :last, :used, keyword_init: true) do
        def covers?(record, line)
          first <= line && line <= last && (rules.empty? || rules.include?(record.rule_id)) && !except.include?(record.rule_id)
        end
      end

      def initialize(source, options)
        @source, @options = source, options
      end

      def apply(diagnostics)
        notices = []
        entries = commands(notices)
        diagnostics.each do |record|
          location = record.location
          next if !location || location.path != @source.path || !location.line || record.fatal?

          entries.each do |entry|
            next unless entry.covers?(record, location.line)

            entry.used = true
            record.suppressed_by ||= :comment
          end
        end
        if %w[warning info].include?(@options["report_unused"])
          entries.group_by(&:comment).each do |comment, slices|
            next if slices.any?(&:used)

            notices << notice("unused-suppression", "This suppression did not match any diagnostics.", comment, @options["report_unused"])
          end
        end
        notices
      end

      private

      def commands(notices)
        entries = []
        @source.comments.each do |comment|
          command = COMMAND.match(comment.text)
          next unless command

          rules, reason = command[2].to_s.split(/(?:\A|\s)--(?:\s|\z)/, 2)
          names = rules.to_s.split(/[\s,]+/).reject(&:empty?)
          case command[1]
          when "enable"
            entries = enable(entries, names, comment.line)
          else
            if @options["require_reason"] && reason.to_s.strip.empty?
              notices << notice("suppression-without-reason", "A suppression needs a reason.", comment, :warning)
            end
            range = case command[1]
            when "disable-file" then [1, @source.lines.length]
            when "disable-next-line"
              next_line = @source.lines.each_index.drop(comment.line).find { |i| !@source.lines[i].match?(/\A\s*(?:#|\z)/) }
              line = next_line ? next_line + 1 : @source.lines.size + 1
              [line, line]
            else [comment.line + 1, Float::INFINITY]
            end
            entries << Entry.new(comment: comment, rules: names, except: [], first: range.first, last: range.last, used: false)
          end
        end
        entries
      end

      def enable(entries, names, line)
        new_entries = []
        entries.each do |entry|
          next unless entry.last.infinite? && (names.empty? || entry.rules.empty? || entry.rules.intersect?(names))

          if names.any?
            remaining = entry.rules - names
            if entry.rules.empty? || remaining.any?
              excluded = entry.rules.empty? ? entry.except | names : []
              new_entries << Entry.new(comment: entry.comment, rules: remaining, except: excluded,
                first: line + 1, last: Float::INFINITY, used: false)
            end
          end
          entry.last = line - 1
        end
        entries + new_entries
      end

      def notice(id, message, comment, severity)
        Diagnostic.new(rule_id: "core/#{id}", severity: severity, message: message,
          location: Location.new(path: @source.path, line: comment.line, column: comment.column))
      end
    end
  end
end
