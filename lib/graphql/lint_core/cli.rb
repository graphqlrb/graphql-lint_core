# frozen_string_literal: true

require "optparse"

module GraphQL
  module LintCore
    class CLI
      COMMANDS = %w[check init rules explain baseline version].freeze

      def self.run(product, argv, name:, defaults:, presets:, options:, stdout: $stdout, stderr: $stderr)
        new(product, name, defaults, presets, options, stdout, stderr).run(argv)
      end

      def initialize(product, name, defaults, presets, options, stdout, stderr)
        @product, @name, @defaults, @presets = product, name, defaults, presets
        @options, @stdout, @stderr = options, stdout, stderr
      end

      def run(argv)
        arguments = argv.dup
        command = COMMANDS.include?(arguments.first) ? arguments.shift : "check"
        baseline_action = arguments.shift if command == "baseline" && %w[update prune].include?(arguments.first)
        cli = {}
        overrides = {}
        parser = option_parser(cli, overrides)
        positional = @options.call(parser, overrides, arguments)
        parser.parse!(arguments)
        return version if cli[:version] || command == "version"
        if cli[:help]
          @stdout.puts(parser)
          return 0
        end

        case command
        when "init"
          no_arguments(arguments)
          init(cli)
        when "rules", "explain"
          display_rules(command, arguments, cli, overrides)
        when "baseline", "check"
          positional.call(arguments) if positional.respond_to?(:call)
          no_arguments(arguments)
          begin
            settings = Config.load(cli[:config], defaults: @defaults, presets: @presets, overrides: overrides, filename: config_file)
          rescue InputError => error
            return configuration_failure(error, overrides)
          end
          return baseline(baseline_action, cli, settings, overrides) if command == "baseline"

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = @product.run(config: cli[:config], overrides: overrides)
          output(result, settings)
          if settings["debug"]
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            write_error(format("%s completed in %.3f seconds.", @name, elapsed))
          end
          result.exit_status
        end
      rescue OptionParser::ParseError, InputError, SystemCallError => error
        write_error(error.message, overrides)
        2
      rescue StandardError => error
        write_error("Internal error in #{@name}: #{error.message}. Please report this error.", overrides)
        write_error(error.full_message, overrides) if overrides&.fetch("debug", false)
        3
      end

      private

      def option_parser(cli, overrides)
        OptionParser.new do |parser|
          parser.banner = "Usage: #{@name} [check|init|rules|explain RULE|baseline update|baseline prune|version] [options]"
          parser.on("-c", "--config PATH", "Read a configuration file") { |path| cli[:config] = path }
          parser.on("-f", "--format NAME[:PATH]", "Add an output format") { |format| (overrides["format"] ||= []) << format }
          parser.on("--fail-level LEVEL", "Minimum failure severity") { |level| overrides["fail_level"] = level }
          parser.on("--max-warnings N", Integer, "Maximum warning count") { |count| overrides["max_warnings"] = count }
          parser.on("-r", "--require PATH", "Load a Ruby extension") { |path| (overrides["require"] ||= []) << path }
          parser.on("--baseline PATH", "Read a baseline file") { |path| overrides["baseline"] = path }
          parser.on("--no-baseline", "Ignore the baseline") { overrides["baseline"] = nil }
          parser.on("--only RULES", Array, "Run only these comma-separated rules") { |rules| overrides["only"] = rules }
          parser.on("--except RULES", Array, "Skip these comma-separated rules") { |rules| overrides["except"] = rules }
          parser.on("--no-color", "Disable color") { overrides["no_color"] = true }
          parser.on("-q", "--quiet", "Display errors only") { overrides["quiet"] = true }
          parser.on("--debug", "Print debugging information") { overrides["debug"] = true }
          parser.on("--preset PRESET", "Add an init preset") { |preset| (cli[:presets] ||= []) << preset }
          parser.on("--force", "Overwrite configuration with init") { cli[:force] = true }
          parser.on("-h", "--help", "Show help") { cli[:help] = true }
          parser.on("--version", "Show versions") { cli[:version] = true }
        end
      end

      def no_arguments(arguments)
        raise InputError, "Unexpected arguments: #{arguments.join(" ")}." unless arguments.empty?
      end

      def config_file = ".#{@name}.yml"

      def version
        @stdout.puts("#{@name} #{@product::VERSION}, graphql-lint_core #{VERSION}, graphql #{GraphQL::VERSION}, Ruby #{RUBY_VERSION}")
        0
      end

      def init(cli)
        file = cli[:config] || config_file
        presets = cli.fetch(:presets, ["recommended"])
        unknown = presets - @presets.keys
        raise InputError, "Unknown preset #{unknown.first.inspect}." if !@presets.empty? && unknown.any?
        example = { "version" => 1 }
        example["extends"] = presets unless @presets.empty?
        example["schema"] = @defaults["schema"] if @defaults["schema"]
        example["documents"] = @defaults["documents"] if @defaults["documents"]
        flags = File::WRONLY | File::CREAT | (cli[:force] ? File::TRUNC : File::EXCL)
        File.open(file, flags) { |stream| stream.write(Psych.dump(example)) }
        @stdout.puts("Created #{file}.")
        0
      end

      def display_rules(command, arguments, cli, overrides)
        settings = Config.load(cli[:config], defaults: @defaults, presets: @presets, overrides: overrides, filename: config_file)
        Config.require_extensions(settings)
        rules = @product.rules
        if command == "rules"
          no_arguments(arguments)
          preset_settings = @presets.keys.to_h do |name|
            [name, Config.apply_extends({ "extends" => [name] }, [], @presets, [], []).fetch("rules", {})]
          end
          rules.sort.each do |id, rule|
            presets = preset_settings.keys.select do |name|
              value = preset_settings.fetch(name)[id]
              value && value != "off"
            end
            @stdout.puts([id, rule.category, rule.default_severity, presets.join(", ")].compact.join("\t").rstrip)
          end
        else
          raise InputError, "Usage: #{@name} explain RULE" unless arguments.length == 1
          id = arguments.fetch(0)
          rule = rules[id]
          raise InputError, "Unknown rule #{id.inspect}." unless rule

          @stdout.puts("#{id} (#{rule.default_severity})", rule.description)
          rule.options.each do |name, definition|
            @stdout.puts("  #{name}: #{definition[:type]} (default: #{definition[:default].inspect})")
          end
          if @product.respond_to?(:examples)
            @product.examples(id)&.each { |label, example| @stdout.puts("", "#{label.capitalize}:", example) }
          end
        end
        0
      end

      def baseline(action, cli, settings, overrides)
        unless %w[update prune].include?(action)
          raise InputError, "Usage: #{@name} baseline update|prune."
        end

        file = cli[:config] || Config.find(config_file)
        path = settings["baseline"] || File.expand_path(".#{@name}-baseline.json", file ? File.dirname(file) : Dir.pwd)
        result = @product.run(config: cli[:config], overrides: overrides.merge("baseline" => nil))
        if result.exit_status >= 2
          output(result, settings)
          return result.exit_status
        end
        Baseline.write(path, result, prune: action == "prune")
        @stdout.puts("Updated #{path}.")
        0
      end

      def configuration_failure(error, overrides)
        entry = Diagnostic.new(rule_id: "core/config-error", severity: :error, fatal: true, message: error.message)
        result = Result.new(diagnostics: [entry], tool: @name.sub(/-(?=[^-]+\z)/, "_"), version: @product::VERSION)
        formats = Array(overrides["format"]).select do |format|
          Config::FORMATS.include?(format.split(":", 2).first)
        end
        if formats.empty?
          write_error(error.message, overrides)
        else
          output(result, overrides.merge("format" => formats))
        end
        result.exit_status
      end

      def output(result, settings)
        tty = @stdout.respond_to?(:tty?) && @stdout.tty?
        formats = Array(settings["format"] || (tty ? "text" : "compact"))
        formats.each do |entry|
          format, path = entry.split(":", 2)
          text = Formatter.render(format, result, quiet: settings["quiet"],
            color: tty && !path && !settings["no_color"] && !ENV.key?("NO_COLOR"), docs: @product.rules)
          path ? File.binwrite(path, text) : @stdout.write(text)
          if format == "github" && ENV["GITHUB_STEP_SUMMARY"]
            File.open(ENV["GITHUB_STEP_SUMMARY"], "a") { |file| file.puts(Formatter.render("markdown", result)) }
          end
        end
        result.reportable.each do |diagnostic|
          if diagnostic.fatal? || diagnostic.rule_id == "core/skipped-schema-check" || result.exit_status == 3
            write_error(diagnostic.message, settings)
          end
        end
      end

      def write_error(message, settings = nil)
        github = ENV["GITHUB_ACTIONS"] == "true" || Array(settings&.fetch("format", nil)).any? do |entry|
          entry.is_a?(String) && entry.split(":", 2).first == "github"
        end
        @stderr.puts(Formatter.log_message(message, github: github))
      end
    end
  end
end
