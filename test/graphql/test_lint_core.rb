# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "stringio"

class TestLintCore < Minitest::Test
  Core = GraphQL::LintCore

  def test_indexes_extensions_with_original_positions
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.graphql"), 'type Query { user(id: ID!): User } type User { id: ID! }')
      File.write(File.join(dir, "b.graphql"), "extend type User {\n  name: String\n}")
      loaded = Core::SchemaLoader.load("#{dir}/*.graphql")
      refute loaded.fatal?, loaded.diagnostics.map(&:message).join("\n")
      assert_equal "ID!", loaded.index.find("Query.user(id:)").type.to_s
      assert_equal 2, loaded.index.find("User.name").location.line
      assert loaded.index.types.fetch("User").reachable?
    end
  end

  def test_loads_stdin_and_canonicalizes_defaults
    text = 'input Filter { b: Boolean a: Int } type Query { list(f: Filter = {b: true, a: 1}): [String!]! }'
    loaded = Core::SchemaLoader.load("-", stdin: StringIO.new(text))
    refute loaded.fatal?
    assert_equal [:non_null, :list, :non_null], loaded.index.find("Query.list").type.wrappers
    assert_equal "{a: 1, b: true}", loaded.index.find("Query.list(f:)").default_value.literal
  end

  def test_type_system_rejects_invalid_schemas_before_build
    examples = {
      "TS-01" => 'type Query { a: Int } type Query { b: Int }',
      "TS-02" => 'type Query { a: Int a: String }',
      "TS-03" => 'type Query { a: Unknown }',
      "TS-04" => 'type Query { a: Int } extend type Missing { b: Int }',
      "TS-05" => 'interface I { a: Int } type Query implements I { b: Int }',
      "TS-06" => 'input I { a: Int } type Query { a: I }',
      "TS-07" => 'union U = Int type Query { a: U }',
      "TS-08" => 'type Unused { a: Int }',
      "TS-09" => 'directive @d(n: Int!) on FIELD_DEFINITION type Query { a: Int @d(n: "x") }',
      "TS-10" => 'type Query { __hidden: Int }',
      "TS-11" => 'type Query { a: E } enum E',
      "TS-12" => 'input I @oneOf { a: Int! } type Query { a(i: I): Int }',
      "TS-13" => 'type Query { a(i: Int! @deprecated): Int }',
      "TS-14" => 'input I { i: I! } type Query { a(i: I): Int }',
      "TS-15" => 'type Query { a(i: Int = "bad"): Int }',
      "TS-16" => 'interface I implements I { a: Int } type Query { a: Int }'
    }
    examples.each do |check, sdl|
      loaded = Core::SchemaLoader.load("-", stdin: StringIO.new(sdl))
      assert loaded.fatal?, check
      assert_includes loaded.diagnostics.map { |d| d.data[:check] }, check
    end
  end

  def test_coordinate_patterns_respect_separators
    assert Core::CoordinatePattern.new("Query.*(*:)").match?("Query.user(id:)")
    refute Core::CoordinatePattern.new("Query.*").match?("Query.user(id:)")
    assert Core::CoordinatePattern.new("Query.**").match?("Query.user(id:)")
  end

  def test_comments_skip_hashes_inside_strings
    source = Core::SourceFile.new(path: "schema.graphql", text: %Q{"""\n# inside\n"""\ntype Query { a: Int } # outside\n})
    assert_equal ["outside"], source.comments.map(&:text)
    assert_equal [4], source.comments.map(&:line)
  end

  def test_config_extends_files_and_rejects_unknown_keys
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.yml"), "version: 1\nfail_level: warning\nrules: {rule-one: error}\n")
      file = File.join(dir, "project.yml")
      File.write(file, "version: 1\nextends: base.yml\nrules: {rule-one: off}\n")
      config = Core::Config.load(file, defaults: {}, overrides: { locale: "ja" })
      assert_equal "warning", config.fetch("fail_level")
      assert_includes [false, "off"], config.fetch("rules").fetch("rule-one")
      assert_equal "ja", config.fetch("locale")
      assert_raises(Core::InputError) { Core::Config.load({ version: 1, typo: "foo" }, defaults: {}) }
    end
  end

  def test_suppression_and_result_formats
    source = Core::SourceFile.new(path: "a.graphql", text: "# graphql-lint-disable-next-line test-rule\n\nquery A { a }\n")
    diagnostic = Core::Diagnostic.new(rule_id: "test-rule", severity: :error, message: "A problem",
      location: Core::Location.new(path: "a.graphql", line: 3, column: 1))
    result = Core::Result.new(diagnostics: [diagnostic], sources: [source], tool: "test", version: "0.1.0")
    assert_equal 0, result.exit_status
    assert_equal :comment, result.diagnostics.first.suppressed_by
    assert_empty result.reportable
    assert_equal 1, JSON.parse(result.to_json).dig("summary", "suppressed", "comment")
    assert_equal "2.1.0", JSON.parse(Core::Formatter.render("sarif", result)).fetch("version")
  end
end

class TestSchemaInputs < Minitest::Test
  Core = GraphQL::LintCore

  def test_loads_full_and_unwrapped_introspection_payloads
    schema = GraphQL::Schema.from_definition("type Query { answer: Int }")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "introspection.json")
      data = schema.as_json
      [data, data.fetch("data")].each do |payload|
        File.write(path, JSON.generate(payload))
        loaded = Core::SchemaLoader.load("introspection:#{path}")
        refute loaded.fatal?, loaded.diagnostics.map(&:message).join("\n")
        assert_equal "Int", loaded.index.find("Query.answer").type.to_s
        assert_nil loaded.index.find("Query.answer").location
        assert loaded.index.find("__Type").builtin?
        assert_includes loaded.diagnostics.map(&:rule_id), "core/limited-input"
      end
    end
  end

  def test_reports_type_failures_in_japanese
    loaded = Core::SchemaLoader.load("-", stdin: StringIO.new("type Query { a: Missing }"), locale: "ja")
    assert_match(/型.*Missing.*未定義/, loaded.fatal_diagnostics.first.message)
    refute_match(/Unknown type/, loaded.fatal_diagnostics.first.message)
  end

  def test_preserves_generated_sdl_locations_on_request
    schema = GraphQL::Schema.from_definition("type Query { answer: Int }")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "generated.graphql")
      loaded = Core::SchemaLoader.load(schema, emit_generated_sdl: path)
      refute loaded.fatal?
      assert_equal path, loaded.index.find("Query.answer").location.path
      assert_includes File.binread(path), "answer: Int"
    end
  end

  def test_reports_invalid_utf8_without_aborting_the_other_sources
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "a.graphql"), "\xFF".b)
      File.write(File.join(dir, "b.graphql"), "type Query {")
      loaded = Core::SchemaLoader.load("#{dir}/*.graphql")
      assert_equal 2, loaded.fatal_diagnostics.size
      assert_equal ["a.graphql", "b.graphql"], loaded.fatal_diagnostics.map { |item| File.basename(item.location.path) }
    end
  end

  def test_uses_codepoint_columns_on_unterminated_final_lines
    loaded = Core::SchemaLoader.load("-", stdin: StringIO.new("# comment\n" + 'type Query { "日本語" value: Int }'))
    assert_equal 2, loaded.index.find("Query.value").name_location.line
    assert_equal 20, loaded.index.find("Query.value").name_location.column
  end
end

class TestCoreIntegration < Minitest::Test
  Core = GraphQL::LintCore

  def test_schema_extension_roots_are_available_to_static_validation
    sdl = "schema { query: Query } extend schema { mutation: Mutation } type Query { ok: Boolean } type Mutation { run: Boolean }"
    result = Core::SchemaLoader.load("-", stdin: StringIO.new(sdl))
    refute result.fatal?
    assert_equal "Mutation", result.index.roots.fetch("mutation")
    assert_equal "Mutation", result.schema.mutation.graphql_name
  end

  def test_loads_ruby_graphql_schemas_with_one_of
    sdl = "input Choice @oneOf { a: Int } type Query { value(choice: Choice): Int }"
    schema = GraphQL::Schema.from_definition(sdl)
    result = Core::SchemaLoader.load(schema)
    refute result.fatal?, result.diagnostics.map(&:message).join("\n")
    assert result.index.find("Choice").one_of?
  end

  def test_executable_directive_argument_types_are_reachable
    sdl = "directive @toggle(choice: Choice) on FIELD enum Choice { ON OFF } type Query { ok: Boolean }"
    result = Core::SchemaLoader.load("-", stdin: StringIO.new(sdl))
    refute result.fatal?
    assert_equal :input, result.index.find("Choice").position
  end

  def test_rejects_invalid_suppression_filters_and_config_types
    invalid = [
      { ignore: [{ rule: "example", reason: "legacy", coordinate: nil }] },
      { version: 1.0 },
      { max_warnings: false }
    ]
    invalid.each { |settings| assert_raises(Core::InputError) { Core::Config.load(settings, defaults: {}) } }
  end

  def test_rule_shorthand_preserves_inherited_exclude
    result = Core::Config.load({ rules: { example: "error" } },
      defaults: { rules: { example: { severity: "warning", exclude: ["Old"] } } })
    assert_equal({ "severity" => "error", "exclude" => ["Old"] }, result.dig("rules", "example"))
  end

  def test_reenabling_one_rule_after_disabling_all
    source = Core::SourceFile.new(path: "a.graphql", text: <<~GRAPHQL)
      # graphql-lint-disable
      # graphql-lint-enable example
      query A { a }
    GRAPHQL
    records = %w[example other].map do |id|
      Core::Diagnostic.new(rule_id: id, severity: :warning, message: id,
        location: Core::Location.new(path: source.path, line: 3, column: 1))
    end
    result = Core::Result.new(diagnostics: records, tool: "test", version: "1", sources: [source],
      config: { "suppression" => { "report_unused" => "warning" } })
    assert_equal ["example"], result.reportable.map(&:rule_id)
    assert_equal :comment, result.diagnostics.last.suppressed_by
  end
end

class TestCoreBoundaries < Minitest::Test
  Core = GraphQL::LintCore

  def test_baseline_suppresses_only_the_recorded_count_and_prunes_resolved_entries
    record = Core::Diagnostic.new(rule_id: "test", severity: :warning, coordinate: "Query.a", message: "A problem")
    Dir.mktmpdir do |directory|
      path = File.join(directory, "baseline.json")
      before = Core::Result.new(diagnostics: [record], tool: "test", version: "1")
      Core::Baseline.write(path, before)
      result = Core::Result.new(diagnostics: [record, record], tool: "test", version: "1",
        config: { "baseline" => path, "max_warnings" => 0 })
      assert_equal 1, result.exit_status
      assert_equal 1, result.reportable.length
      assert_equal 1, result.summary.dig(:suppressed, :baseline)

      empty = Core::Result.new(diagnostics: [], tool: "test", version: "1", config: { "baseline" => path })
      assert_equal 1, empty.baseline_resolved
      Core::Baseline.write(path, empty, prune: true)
      assert_empty Core::Baseline.read(path, "test")
    end
  end

  def test_directive_locations_and_unbounded_float_are_input_failures
    sdl = 'directive @test on OBJECT type Query { a(value: Float = 1e999): Int @test }'
    result = nil
    capture_io { result = Core::SchemaLoader.load("-", stdin: StringIO.new(sdl)) }
    assert result.fatal?
    assert_equal ["TS-09", "TS-15"], result.fatal_diagnostics.map { |item| item.data[:check] }.sort
  end
end
