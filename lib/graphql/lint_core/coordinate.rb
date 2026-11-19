# frozen_string_literal: true

module GraphQL
  module LintCore
    # @api public
    module Coordinate
      module_function

      def for(member)
        return member.coordinate if member.respond_to?(:coordinate)

        name = member.graphql_name
        case member
        when GraphQL::Schema::Argument
          owner = self.for(member.owner)
          member.owner.is_a?(Class) && member.owner < GraphQL::Schema::InputObject ? "#{owner}.#{name}" : "#{owner}(#{name}:)"
        when GraphQL::Schema::Field, GraphQL::Schema::EnumValue then "#{self.for(member.owner)}.#{name}"
        else
          member.is_a?(Class) && member < GraphQL::Schema::Directive ? "@#{name}" : name
        end
      end
    end

    # @api public
    class CoordinatePattern
      def initialize(pattern)
        raise InputError, "Coordinate pattern must be a string." unless pattern.is_a?(String)

        pieces = pattern.scan(/\*\*|\*|[^*]+/).map do |part|
          case part
          when "**" then ".*"
          when "*" then "[^.@():]*"
          else Regexp.escape(part)
          end
        end
        @regexp = Regexp.new("\\A#{pieces.join}\\z", timeout: 1.0)
      end

      def match?(coordinate)
        coordinate && @regexp.match?(coordinate)
      end
    end
  end
end
