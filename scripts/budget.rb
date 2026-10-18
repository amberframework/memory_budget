#!/usr/bin/env ruby
# frozen_string_literal: true
require "digest"
require "json"
require "open3"
require "rbconfig"

# Resolves supported Crystal-alpha wrappers as data, then verifies the backend itself.
package_root = File.expand_path("..", __dir__)
wrapper_path = ENV["MEMORY_BUDGET_COMPILER"] || ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |entry| File.join(entry, "crystal-alpha") }.find { |path| File.executable?(path) }
abort "crystal-alpha is required" unless wrapper_path
compiler_path = File.realpath(wrapper_path)
first_bytes = File.binread(compiler_path, 4096)
if first_bytes.start_with?("#!")
  match = first_bytes.match(/exec\s+["']?([^"'\s]+)/)
  abort "Unrecognized Crystal-alpha wrapper; provide MEMORY_BUDGET_COMPILER" unless match
  compiler_path = File.realpath(match[1])
end
actual_compiler_sha256 = Digest::SHA256.file(compiler_path).hexdigest
profile_path = ENV["MEMORY_BUDGET_TOOLCHAIN_LOCK"] || Dir.glob(File.join(package_root, "toolchain.*.json")).find do |path|
  JSON.parse(File.read(path)).fetch("compiler_sha256") == actual_compiler_sha256
end
abort "Compiler has no approved memory-budget toolchain profile" unless profile_path
profile = JSON.parse(File.read(profile_path))
abort "Compiler SHA-256 mismatch" unless profile.fetch("compiler_sha256") == actual_compiler_sha256
if profile["ruby_sha256"]
  abort "Ruby SHA-256 mismatch" unless Digest::SHA256.file(RbConfig.ruby).hexdigest == profile.fetch("ruby_sha256")
end
output, error_output, status = Open3.capture3(compiler_path, "env", "CRYSTAL_PATH")
abort "Compiler path lookup failed: #{error_output}" unless status.success?
stdlib_root = ENV["MEMORY_BUDGET_STDLIB"] || output.strip.split(":").find { |path| File.file?(File.join(path, "prelude.cr")) }
abort "Cannot locate approved Crystal standard library" unless stdlib_root
ENV["MEMORY_BUDGET_COMPILER"] = compiler_path
ENV["MEMORY_BUDGET_COMPILER_SHA256"] = profile.fetch("compiler_sha256")
ENV["MEMORY_BUDGET_STDLIB"] = stdlib_root
ENV["MEMORY_BUDGET_STDLIB_SHA256"] = profile.fetch("stdlib_sha256")
ENV["CRYSTAL_CACHE_DIR"] ||= File.join(ENV.fetch("TMPDIR", "/tmp"), "memory-budget-#{Digest::SHA256.hexdigest(Dir.pwd)[0, 16]}")
exec RbConfig.ruby, File.join(__dir__, "run_specs.rb"), *ARGV
