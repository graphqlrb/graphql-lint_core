# frozen_string_literal: true

require "graphql"

$results = []
def check(id, desc)
  ok = yield
  $results << [id, ok]
  puts format("%-5s %-4s %s", id, ok ? "OK" : "NG", desc)
rescue => e
  $results << [id, false]
  puts format("%-5s %-4s %s (%s: %s)", id, "ERR", desc, e.class, e.message[0, 80])
end

puts "graphql-ruby #{GraphQL::VERSION} / Ruby #{RUBY_VERSION}"

a = GraphQL.parse("type User { id: ID!\n  name: String! }\ntype Query { user: User }", filename: "a.graphql")
b = GraphQL.parse("extend type User { email: String }", filename: "b.graphql")
merged = GraphQL::Language::Nodes::Document.new(definitions: a.definitions + b.definitions)

check("F-01", "Merged nodes retain filenames, lines, and columns") do
  n = merged.definitions.last
  n.filename == "b.graphql" && n.line == 1 && n.col == 1
end

schema = GraphQL::Schema::BuildFromDefinition.from_document(GraphQL::Schema, merged, default_resolve: nil)
check("F-02", "Extended fields retain their original AST nodes") do
  schema.get_type("User").get_field("email").ast_node.filename == "b.graphql"
end

check("F-03", "The lint suite must validate missing interface fields") do
  GraphQL::Schema.from_definition("type Query { a: A } interface I { x: Int } type A implements I { y: Int }")
  true
end

check("F-04", "The lint suite must check for missing types") do
  begin
    GraphQL.parse("type Query {\n  a: Int\n  b: \n}")
    true
  rescue GraphQL::ParseError
    false
  end
end

check("F-05", "The AST omits comments") do
  d = GraphQL.parse("type Query {\n  # c\n  a: Int\n}")
  f = d.definitions[0].fields[0]
  !f.respond_to?(:comment) || f.comment.nil?
end

check("F-06", "Column units can be detected") do
  col = GraphQL.parse("query A { a(x: \"日本語\") b }").definitions[0].selections[1].col
  unit = { 23 => "code points", 29 => "bytes" }[col]
  puts "            Column unit: #{unit || "unexpected (column #{col})"}"
  !unit.nil?
end

check("F-17", "Static validation can leave fragment resolution to the suite") do
  rules = GraphQL::StaticValidation::ALL_RULES -
          [GraphQL::StaticValidation::FragmentsAreUsed, GraphQL::StaticValidation::FragmentNamesAreUnique]
  s = GraphQL::Schema.from_definition("type Query { a(x: Int): Int }")
  doc = GraphQL.parse("query Q { a(x: 1) ...Missing ... on Query { ...AlsoMissing } }")
  GraphQL::StaticValidation::Validator.new(schema: s, rules: rules)
    .validate(GraphQL::Query.new(s, document: doc))[:errors].empty?
end

v = GraphQL::StaticValidation::Validator.new(schema: schema, rules: GraphQL::StaticValidation::ALL_RULES)
op = GraphQL.parse("query Q { user { ...F } }", filename: "q.graphql")
fr = GraphQL.parse("fragment F on User { nope }", filename: "f.graphql")
unit = GraphQL::Language::Nodes::Document.new(definitions: op.definitions + fr.definitions)
res = v.validate(GraphQL::Query.new(schema, document: unit), validate: true, timeout: 5, max_errors: 100)

check("F-08", "Static validation reports a code and a source filename") do
  e = res[:errors].first.to_h
  e.dig("extensions", "code") == "undefinedField" && e["locations"].first["filename"] == "f.graphql"
end

check("F-09", "Unused-fragment validation runs on an isolated fragment") do
  only = GraphQL::Language::Nodes::Document.new(definitions: fr.definitions)
  v.validate(GraphQL::Query.new(schema, document: only))[:errors].any? { |e| e.to_h.dig("extensions", "code") == "useAndDefineFragment" }
end

check("F-11", "GraphQL::Analysis exposes typed field information") do
  defined?(GraphQL::Analysis::Analyzer) && GraphQL::Analysis::Visitor.method_defined?(:field_definition)
end

check("F-12", "Argument paths require conversion to schema coordinates") do
  s = GraphQL::Schema.from_definition("type Query { a(x: Int): Int }")
  s.query.get_field("a").arguments["x"].path == "Query.a.x"
end

check("F-13", "Ruby-defined fields lack AST nodes") do
  t = Class.new(GraphQL::Schema::Object) { graphql_name "T"; field :a, Integer }
  t.get_field("a").ast_node.nil?
end

ng = $results.reject { |_, ok| ok }.map(&:first)
puts ng.empty? ? "All API probes passed." : "API probes failed: #{ng.join(', ')}"
exit(ng.empty? ? 0 : 1)
