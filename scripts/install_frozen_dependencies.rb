#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative "toolchain_profile"
require "yaml"
require "fileutils"

begin
  package_root = File.expand_path("..", __dir__)
  identity = MemoryBudget::ToolchainProfile.resolve(package_root)
  profile = identity.profile
  abort "Frozen dependency installation requires toolchain profile schema 3 with an admitted Git provider" unless profile["schema_version"] == 3
  MemoryBudget::ToolchainProfile.verify_hash_field(profile, "minecart_sha256", identity.profile_path)
  version = profile["minecart_version"]
  abort "Toolchain profile requires a nonblank minecart_version" unless version.is_a?(String) && !version.strip.empty?
  tool = MemoryBudget::ToolchainProfile.executable(ENV["MEMORY_BUDGET_MINECART"], "minecart", "Minecart")
  abort "Minecart SHA-256 mismatch: #{tool}" unless Digest::SHA256.file(tool).hexdigest == profile.fetch("minecart_sha256")
  output, errors, status = Open3.capture3(identity.environment, tool, "--version")
  identity.environment
  abort "Minecart SHA-256 mismatch after version readback" unless Digest::SHA256.file(tool).hexdigest == profile.fetch("minecart_sha256")
  abort "Minecart version mismatch: #{output.strip} #{errors.strip}" unless status.success? && output.strip == version
  pins = %w[shard.yml shard.lock].to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
  manifest = YAML.safe_load(File.read("shard.yml"), permitted_classes: [], permitted_symbols: [], aliases: false)
  lock = YAML.safe_load(File.read("shard.lock"), permitted_classes: [], permitted_symbols: [], aliases: false)
  abort "Package manifest and lock must be maps" unless manifest.is_a?(Hash) && lock.is_a?(Hash)
  locked = lock.fetch("shards")
  abort "Dependency lock must contain a shard map" unless locked.is_a?(Hash)
  dependency_maps = [manifest["dependencies"], manifest["development_dependencies"]].compact
  abort "Dependencies must be maps" unless dependency_maps.all? { |entry| entry.is_a?(Hash) }
  required = dependency_maps.flat_map(&:keys).uniq
  abort "Dependency lock is missing a required shard" unless (required - locked.keys).empty?
  abort "Every locked dependency requires an immutable checksum" unless locked.values.all? { |entry| entry.is_a?(Hash) && entry["checksum"].is_a?(String) && entry["checksum"].match?(/\A(?:git-tree:[0-9a-f]{40}|sha256:[0-9a-f]{64})\z/) }
  FileUtils.mkdir_p("performance/results")
  receipt = identity.to_h.merge("minecart_path" => tool, "minecart_sha256" => profile.fetch("minecart_sha256"), "minecart_version" => output.strip, "dependency_pins" => pins)
  File.write("performance/results/dependency-toolchain.json", JSON.pretty_generate(receipt) + "\n")
  has_installed = system(identity.environment.merge("CRYSTAL_WORKERS" => "1"), tool, "install", "--frozen", "--skip-ai-docs", "--jobs=1")
  identity.environment
  abort "Minecart SHA-256 mismatch after frozen install" unless Digest::SHA256.file(tool).hexdigest == profile.fetch("minecart_sha256")
  abort "Frozen dependency install failed" unless has_installed
  abort "Dependency pins changed" unless pins.all? { |path, hash| Digest::SHA256.file(path).hexdigest == hash }
rescue MemoryBudget::ToolchainProfile::AdmissionError, Errno::ENOENT, Errno::EACCES, Psych::Exception, KeyError => error
  abort error.message
end
