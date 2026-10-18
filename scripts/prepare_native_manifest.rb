#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative "native_environment"

# Produce a candidate for review. A separately reviewed schema-2 profile pins
# its exact bytes before any compiler/spec entrypoint admits the candidate.
begin
  abort "Usage: ruby scripts/prepare_native_manifest.rb native-roots.json" unless ARGV.length == 1
  config = JSON.parse(File.read(ARGV.first))
  MemoryBudget::NativeEnvironment.object_keys(config, %w[profile environment files loader_trace], "native roots configuration")
  MemoryBudget::NativeEnvironment.object_keys(config.fetch("environment"), MemoryBudget::NativeEnvironment::VARIABLES, "native environment")
  roots = config.fetch("environment").values.flatten.uniq
  roots = roots.reject { |root| roots.any? { |other| root != other && root.start_with?(other + "/") } }
  manifest = {"schema_version" => 1, "profile" => config.fetch("profile"),
    "platform" => MemoryBudget::NativeEnvironment.platform,
    "directories" => roots.map { |path| MemoryBudget::NativeEnvironment.snapshot_directory(path) },
    "files" => config.fetch("files").map { |path| MemoryBudget::NativeEnvironment.snapshot_entry(path).merge("path" => path) },
    "environment" => config.fetch("environment"), "loader_trace" => config.fetch("loader_trace")}
  MemoryBudget::NativeEnvironment.validate_manifest(manifest)
  puts JSON.pretty_generate(manifest)
rescue MemoryBudget::NativeEnvironment::AdmissionError, JSON::ParserError, Errno::ENOENT, KeyError => error
  abort "Native manifest candidate failed: #{error.message}"
end
