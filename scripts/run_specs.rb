#!/usr/bin/env ruby
# frozen_string_literal: true
require "digest"
require "json"
require "fileutils"
require "open3"

# The boundary accepts an approved compiler/backend and an immutable stdlib source.
package_root = File.expand_path("..", __dir__)
project_root = File.expand_path(ENV.fetch("MEMORY_BUDGET_PROJECT_ROOT", Dir.pwd))
compiler_path = File.expand_path(ENV.fetch("MEMORY_BUDGET_COMPILER"))
expected_compiler_sha256 = ENV.fetch("MEMORY_BUDGET_COMPILER_SHA256")
stdlib_root = File.expand_path(ENV.fetch("MEMORY_BUDGET_STDLIB"))
expected_stdlib_sha256 = ENV.fetch("MEMORY_BUDGET_STDLIB_SHA256")
abort "Compiler SHA-256 mismatch" unless Digest::SHA256.file(compiler_path).hexdigest == expected_compiler_sha256
list_of_stdlib_paths = Dir.glob(File.join(stdlib_root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort
list_of_stdlib_pins = list_of_stdlib_paths.map { |path| "#{Digest::SHA256.file(path).hexdigest}  #{path.delete_prefix(stdlib_root + "/")}\n" }
abort "Stdlib SHA-256 mismatch" unless Digest::SHA256.hexdigest(list_of_stdlib_pins.join) == expected_stdlib_sha256
manifest = JSON.parse(File.read(File.join(package_root, "runtime_overlay", "manifest.json")))
abort "Unsupported counter protocol" unless manifest.fetch("counter_protocol") == 1
manifest.fetch("files").each do |entry|
  source = File.join(package_root, "runtime_overlay", entry.fetch("file"))
  abort "Runtime overlay SHA-256 mismatch" unless Digest::SHA256.file(source).hexdigest == entry.fetch("sha256")
end

cache_root = File.expand_path(ENV.fetch("CRYSTAL_CACHE_DIR"))
FileUtils.mkdir_p(cache_root)
prepared_stdlib = File.join(cache_root, "budget-stdlib")
if File.exist?(prepared_stdlib)
  abort "Prepared stdlib must be a directory" unless File.directory?(prepared_stdlib)
else
  FileUtils.cp_r(stdlib_root, prepared_stdlib)
end
manifest.fetch("files").each do |entry|
  destination = File.join(prepared_stdlib, entry.fetch("file"))
  FileUtils.mkdir_p(File.dirname(destination))
  FileUtils.cp(File.join(package_root, "runtime_overlay", entry.fetch("file")), destination)
end
expected_map_of_stdlib_hashes = list_of_stdlib_paths.each_with_object({}) do |path, hashes|
  hashes[path.delete_prefix(stdlib_root + "/")] = Digest::SHA256.file(path).hexdigest
end
manifest.fetch("files").each { |entry| expected_map_of_stdlib_hashes[entry.fetch("file")] = entry.fetch("sha256") }
list_of_prepared_paths = Dir.glob(File.join(prepared_stdlib, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
actual_map_of_stdlib_hashes = list_of_prepared_paths.each_with_object({}) do |path, hashes|
  hashes[path.delete_prefix(prepared_stdlib + "/")] = Digest::SHA256.file(path).hexdigest
end
abort "Prepared stdlib source mismatch" unless actual_map_of_stdlib_hashes == expected_map_of_stdlib_hashes
environment = {"CRYSTAL_PATH" => "lib:#{prepared_stdlib}", "CRYSTAL_WORKERS" => "1", "MEMORY_BUDGET_REQUIRE_ALLOCATION" => "1"}
arguments = ARGV.empty? ? ["spec", "-Dfiber_allocation_tally"] : ARGV
system(environment, compiler_path, *arguments, chdir: project_root)
exit($?.exitstatus || 2)
