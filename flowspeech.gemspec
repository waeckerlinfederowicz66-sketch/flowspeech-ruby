# frozen_string_literal: true

require_relative "lib/flowspeech/version"

Gem::Specification.new do |spec|
  spec.name = "flowspeech"
  spec.version = FlowSpeech::VERSION
  spec.authors = ["FlowSpeech"]
  spec.email = ["support@flowspeech.io"]

  spec.summary = "Ruby client for the FlowSpeech text-to-speech API"
  spec.description = "Generate context-aware speech, multi-speaker dialogue, and audio metadata with FlowSpeech."
  spec.homepage = "https://flowspeech.io/"
  spec.license = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.6.0")

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/waeckerlinfederowicz66-sketch/flowspeech-ruby"
  spec.metadata["changelog_uri"] = "https://github.com/waeckerlinfederowicz66-sketch/flowspeech-ruby/releases"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "README.md", "LICENSE"]
  end
  spec.require_paths = ["lib"]
end

