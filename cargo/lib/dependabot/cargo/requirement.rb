# typed: strict
# frozen_string_literal: true

################################################################################
# For more details on rust version constraints, see:                           #
# - https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html     #
# - https://steveklabnik.github.io/semver/semver/index.html                    #
################################################################################

require "sorbet-runtime"

require "dependabot/requirement"
require "dependabot/utils"
require "dependabot/cargo/version"

module Dependabot
  module Cargo
    class Requirement < Dependabot::Requirement
      extend T::Sig

      quoted = OPS.keys.map { |k| Regexp.quote(k) }.join("|")
      version_pattern = Cargo::Version::VERSION_PATTERN

      PATTERN_RAW = T.let("\\s*(#{quoted})?\\s*(#{version_pattern})\\s*".freeze, String)
      PATTERN = /\A#{PATTERN_RAW}\z/
      PARTIAL_COMPARISON_PATTERN = /\A\s*(<=|>=|=|<|>)\s*(\d+(?:\.\d+)?)\s*\z/
      CARGO_PREFIX_PATTERN = /\A(?:\^|~(?!>))\s*/

      # Use Cargo::Version rather than Gem::Version to ensure that
      # pre-release versions aren't transformed.
      sig { override.params(obj: T.any(Gem::Version, String)).returns([String, Gem::Version]) }
      def self.parse(obj)
        return ["=", Cargo::Version.new(obj.to_s)] if obj.is_a?(Gem::Version)

        unless (matches = PATTERN.match(obj.to_s))
          msg = "Illformed requirement [#{obj.inspect}]"
          raise BadRequirementError, msg
        end

        return DefaultRequirement if matches[1] == ">=" && matches[2] == "0"

        [matches[1] || "=", Cargo::Version.new(T.must(matches[2]))]
      end

      # For consistency with other languages, we define a requirements array.
      # Rust doesn't have an `OR` separator for requirements, so it always
      # contains a single element.
      sig { override.params(requirement_string: T.nilable(String)).returns(T::Array[Requirement]) }
      def self.requirements_array(requirement_string)
        [new(requirement_string)]
      end

      # Parses a pre-commit Rust additional_dependency string.
      # Formats: "package_name:version", "cli:package_name:version"
      sig { params(dep_string: String).returns(T.nilable(T::Hash[Symbol, T.nilable(String)])) }
      def self.parse_dep_string(dep_string)
        stripped = dep_string.strip
        return nil if stripped.empty?

        parts = stripped.split(":", -1)

        cli = false
        if parts.first&.downcase == "cli"
          return nil if parts.length < 3

          cli = true
          parts.shift
        end

        return nil if parts.length < 2

        name = T.must(parts[0])
        constraint = T.must(parts[1..]).join(":")
        return nil if name.empty? || constraint.strip.empty?

        constraint = constraint.strip
        version = extract_version(constraint)

        {
          name: name,
          normalised_name: name,
          version: version,
          requirement: constraint,
          extras: cli ? "cli" : nil
        }
      end

      sig { params(constraint: String).returns(T.nilable(String)) }
      def self.extract_version(constraint)
        version_part = constraint.sub(/\A(?:[~^]|[><=]+)\s*/, "")

        return nil unless Cargo::Version.correct?(version_part)

        version_part
      end

      private_class_method :extract_version

      sig { params(requirements: T.nilable(T.any(String, T::Array[String]))).void }
      def initialize(*requirements)
        raw_requirements = requirements.flatten
        @prerelease_versions = T.let(
          raw_requirements
            .flat_map { |req_string| T.must(req_string).split(",") }
            .filter_map do |req_string|
              matches = PATTERN.match(req_string.strip.sub(CARGO_PREFIX_PATTERN, ""))
              next unless matches&.[](2)

              version = Cargo::Version.new(T.must(matches[2]))
              version if version.prerelease?
            end,
          T::Array[Gem::Version]
        )

        requirements = raw_requirements.flat_map do |req_string|
          T.must(req_string).split(",").map(&:strip).map do |r|
            convert_rust_constraint_to_ruby_constraint(r.strip)
          end
        end

        super(requirements)
      end

      sig { override.params(version: Gem::Version).returns(T::Boolean) }
      def satisfied_by?(version)
        version = Cargo::Version.new(version.to_s)

        prerelease_allowed?(version) && requirements_satisfied_by?(version)
      end

      sig do
        params(
          version: Gem::Version,
          prerelease_requirement: Requirement
        ).returns(T::Boolean)
      end
      def satisfied_by_with_prerelease_context?(version, prerelease_requirement)
        version = Cargo::Version.new(version.to_s)

        prerelease_requirement.prerelease_allowed?(version) && requirements_satisfied_by?(version)
      end

      sig { override.params(version: Gem::Version).returns(T::Boolean) }
      def satisfied_by_for_advisory?(version)
        requirements_satisfied_by?(Cargo::Version.new(version.to_s))
      end

      protected

      sig { params(version: Gem::Version).returns(T::Boolean) }
      def prerelease_allowed?(version)
        return true unless version.prerelease?

        @prerelease_versions.any? { |requirement_version| requirement_version.release == version.release }
      end

      private

      sig { params(version: Gem::Version).returns(T::Boolean) }
      def requirements_satisfied_by?(version)
        requirements.all? { |operator, requirement| (OPS[operator] || OPS["="]).call(version, requirement) }
      end

      sig { params(req_string: String).returns(T.any(String, T::Array[String])) }
      def convert_rust_constraint_to_ruby_constraint(req_string)
        if req_string.include?("*")
          ruby_range(req_string.gsub(/(?:\.|^)[*]/, "").gsub(/^[^\d]/, ""))
        elsif req_string.match?(/^~[^>]/) then convert_tilde_req(req_string)
        elsif req_string.match?(/^[\d^]/) then convert_caret_req(req_string)
        elsif req_string.match?(/[<=>]/) then convert_comparison_req(req_string)
        else
          ruby_range(req_string)
        end
      end

      sig { params(req_string: String).returns(T.any(String, T::Array[String])) }
      def convert_comparison_req(req_string)
        matches = PARTIAL_COMPARISON_PATTERN.match(req_string)
        return req_string unless matches

        operator = T.must(matches[1])
        parts = T.must(matches[2]).split(".").map(&:to_i)
        lower_bound = (parts + Array.new(3 - parts.length, 0)).join(".")
        upper_parts = parts.map.with_index do |part, index|
          index == parts.length - 1 ? part + 1 : part
        end
        upper_bound = (upper_parts + Array.new(3 - upper_parts.length, 0)).join(".")

        case operator
        when "=" then [">= #{lower_bound}", "< #{upper_bound}"]
        when "<=" then "< #{upper_bound}"
        when "<" then "< #{lower_bound}"
        when ">=" then ">= #{lower_bound}"
        when ">" then ">= #{upper_bound}"
        else req_string
        end
      end

      sig { params(req_string: String).returns(String) }
      def convert_tilde_req(req_string)
        version = req_string.gsub(/^~/, "")
        parts = version.split(".")
        parts << "0" if parts.count < 3
        "~> #{parts.join('.')}"
      end

      sig { params(req_string: String).returns(String) }
      def ruby_range(req_string)
        parts = req_string.split(".")

        # If we have three or more parts then this is an exact match
        return req_string if parts.count >= 3

        # If we have no parts then the version is completely unlocked
        return ">= 0" if parts.none?

        # If we have fewer than three parts we do a partial match
        parts << "0"
        "~> #{parts.join('.')}"
      end

      sig { params(req_string: String).returns(T::Array[String]) }
      def convert_caret_req(req_string)
        version = req_string.gsub(/^\^/, "")
        parts = version.split(".")
        first_non_zero = parts.find { |d| d != "0" }
        first_non_zero_index =
          first_non_zero ? T.must(parts.index(first_non_zero)) : parts.count - 1
        upper_bound = parts.map.with_index do |part, i|
          if i < first_non_zero_index then part
          elsif i == first_non_zero_index then (part.to_i + 1).to_s
          else
            0
          end
        end.join(".")

        [">= #{version}", "< #{upper_bound}"]
      end
    end
  end
end

Dependabot::Utils
  .register_requirement_class("cargo", Dependabot::Cargo::Requirement)
