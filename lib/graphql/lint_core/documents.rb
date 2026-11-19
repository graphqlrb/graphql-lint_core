# frozen_string_literal: true

module GraphQL
  module LintCore
    module Documents
      class DocumentSource
        def each_document
          raise NotImplementedError
        end
      end

      class FileSource < DocumentSource
        FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
        EXTENSIONS = %w[.graphql .gql].freeze

        def initialize(include:, exclude: [])
          @included = Array(include)
          @excluded = Array(exclude)
        end

        def each_document
          paths = @included.flat_map { |pattern| Dir.glob(pattern) }
          paths.map { |path| path.tr("\\", "/") }.uniq.sort.each do |path|
            next unless EXTENSIONS.include?(File.extname(path)) && File.file?(path)
            next if @excluded.any? { |pattern| File.fnmatch?(pattern, path, FLAGS) }

            yield path, File.binread(path)
          end
        rescue SystemCallError => error
          raise InputError, error.message
        end
      end

      class Definition
        attr_reader :node, :source, :ordinal
        attr_accessor :display_name

        def initialize(node, source, ordinal)
          @node = node
          @source = source
          @ordinal = ordinal
        end

        def path = source.path
        def name = node.name
        def kind = operation? ? node.operation_type : "fragment"
        def operation? = node.is_a?(GraphQL::Language::Nodes::OperationDefinition)
        def fragment? = !operation?
        def location = source.location(node.line, node.col)
      end

      Document = Data.define(:source, :definitions) do
        def path = source.path
        def location = source.location(1, 1)
      end

      Unit = Data.define(:definition, :document, :fragments, :sources, :fragment_aliases) do
        def operation = definition.operation? ? definition : nil
      end

      class DocumentSet
        attr_reader :documents, :operations, :fragments, :diagnostics, :sources, :units, :spreads

        def initialize(documents, fragment_resolution: "global")
          @resolution = fragment_resolution.to_s
          unless %w[global same_file].include?(@resolution)
            raise ConfigError, "documents.fragment_resolution must be global or same_file."
          end

          @sources = []
          @documents = []
          @operations = []
          @fragments = []
          @diagnostics = []
          @spreads = []
          @owners = {}.compare_by_identity
          @targets = {}.compare_by_identity
          @edges = {}
          @unresolved_names = {}
          @issues = []
          @uses = Hash.new { |hash, key| hash[key] = [] }
          collect(documents)
          name_operations
          resolve_spreads
          find_cycles
          build_units
          @diagnostics.concat(@issues.map { |definition, attributes| Diagnostic.new(**attributes, operations: operations_for(definition)) })
          @diagnostics.sort_by!(&:sort_key)
        end

        def resolve(spread_node)
          @targets[spread_node]
        end

        def owner(node)
          @owners[node]
        end

        def operations_for(definition_or_node)
          definition = definition_or_node.is_a?(Definition) ? definition_or_node : owner(definition_or_node)
          return [] unless definition
          return [definition.display_name] if definition.operation?

          @uses.fetch(definition, [])
        end

        def diagnostics_for(unit)
          names = operations_for(unit.definition)
          diagnostics.select do |diagnostic|
            (!names.empty? && (diagnostic.operations & names).any?) ||
              (diagnostic.operations.empty? && diagnostic.location&.path == unit.definition.path)
          end
        end

        private

        def collect(input)
          entries = {}
          if input.respond_to?(:each_document)
            input.each_document { |path, text| entries[path.to_s.tr("\\", "/")] = text }
          elsif input.is_a?(Hash)
            input.each { |path, text| entries[path.to_s.tr("\\", "/")] = text }
          else
            raise InputError, "Documents must be a path-to-text mapping or a document source."
          end

          entries.sort.each { |path, text| parse(path, text) }
        end

        def parse(path, text)
          source = SourceFile.new(path: path, text: text)
          @sources << source
          nodes = GraphQL.parse(source.parse_text, filename: path).definitions
          definitions = executable_definitions(nodes, source)
          @documents << Document.new(source: source, definitions: definitions)
        rescue GraphQL::ParseError => error
          location = source.location(error.line || 1, error.col || 1)
          @diagnostics << Diagnostic.new(rule_id: "core/syntax-error", severity: :error,
            message: error.message, location: location)
        rescue InputError => error
          @diagnostics << Diagnostic.new(rule_id: "core/syntax-error", severity: :error,
            message: error.message, location: Location.new(path: path, line: 1, column: 1))
        end

        def executable_definitions(nodes, source)
          operation_number = 0
          definitions = nodes.filter_map do |node|
            case node
            when GraphQL::Language::Nodes::OperationDefinition
              definition = Definition.new(node, source, operation_number += 1)
              @operations << definition
            when GraphQL::Language::Nodes::FragmentDefinition
              unless node.name
                executable_error(source, node, "An executable fragment must have a name.")
                next
              end

              definition = Definition.new(node, source, nil)
              definition.display_name = definition.name
              @fragments << definition
            else
              executable_error(source, node, "A schema definition cannot occur in an executable document.")
              next
            end
            @owners[node] = definition
            definition
          end
          if operation_number > 1
            definitions.select { |definition| definition.operation? && !definition.name }.each do |definition|
              @issues << [definition, { rule_id: "spec/lone-anonymous-operation", severity: :error,
                message: "An anonymous operation must be the only operation in its file.",
                location: definition.location }]
            end
          end
          definitions
        end

        def executable_error(source, node, message)
          @diagnostics << Diagnostic.new(rule_id: "spec/executable-definitions", severity: :error,
            message: message, location: source.location(node.line, node.col))
        end

        def name_operations
          names = @operations.group_by(&:name)
          names.each do |name, definitions|
            per_file = definitions.group_by(&:path)
            definitions.each do |definition|
              definition.display_name = if !name
                "<anonymous>@#{definition.path}##{definition.ordinal}"
              elsif definitions.size == 1
                name
              elsif per_file.fetch(definition.path).size == 1
                "#{name}@#{definition.path}"
              else
                "#{name}@#{definition.path}##{definition.ordinal}"
              end
            end
          end
        end

        def resolve_spreads
          candidates_by_name = @fragments.group_by(&:name)
          (@operations + @fragments).each do |definition|
            @edges[definition] = []
            @unresolved_names[definition] = []
            stack = definition.node.selections.reverse
            until stack.empty?
              node = stack.pop
              @owners[node] = definition
              if node.is_a?(GraphQL::Language::Nodes::FragmentSpread)
                @spreads << node
                candidates = candidates_by_name.fetch(node.name, [])
                local = candidates.select { |candidate| candidate.path == definition.path }
                candidates = local if !local.empty? || @resolution == "same_file"
                if candidates.size == 1
                  @edges[definition] << [node, candidates.first]
                  @targets[node] = candidates.first
                else
                  @unresolved_names[definition] << node.name
                  @issues << [definition, { rule_id: "spec/known-fragment-names", severity: :error,
                    message: "Fragment `#{node.name}` could not be resolved.",
                    location: definition.source.location(node.line, node.col),
                    data: { fragment: node.name },
                    related: candidates.map { |candidate| { location: candidate.location, message: "Candidate definition" } } }]
                end
              elsif node.respond_to?(:selections)
                stack.concat(node.selections.reverse)
              end
            end
          end
        end

        def find_cycles
          state = {}
          @fragments.each do |fragment|
            next if state.key?(fragment)

            state[fragment] = :active
            stack = [[fragment, @edges.fetch(fragment).each]]
            until stack.empty?
              definition, edges = stack.last
              begin
                node, target = edges.next
              rescue StopIteration
                state[definition] = :done
                stack.pop
                next
              end
              if state[target] == :active
                start = stack.index { |item, _| item.equal?(target) }
                names = stack.drop(start).map { |item, _| item.name } << target.name
                @issues << [definition, { rule_id: "spec/no-fragment-cycles", severity: :error,
                  message: "Fragment cycle: #{names.join(' -> ')}.",
                  location: definition.source.location(node.line, node.col),
                  data: { fragments: names } }]
              elsif !state.key?(target)
                state[target] = :active
                stack << [target, @edges.fetch(target).each]
              end
            end
          end
        end

        def build_units
          source_index = @sources.to_h { |source| [source.path, source] }
          @units = @operations.map do |operation|
            fragments = dependencies(operation)
            fragments.each { |fragment| @uses[fragment] << operation.display_name }
            build_unit(operation, fragments, source_index)
          end
          @fragments.each do |fragment|
            next if @uses.key?(fragment)

            @units << build_unit(fragment, dependencies(fragment), source_index)
          end
        end

        def dependencies(definition)
          visited = { definition => true }
          stack = @edges.fetch(definition).reverse.map(&:last)
          fragments = []
          until stack.empty?
            current = stack.pop
            next if visited[current]

            visited[current] = true
            fragments << current
            stack.concat(@edges.fetch(current).reverse.map(&:last))
          end
          fragments
        end

        def build_unit(definition, fragments, sources)
          definitions = [definition, *fragments]
          groups = definitions.select(&:fragment?).group_by(&:name)
          duplicated = groups.values.select { |items| items.length > 1 }.flatten
          unresolved = definitions.flat_map { |item| @unresolved_names.fetch(item) }.uniq & groups.keys
          aliases = {}

          if duplicated.empty? && unresolved.empty?
            nodes = definitions.map(&:node)
          else
            renamed = {}
            (duplicated.map { |item| [item, item.name] } + unresolved.map { |name| [name, name] }).each_with_index do |(key, name), index|
              label = "GraphqlLintFragment#{index + 1}"
              label += "_" while groups.key?(label) || aliases.key?(label)
              aliases[label] = name
              renamed[key] = label
            end

            # The validator resolves fragment names globally inside each synthetic document.
            nodes = definitions.map do |item|
              node = rewrite_spreads(item.node, renamed)
              renamed.key?(item) ? node.merge(name: renamed.fetch(item)) : node
            end
          end

          document = GraphQL::Language::Nodes::Document.new(definitions: nodes)
          Unit.new(definition: definition, document: document, fragments: fragments, sources: sources, fragment_aliases: aliases)
        end

        def rewrite_spreads(node, renamed)
          if node.is_a?(GraphQL::Language::Nodes::FragmentSpread)
            target = @targets[node] || node.name
            replacement = renamed[target]
            return replacement ? node.merge(name: replacement) : node
          end
          return node unless node.respond_to?(:selections) && !node.selections.empty?

          selections = node.selections.map { |selection| rewrite_spreads(selection, renamed) }
          selections.zip(node.selections).all? { |new, old| new.equal?(old) } ? node : node.merge(selections: selections)
        end
      end
    end
    DocumentSet = Documents::DocumentSet
  end
end
