# frozen_string_literal: true

module GraphQL
  module LintCore
    # @api public
    class SourceFile
      Comment = Struct.new(:line, :column, :text, keyword_init: true)
      PROBE = 'type Query { "あ" value: Int }'
      BYTE_COLUMNS = GraphQL.parse(PROBE).definitions.first.fields.first.type.col == PROBE.split("Int").first.bytesize + 1
      TOKEN = /"""(?:\\\x22\x22\x22|(?!""").)*"""|"(?:\\.|[^"\\])*"|#[^\r\n]*|[_A-Za-z][_0-9A-Za-z]*|[^\s,]/m

      attr_reader :path, :text, :kind, :lines

      def initialize(path:, text:, kind: :sdl, prelude: false, generated: false)
        @path, @kind, @prelude, @generated = path, kind, prelude, generated
        raise InputError, "Expected UTF-8 text in #{path}." unless text.is_a?(String)

        @text = text.dup.force_encoding(Encoding::UTF_8)
        raise InputError, "Invalid UTF-8 in #{path}." unless @text.valid_encoding?

        @text = @text.delete_prefix("\uFEFF").freeze
        @lines = @text.lines.freeze
      end

      def prelude? = @prelude
      def generated? = @generated

      # graphql-ruby 2.6.10 computes incorrect columns on an unterminated final line.
      def parse_text = text.end_with?("\n") ? text : text + "\n"

      def location(line, column = nil)
        line, column = line.position if line.respond_to?(:position)
        return if generated? || line.nil?
        column = codepoint_column(line, column)
        Location.new(path: path, line: line, column: column)
      end

      def codepoint_column(line, column)
        if BYTE_COLUMNS && column && lines[line - 1]
          lines[line - 1].byteslice(0, column - 1).to_s.scrub.length + 1
        else
          column
        end
      end

      def name_location(node)
        start = location(node)
        return start unless start && node.respond_to?(:name) && node.name

        tokens, = lexical_index
        index = tokens.bsearch_index { |line, column, _| ([line, column] <=> [start.line, start.column]) >= 0 }
        tokens[index || tokens.length, 8].each do |line, column, token|
          return Location.new(path: path, line: line, column: column) if token == node.name
        end
        start
      end

      def description_style(node)
        return unless node.respond_to?(:description) && node.description
        start = location(node)
        return :block unless start

        lines[start.line - 1][start.column - 1, 3] == '"""' ? :block : :inline
      end

      def comments
        lexical_index.last
      end

      def schema_description(node)
        line, column = node.position
        column = codepoint_column(line, column)
        token = lexical_index.first.bsearch { |row, col, _| ([row, col] <=> [line, column]) >= 0 }&.last
        if token&.start_with?('"')
          GraphQL.parse("#{token} type Description { value: Int }").definitions.first.description
        end
      end

      private

      def lexical_index
        @lexical_index ||= begin
          offsets = [0]
          lines.each { |line| offsets << offsets.last + line.length }
          tokens = []
          remarks = []
          text.scan(TOKEN) do
            match = Regexp.last_match
            line = offsets.bsearch_index { |offset| offset > match.begin(0) } || lines.length
            column = match.begin(0) - offsets[line - 1] + 1
            token = match[0]
            if token.start_with?("#")
              remarks << Comment.new(line: line, column: column, text: token.delete_prefix("#").strip)
            else
              tokens << [line, column, token]
            end
          end
          [tokens.freeze, remarks.freeze]
        end
      end
    end
  end
end
