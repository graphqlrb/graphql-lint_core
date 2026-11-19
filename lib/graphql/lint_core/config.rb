# frozen_string_literal: true

require "date"
require "psych"
require "did_you_mean"
require "pathname"

module GraphQL
  module LintCore
    module Config
      SEVERITIES = %w[error warning info].freeze
      FORMATS = %w[text compact json github sarif markdown].freeze
      COMMON = {
        "version" => 1, "require" => [], "fail_level" => "error", "rules" => {}, "ignore" => [],
        "suppression" => { "require_reason" => false, "report_unused" => "off" }
      }.freeze
      OPTIONAL = %w[extends format max_warnings baseline only except quiet debug no_color git]
      SCHEMA_KEYS = %w[sources prelude skip_checks emit_generated_sdl]
      module_function

      def load(input, defaults:, presets: {}, overrides: {}, filename: nil, disallow: [])
        original = input
        input ||= find(filename) if filename
        defaults = stringify(defaults)
        keys = (COMMON.keys + OPTIONAL + defaults.keys) - disallow
        initial = merge(COMMON, defaults)
        config = case input
        when nil then {}
        when Hash then stringify(input)
        else read(input.to_s, keys: keys)
        end
        unknown_keys(config, keys, "")
        if input && !input.is_a?(Hash) && !config.key?("version")
          raise InputError, "version is required."
        end
        fallback = defaults.fetch("extends", presets.key?("recommended") ? ["recommended"] : [])
        config = apply_extends(config, fallback, presets, keys, [], file: (input unless input.is_a?(Hash)))
        settings = merge(merge(initial, config), stringify(overrides))
        if filename && keys.include?("baseline") && !settings.key?("baseline")
          directory = input && !input.is_a?(Hash) ? File.dirname(File.expand_path(input)) : Dir.pwd
          default_path = File.join(directory, filename.delete_suffix(".yml") + "-baseline.json")
          settings["baseline"] = default_path if File.file?(default_path)
        end
        unknown_keys(stringify(overrides), keys, "")
        validate(settings, keys + COMMON.keys)
        settings
      rescue InputError => error
        prefix = original.is_a?(Hash) ? "Configuration" : (input || "Configuration")
        raise InputError, "#{prefix}: #{error.message}"
      end

      def find(filename)
        Pathname(Dir.pwd).ascend do |dir|
          file = dir.join(filename)
          return file.to_s if file.file?
          break if dir.join(".git").exist?
        end
        nil
      end

      def read(path, keys:)
        data = Psych.safe_load(File.binread(path), permitted_classes: [Date], aliases: false, filename: path)
        raise InputError, "Expected a YAML mapping." unless data.is_a?(Hash)

        data = stringify(data)
        unknown_keys(data, keys, "")
        rebase(data, File.dirname(File.expand_path(path)))
      rescue Psych::Exception, SystemCallError => error
        raise InputError, error.message
      end

      def apply_extends(config, fallback, presets, keys, stack, file: nil)
        extends = config.fetch("extends", fallback)
        unless extends.is_a?(String) || extends.is_a?(Array)
          raise InputError, "extends must be a preset name, path, or list."
        end
        check_strings(Array(extends), "extends")
        accumulated = {}
        Array(extends).each do |entry|
          if presets.key?(entry)
            raise InputError, "Circular preset extends at #{entry.inspect}." if stack.include?(entry)

            inherited = apply_extends(stringify(presets.fetch(entry)), [], presets, keys, [*stack, entry])
            accumulated = merge(accumulated, inherited)
            next
          end
          path = File.expand_path(entry, file ? File.dirname(File.expand_path(file)) : Dir.pwd)
          raise InputError, "Circular extends at #{path}." if stack.include?(path) || file && path == File.expand_path(file)

          inherited = apply_extends(read(path, keys: keys), [], presets, keys, [*stack, path], file: path)
          accumulated = merge(accumulated, inherited)
        end
        merge(accumulated, config)
      end

      def rebase(data, dir)
        return data if dir == Dir.pwd

        %w[schema old new].each do |key|
          data[key] = rebase_schema(data[key], dir) if data.key?(key)
        end
        if data["documents"].is_a?(Hash)
          docs = data["documents"]
          %w[include exclude].each { |key| docs[key] = map_paths(docs[key], dir) if docs.key?(key) }
        elsif data["documents"].is_a?(Array)
          data["documents"] = map_paths(data["documents"], dir)
        end
        Array(data["ignore"]).each do |entry|
          entry["path"] = path_from(entry["path"], dir) if entry.is_a?(Hash) && entry["path"].is_a?(String)
        end
        data["require"] = Array(data["require"]).map { |name| extension_path(name, dir) } if data["require"].is_a?(Array)
        data["baseline"] = path_from(data["baseline"], dir) if data["baseline"].is_a?(String)
        if data["format"]
          data["format"] = Array(data["format"]).map do |value|
            next value unless value.is_a?(String)
            name, file = value.split(":", 2)
            file ? "#{name}:#{path_from(file, dir)}" : value
          end
        end
        if data["git"].is_a?(Hash) && data["git"]["repository"].is_a?(String)
          data["git"]["repository"] = path_from(data["git"]["repository"], dir)
        elsif %w[schema old new].any? { |key| data[key].to_s.include?("git") }
          data["git"] = { "repository" => dir } unless data.key?("git")
        end
        data
      end

      def rebase_schema(value, dir)
        return value if value.nil?
        if value.is_a?(Hash) && !(value.keys & SCHEMA_KEYS).empty?
          value["sources"] = Array(value["sources"]).map { |entry| rebase_schema(entry, dir) } if value.key?("sources")
          value["prelude"] = map_paths(value["prelude"], dir) if value.key?("prelude")
          return value
        end
        if value.is_a?(Hash)
          return value if value.key?("git")
          return { "ruby" => rebase_ruby(value["ruby"], dir) } if value.key?("ruby")
          return value.transform_values { |item| path_from(item, dir) }
        end
        return value.map { |entry| rebase_schema(entry, dir) } if value.is_a?(Array)
        return value unless value.is_a?(String) && value != "-"

        kind, input = value.split(":", 2)
        return value if %w[ruby git stdin].include?(kind)
        return "#{kind}:#{path_from(input, dir)}" if input && %w[sdl introspection].include?(kind)

        path_from(value, dir)
      end

      def rebase_ruby(value, dir)
        if value.is_a?(Hash) && value["require"].is_a?(Array)
          value["require"] = map_paths(value["require"], dir)
        end
        value
      end

      def map_paths(values, dir)
        return values.map { |value| path_from(value, dir) } if values.is_a?(Array)

        path_from(values, dir)
      end

      def extension_path(name, dir)
        return name unless name.is_a?(String)
        return path_from(name, dir) if name.start_with?(".") || name.end_with?(".rb")

        name
      end

      def path_from(path, dir)
        path.is_a?(String) ? File.expand_path(path, dir) : path
      end

      def require_extensions(settings)
        settings.fetch("require", []).each { |entry| require extension_path(entry, Dir.pwd) }
      rescue LoadError, StandardError => error
        raise InputError, "Cannot load extension: #{error.message}"
      end

      def validate(settings, keys)
        unknown_keys(settings, keys, "")
        raise InputError, "version must be 1." unless settings["version"].eql?(1)
        check_strings(settings["require"], "require")
        optional_string(settings["baseline"], "baseline")
        enum(settings["fail_level"], SEVERITIES, "fail_level")
        warnings = settings["max_warnings"]
        if !warnings.nil? && (!warnings.is_a?(Integer) || warnings.negative?)
          raise InputError, "max_warnings must be a non-negative integer."
        end
        unless settings["format"].nil?
          formats = Array(settings["format"])
          check_strings(formats, "format")
          formats.each { |format| enum(format.split(":", 2).first, FORMATS, "format") }
        end
        validate_rules(settings["rules"])
        validate_ignore(settings["ignore"])
        suppression = settings["suppression"]
        unknown_keys(suppression, %w[require_reason report_unused], "suppression")
        enum(suppression["require_reason"], [true, false], "suppression.require_reason")
        enum(suppression["report_unused"], %w[off info warning], "suppression.report_unused")
        if settings["git"]
          unknown_keys(settings["git"], ["repository"], "git")
          optional_string(settings["git"]["repository"], "git.repository")
        end
      end

      def validate_rules(rules)
        raise InputError, "rules must be a mapping." unless rules.is_a?(Hash)

        rules.each do |id, value|
          path = "rules.#{id}"
          case value
          when true, false
            next
          when Hash
            unknown_keys(value, %w[severity options exclude], path)
            enum(value["severity"], SEVERITIES + ["off"], "#{path}.severity") if value.key?("severity")
            if value.key?("options") && !value["options"].is_a?(Hash)
              raise InputError, "#{path}.options must be a mapping."
            end
            check_strings(value["exclude"], "#{path}.exclude") if value.key?("exclude")
          else
            enum(value, SEVERITIES + ["off"], path)
          end
        end
      end

      def validate_ignore(entries)
        raise InputError, "ignore must be an array." unless entries.is_a?(Array)

        entries.each_with_index do |entry, index|
          path = "ignore.#{index}"
          unknown_keys(entry, %w[rule reason path coordinate operation], path)
          %w[rule reason].each do |key|
            unless entry[key].is_a?(String) && !entry[key].strip.empty?
              raise InputError, "#{path}.#{key} must be a non-empty string."
            end
          end
          selectors = %w[path coordinate operation].select { |key| entry.key?(key) }
          raise InputError, "#{path} requires path, coordinate, or operation." if selectors.empty?
          selectors.each do |key|
            unless entry[key].is_a?(String) && !entry[key].strip.empty?
              raise InputError, "#{path}.#{key} must be a non-empty string."
            end
          end
        end
      end

      def unknown_keys(value, allowed, path)
        raise InputError, "#{path.empty? ? "Configuration" : path} must be a mapping." unless value.is_a?(Hash)

        key = (value.keys - allowed).first
        return unless key

        candidates = DidYouMean::SpellChecker.new(dictionary: allowed).correct(key.to_s)
        hint = candidates.empty? ? "" : " Did you mean #{candidates.first.inspect}?"
        raise InputError, "Unknown setting #{[path, key].reject { |item| item == "" }.join(".")}.#{hint}"
      end

      def enum(value, choices, path)
        raise InputError, "#{path} must be one of #{choices.join(", ")}." unless choices.include?(value)
      end

      def optional_string(value, path)
        raise InputError, "#{path} must be a string." unless value.nil? || value.is_a?(String)
      end

      def check_strings(value, path)
        raise InputError, "#{path} must be a list of strings." unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
      end

      def stringify(value)
        case value
        when Hash then value.to_h { |key, item| [key.to_s, stringify(item)] }
        when Array then value.map { |item| stringify(item) }
        when Symbol then value.to_s
        else value
        end
      end

      def merge(base, overrides)
        base.merge(overrides) do |key, old, new_value|
          if old.is_a?(Hash) && new_value.is_a?(Hash)
            merge(old, new_value)
          elsif old.is_a?(Hash) && SEVERITIES.include?(new_value)
            old.merge("severity" => new_value)
          elsif SEVERITIES.include?(old) && new_value.is_a?(Hash) && !new_value.key?("severity")
            new_value.merge("severity" => old)
          else
            new_value
          end
        end
      end
    end
  end
end
