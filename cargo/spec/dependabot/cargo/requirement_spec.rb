# typed: true
# frozen_string_literal: true

require "spec_helper"
require "dependabot/cargo/requirement"

RSpec.describe Dependabot::Cargo::Requirement do
  subject(:requirement) { described_class.new(requirement_string) }

  let(:requirement_string) { ">=1.0.0" }

  describe ".new" do
    it { is_expected.to be_a(described_class) }

    context "with a blank string" do
      let(:requirement_string) { "" }

      it { is_expected.to eq(described_class.new(">= 0")) }
    end

    context "with a pre-release" do
      let(:requirement_string) { "4.0.0-beta3" }

      it "preserves the pre-release formatting" do
        expect(requirement.requirements.first.last.to_s).to eq("4.0.0-beta3")
      end

      it "matches prereleases for the same release" do
        expect(requirement).to be_satisfied_by(Dependabot::Cargo::Version.new("4.0.0-beta4"))
      end

      it "rejects prereleases for a different release" do
        expect(requirement).not_to be_satisfied_by(Dependabot::Cargo::Version.new("4.0.1-beta1"))
      end

      it "recognizes prerelease opt-ins with Cargo and RubyGems prefixes" do
        ["^1.2.3-beta.1", "~1.2.3-beta.1", "~>1.2.3-beta.1"].each do |requirement_string|
          prefixed_requirement = described_class.new(requirement_string)

          expect(prefixed_requirement).to be_satisfied_by(
            Dependabot::Cargo::Version.new("1.2.3-beta.2")
          )
        end
      end
    end

    context "with a build-version" do
      let(:requirement_string) { "4.0.0+something" }

      it "preserves the build version" do
        expect(requirement.requirements.first.last.to_s)
          .to eq("4.0.0+something")
      end
    end

    describe "wildcards" do
      context "with only a *" do
        let(:requirement_string) { "*" }

        it { is_expected.to eq(described_class.new(">= 0")) }
      end

      context "with a 1.*" do
        let(:requirement_string) { "1.*" }

        it { is_expected.to eq(described_class.new("~> 1.0")) }
      end

      context "with a 1.1.*" do
        let(:requirement_string) { "1.1.*" }

        it { is_expected.to eq(described_class.new("~> 1.1.0")) }

        context "when prefixed with a caret" do
          let(:requirement_string) { "^1.1.*" }

          it { is_expected.to eq(described_class.new("~> 1.1.0")) }
        end
      end
    end

    context "with no specifier" do
      let(:requirement_string) { "1.1.0" }

      it { is_expected.to eq(described_class.new(">= 1.1.0", "< 2.0.0")) }
    end

    context "with a caret version" do
      context "when specified to 3 dp" do
        let(:requirement_string) { "^1.2.3" }

        it { is_expected.to eq(described_class.new(">= 1.2.3", "< 2.0.0")) }

        context "with a zero major" do
          let(:requirement_string) { "^0.2.3" }

          it { is_expected.to eq(described_class.new(">= 0.2.3", "< 0.3.0")) }

          context "when a zero minor is present" do
            let(:requirement_string) { "^0.0.3" }

            it { is_expected.to eq(described_class.new(">= 0.0.3", "< 0.0.4")) }
          end
        end
      end

      context "when specified to 2 dp" do
        let(:requirement_string) { "^1.2" }

        it { is_expected.to eq(described_class.new(">= 1.2", "< 2.0")) }

        context "with a zero major" do
          let(:requirement_string) { "^0.2" }

          it { is_expected.to eq(described_class.new(">= 0.2", "< 0.3")) }

          context "when a zero minor is present" do
            let(:requirement_string) { "^0.0" }

            it { is_expected.to eq(described_class.new(">= 0.0", "< 0.1")) }
          end
        end
      end

      context "when specified to 1 dp" do
        let(:requirement_string) { "^1" }

        it { is_expected.to eq(described_class.new(">= 1", "< 2")) }

        context "with a zero major" do
          let(:requirement_string) { "^0" }

          it { is_expected.to eq(described_class.new(">= 0", "< 1")) }
        end
      end
    end

    context "with a ~ version" do
      context "when specified to 3 dp" do
        let(:requirement_string) { "~1.5.1" }

        it { is_expected.to eq(described_class.new("~> 1.5.1")) }
      end

      context "when specified to 2 dp" do
        let(:requirement_string) { "~1.5" }

        it { is_expected.to eq(described_class.new("~> 1.5.0")) }
      end

      context "when specified to 1 dp" do
        let(:requirement_string) { "~1" }

        it { is_expected.to eq(described_class.new("~> 1.0")) }
      end
    end

    context "with a > version specified" do
      let(:requirement_string) { ">1.5.1" }

      it { is_expected.to eq(Gem::Requirement.new("> 1.5.1")) }
    end

    context "with a full = version specified" do
      let(:requirement_string) { "=1.5.0" }

      it { is_expected.to eq(Gem::Requirement.new("1.5.0")) }
    end

    describe "partial comparison requirements" do
      it "matches Cargo's version boundaries" do
        {
          "=0.1" => {
            matches: %w(0.1.0 0.1.99),
            rejects: %w(0.0.99 0.1.99-beta 0.2.0-beta 0.2.0)
          },
          "<=0.1" => {
            matches: %w(0.0.99 0.1.0 0.1.99),
            rejects: %w(0.0.99-beta 0.1.99-beta 0.2.0-beta 0.2.0)
          },
          "<2" => {
            matches: %w(0.0.0 1.99.99),
            rejects: %w(1.99.99-beta 2.0.0-beta 2.0.0)
          },
          ">=1.2" => {
            matches: %w(1.2.0 1.2.99 2.0.0),
            rejects: %w(1.1.99 1.2.99-beta 2.0.0-beta)
          },
          ">1.2" => {
            matches: %w(1.3.0 2.0.0),
            rejects: %w(1.2.0 1.2.99 1.3.0-beta 2.0.0-beta)
          }
        }.each do |partial_requirement, versions|
          cargo_requirement = described_class.new(partial_requirement)

          versions.fetch(:matches).each do |version|
            expect(cargo_requirement).to be_satisfied_by(Dependabot::Cargo::Version.new(version))
          end

          versions.fetch(:rejects).each do |version|
            expect(cargo_requirement).not_to be_satisfied_by(Dependabot::Cargo::Version.new(version))
          end
        end
      end
    end

    context "with an ~> version specified" do
      let(:requirement_string) { "~> 1.5.1" }

      its(:to_s) { is_expected.to eq(Gem::Requirement.new("~> 1.5.1").to_s) }
    end

    context "with a comma separated list" do
      let(:requirement_string) { ">1.5.1, < 2.0.0" }

      it { is_expected.to eq(Gem::Requirement.new("> 1.5.1", "< 2.0.0")) }
    end

    context "when used as a security advisory range" do
      let(:requirement_string) { "<0.3.0" }
      let(:prerelease_version) { Dependabot::Cargo::Version.new("0.3.0-alpha-1") }

      it "compares prereleases numerically without Cargo manifest opt-in rules" do
        expect(requirement).not_to be_satisfied_by(prerelease_version)
        expect(requirement.satisfied_by_for_advisory?(prerelease_version)).to be(true)
      end
    end
  end
end
