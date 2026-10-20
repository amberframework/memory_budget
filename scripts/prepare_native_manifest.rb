#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative "native_environment"

# Produce a candidate for review. A separately reviewed schema-2 profile pins
# its exact bytes before any compiler/spec entrypoint admits the candidate.
begin
  abort "Usage: ruby scripts/prepare_native_manifest.rb native-roots.json" unless ARGV.length == 1
  config = JSON.parse(File.read(ARGV.first))
  metadata = MemoryBudget::NativeEnvironment.validate_configuration(config)
  roots = config.fetch("environment").values.flatten.uniq
  roots = roots.reject { |root| roots.any? { |other| root != other && root.start_with?(other + "/") } }
  manifest = metadata.merge("profile" => config.fetch("profile"),
    "platform" => MemoryBudget::NativeEnvironment.platform,
    "directories" => roots.map { |path| MemoryBudget::NativeEnvironment.snapshot_directory(path) },
    "files" => config.fetch("files").map { |path| MemoryBudget::NativeEnvironment.snapshot_entry(path).merge("path" => path) },
    "environment" => config.fetch("environment"), "loader_trace" => config.fetch("loader_trace"))
  MemoryBudget::NativeEnvironment.validate_manifest(manifest)
  puts JSON.pretty_generate(manifest)
rescue MemoryBudget::NativeEnvironment::AdmissionError, JSON::ParserError, Errno::ENOENT, KeyError => error
  abort "Native manifest candidate failed: #{error.message}"
end
