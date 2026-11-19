# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "graphql/lint_core"

class LintCoreOperationsTest < Minitest::Test
  Core = GraphQL::LintCore

  def test_shared_fragment_uses_its_own_location_and_related_operations
    set = document_set(
      "a.graphql" => "query A { ...Shared }",
      "b.gql" => "query B { ...Shared }",
      "shared.gql" => "fragment Shared on Query { missing }"
    )
    assert_empty set.diagnostics
    assert_equal %w[A B], set.operations_for(set.fragments.first)
    errors = Core::OperationValidator.new(schema).validate(set)
    assert_equal 1, errors.size
    assert_equal "spec/fields-on-correct-type", errors.first.rule_id
    assert_equal "shared.gql", errors.first.location.path
    assert_equal %w[A B], errors.first.operations
    assert_equal "missing", errors.first.data.fetch(:extensions).fetch("fieldName")
  end

  def test_fragment_resolution_prefers_local_definition_and_detects_cycles
    documents = {
      "a.graphql" => "query A { ...Shared } fragment Shared on Query { ...Shared }",
      "b.gql" => "fragment Shared on Query { name }",
      "c.gql" => "query C { ...Shared }"
    }
    set = document_set(documents)
    assert_equal ["spec/no-fragment-cycles", "spec/known-fragment-names"], set.diagnostics.map(&:rule_id)
    assert_equal ["A"], set.operations_for(set.fragments.first)
    assert_empty set.operations_for(set.fragments.last)
    assert_equal 1, set.units.count { |unit| unit.definition.fragment? }
    assert_equal 1, set.diagnostics_for(set.units.find { |unit| unit.definition.name == "C" }).size

    same_file = Core::Documents::DocumentSet.new(documents, fragment_resolution: "same_file")
    unknown = same_file.diagnostics.find { |diagnostic| diagnostic.rule_id == "spec/known-fragment-names" }
    assert_empty unknown.related
  end

  def test_static_validation_uses_the_same_local_fragment_resolution_as_the_walker
    set = document_set(
      "query.gql" => "query Q { ...A ...B }",
      "a.gql" => "fragment A on Query { ...Shared } fragment Shared on Query { value: name }",
      "b.gql" => "fragment B on Query { ...Shared } fragment Shared on Query { value: id }"
    )
    assert_empty set.diagnostics
    issues = Core::OperationValidator.new(schema).validate(set)
    assert_includes issues.map(&:rule_id), "spec/overlapping-fields-can-be-merged"
  end

  def test_syntax_executable_definitions_and_anonymous_operations_keep_other_documents
    set = document_set(
      "a.gql" => "type Query { name: String }\n{ name }\nquery Other { name }",
      "b.gql" => "query Broken {",
      "c.gql" => "query Other { name }"
    )
    assert_equal %w[<anonymous>@a.gql#1 Other@a.gql Other@c.gql], set.operations.map(&:display_name)
    assert_equal %w[spec/executable-definitions spec/lone-anonymous-operation core/syntax-error],
      set.diagnostics.map(&:rule_id)
    refute set.diagnostics.last.fatal
  end

  def test_unreferenced_fragments_are_validated
    set = document_set("unused.graphql" => "fragment Unused on Query { missing }")
    diagnostics = Core::OperationValidator.new(schema).validate(set)
    assert_equal ["spec/fields-on-correct-type"], diagnostics.map(&:rule_id)
    assert_empty diagnostics.first.operations
  end

  def test_undefined_variables_in_one_of_objects_are_reported
    set = document_set("query.gql" => "query Q { choose(input: { tag: $undefined }) }")
    loaded = Core::SchemaLoader.load("-", stdin: StringIO.new("type Query { choose(input: Choice): Int } input Choice @oneOf { tag: Int }"))
    refute loaded.fatal?, loaded.diagnostics.map(&:message).join(", ")
    diagnostics = Core::OperationValidator.new(loaded).validate(set)
    assert_includes diagnostics.map(&:rule_id), "spec/no-undefined-variables"
  end

  def test_usage_walker_retains_types_literals_and_fragment_chain
    set = document_set(
      "a.gql" => "query A($input: Search) { ...Shared }",
      "shared.gql" => "fragment Shared on Query { aliasName: name(filter: { tags: [NEW] }) }"
    )
    usage = Core::UsageIndex.new(schema.index, set)
    assert_equal [:type, :variable_type], usage.for_coordinate("Search").map { |ref| [ref.kind, ref.via] }.first
    assert usage.for_coordinate("Search").any? { |ref| ref.via == :literal }
    reference = usage.for_coordinate("Tag.NEW").first
    assert_equal :enum_value, reference.kind
    assert_equal "shared.gql", reference.location.path
    assert_equal ["Shared"], reference.fragment_chain
    assert_equal "A", reference.operation
    assert_equal "NEW", reference.node.name
  end

  def test_naming_rules_and_filename_conversion
    naming = Core::Naming
    rules = naming.validate(style: "PascalCase", suffix: "Query", forbidden_prefixes: ["Old"], allow_leading_underscore: true)
    assert naming.valid?("_HTTPRequestQuery", rules)
    refute naming.valid?("OldGetQuery", rules)
    assert_equal "GetUserQuery", naming.replacement("get_user", rules)
    assert_equal "http-request", naming.convert("HTTPRequest", "kebab-case")
    refute naming.valid?("FindUser", naming.validate(pattern: 'User'))
    assert_raises(Core::ConfigError) { naming.validate(unknown: "setting") }
  end

  private

  def document_set(documents)
    assert defined?(Core::Documents::DocumentSet), "Core should load the document set"
    Core::Documents::DocumentSet.new(documents)
  end

  def schema
    @schema ||= Core::SchemaLoader.load(Class.new(GraphQL::Schema).from_definition(<<~GRAPHQL))
      type Query { name(filter: Search): String id: ID }
      input Search { tags: [Tag!] }
      enum Tag { NEW OLD }
    GRAPHQL
  end
end
