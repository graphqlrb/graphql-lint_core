# frozen_string_literal: true

require "open3"

module GraphQL
  module LintCore
    # @api public
    LoadedSchema = Struct.new(:schema, :document, :sources, :index, :origin, :diagnostics, keyword_init: true) do
      alias source_files sources

      def fatal_diagnostics = diagnostics.select(&:fatal?)
      def fatal? = diagnostics.any?(&:fatal?)
      def generated? = %i[ruby introspection].include?(origin)
    end

    # @api public
    class SchemaLoader
      Nodes = GraphQL::Language::Nodes
      SOURCE_KINDS = %w[sdl git ruby introspection stdin].freeze
      NULL_RESOLVER = ->(*) { raise InputError, "An SDL schema is for static validation only." }

      def self.load(input, **options)
        new(**options).load(input)
      end

      def initialize(prelude: [], stdin: $stdin, skip_checks: [], emit_generated_sdl: nil,
        base_dir: Dir.pwd, repository: nil)
        @prelude, @stdin = Array(prelude), stdin
        @skip_checks, @emit = skip_checks, emit_generated_sdl
        @base_dir, @repository = base_dir, repository || base_dir
        @diagnostics = []
      end

      def load(input)
        entries = input.is_a?(Array) ? input : [input]
        specs = entries.map { |entry| specification(entry) }
        kinds = specs.map(&:first)
        if specs.empty? || (specs.size > 1 && (kinds - %w[sdl git]).any?)
          raise InputError, "A schema requires SDL/git files or one Ruby, introspection, or stdin source."
        end
        origin = kinds.first.to_sym
        preludes = @prelude.flat_map { |pattern| read_glob(pattern, prelude: true) }
        sources = (preludes + specs.flat_map { |kind, value| read_source(kind, value) }).compact.uniq(&:path)
        definitions = sources.flat_map { |source| parse(source) }
        document = Nodes::Document.new(definitions: definitions)
        loaded = LoadedSchema.new(document: document, sources: sources, origin: origin, diagnostics: @diagnostics)
        return loaded if loaded.fatal?

        index = SchemaIndex.new(document, sources)
        loaded.index = index
        Array(@skip_checks).each do |check|
          diagnostic("skipped-schema-check", "Schema check #{check} was skipped.", severity: :warning, fatal: false)
        end
        @diagnostics.concat(TypeSystem.new(document, index, skip: @skip_checks).validate)
        return loaded if loaded.fatal?

        loaded.schema = index.schema = build(builder_document(document, index))
        loaded
      rescue InputError, SystemCallError, IOError => error
        diagnostic("input-error", error.message)
        LoadedSchema.new(sources: [], diagnostics: @diagnostics)
      end

      private

      def specification(entry)
        if entry.is_a?(Class) && entry < GraphQL::Schema
          ["ruby", entry]
        elsif entry.is_a?(Hash)
          kind, value = entry.first
          kind = kind.to_s
          raise InputError, "Invalid schema source #{entry.inspect}." unless entry.size == 1 && SOURCE_KINDS.include?(kind)

          [kind, value]
        elsif entry == "-"
          ["stdin", nil]
        elsif entry.is_a?(String) && !entry.empty?
          prefix, rest = entry.split(":", 2)
          SOURCE_KINDS.include?(prefix) && rest ? [prefix, rest] : ["sdl", entry]
        else
          raise InputError, "A schema source is required."
        end
      end

      def read_source(kind, value)
        case kind
        when "sdl" then read_glob(value)
        when "git" then read_git(value)
        when "stdin" then [source("-", @stdin.read, :stdin)]
        when "ruby"
          [generated_source(ruby_schema(value), :ruby, value)]
        when "introspection"
          data = JSON.parse(File.binread(File.expand_path(value, @base_dir)))
          if data.is_a?(Hash) && data.key?("__schema")
            data = { "data" => data }
          end
          schema = GraphQL::Schema.from_introspection(data)
          diagnostic("limited-input", "Introspection omits most applied directives.", severity: :info, fatal: false)
          [generated_source(schema.to_definition, :introspection, value)]
        end
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError, NoMethodError, GraphQL::Error => error
        raise InputError, "Cannot read #{kind} schema: #{error.message}"
      end

      def read_glob(pattern, prelude: false)
        raise InputError, "SDL path must be a string." unless pattern.is_a?(String) && !pattern.empty?
        paths = Dir.glob(pattern, base: @base_dir).select { |path| File.file?(File.expand_path(path, @base_dir)) }.sort
        raise InputError, "No SDL files match #{pattern.inspect}." if paths.empty?

        paths.map { |path| source(path, File.binread(File.expand_path(path, @base_dir)), :sdl, prelude: prelude) }
      end

      def read_git(spec)
        ref, pattern = if spec.is_a?(Hash)
          values = spec.transform_keys(&:to_s)
          values.values_at("ref", "path")
        else
          spec.to_s.split(":", 2)
        end
        if !ref.is_a?(String) || ref.empty? || ref.start_with?("-") || !pattern.is_a?(String) || pattern.empty?
          raise InputError, "Git input must use git:<ref>:<path or glob>."
        end
        commit = git("rev-parse", "--verify", "--end-of-options", "#{ref}^{commit}").strip
        flags = File::FNM_PATHNAME | File::FNM_EXTGLOB
        files = git("ls-tree", "-r", "-z", "--name-only", commit).split("\0")
        matches = files.select { |path| File.fnmatch?(pattern, path, flags) }.sort
        raise InputError, "No paths at #{ref.inspect} match #{pattern.inspect}." if matches.empty?

        matches.map { |path| source("#{path}@#{ref}", git("show", "#{commit}:#{path}"), :git) }
      end

      def git(*args)
        text, error, status = Open3.capture3({ "GIT_NO_LAZY_FETCH" => "1" }, "git", "-C", @repository, *args, binmode: true)
        raise InputError, "Git input failed: #{error.strip.force_encoding(Encoding::UTF_8).scrub}" unless status.success?

        text.force_encoding(Encoding::UTF_8)
      end

      def ruby_schema(spec)

        options = spec.is_a?(Hash) ? spec.transform_keys(&:to_s) : { "class" => spec }
        Array(options["require"]).each { |file| require File.expand_path(file, @base_dir) }
        schema = options["class"]
        schema = Object.const_get(schema) if schema.is_a?(String)
        unless schema.is_a?(Class) && schema < GraphQL::Schema
          raise InputError, "Ruby schema must be a GraphQL::Schema subclass."
        end

        schema.to_definition(context: options.fetch("context", {}).transform_keys(&:to_sym))
      rescue LoadError, StandardError => error
        raise InputError, "Cannot load Ruby schema: #{error.message}"
      end

      def generated_source(text, kind, value)
        label = value.is_a?(Hash) ? value["class"] || value[:class] : value
        if @emit
          File.binwrite(File.expand_path(@emit, @base_dir), text)
          source(@emit, text, kind)
        else
          source("(generated:#{label})", text, kind, generated: true)
        end
      end

      def source(path, text, kind, **options)
        SourceFile.new(path: path, text: text, kind: kind, **options)
      rescue InputError => error
        diagnostic("syntax-error", error.message, location: Location.new(path: path, line: 1, column: 1))
        nil
      end

      def parse(source)
        GraphQL.parse(source.parse_text, filename: source.path).definitions.reject do |node|
          generated_one_of = %i[ruby introspection].include?(source.kind) &&
            node.is_a?(Nodes::DirectiveDefinition) && node.name == "oneOf" &&
            node.arguments.empty? && !node.repeatable && node.locations.map(&:name) == ["INPUT_OBJECT"]
          generated_one_of
        end.tap do |definitions|
          stack = definitions.dup
          until stack.empty?
            node = stack.pop
            if (node.is_a?(Nodes::FieldDefinition) || node.is_a?(Nodes::InputValueDefinition)) && missing_type?(node.type)
              diagnostic("syntax-error", "Definition `#{node.name}` requires a type.", location: source.location(node))
            end
            stack.concat(node.children)
          end
        end
      rescue GraphQL::ParseError => error
        diagnostic("syntax-error", error.message, location: source.location(error.line, error.col))
        []
      rescue SystemStackError
        diagnostic("syntax-error", "Schema nesting is too deep.", location: Location.new(path: source.path, line: 1, column: 1))
        []
      end

      def missing_type?(type)
        type = type.of_type while type.respond_to?(:of_type)
        type.nil?
      end

      def build(document)
        GraphQL::Schema::BuildFromDefinition.from_document(GraphQL::Schema, document, default_resolve: NULL_RESOLVER)
      rescue StandardError, SystemStackError => error
        diagnostic("schema-build-error", "Cannot build schema: #{error.message}")
        nil
      end

      def builder_document(document, index)
        return document unless document.definitions.grep(Nodes::SchemaExtension).any?

        definitions = document.definitions
        root_nodes = definitions.grep(Nodes::SchemaDefinition)
        schema_definition = Nodes::SchemaDefinition.new(
          **index.roots.transform_keys(&:to_sym), directives: root_nodes.first&.directives || []
        )
        Nodes::Document.new(definitions: [schema_definition, *definitions.reject { |node| node.is_a?(Nodes::SchemaDefinition) }])
      end

      def diagnostic(key, message, severity: :error, location: nil, fatal: true)
        @diagnostics << Diagnostic.new(rule_id: "core/#{key}", severity: severity,
          message: message, location: location, fatal: fatal)
      end
    end
  end
end
