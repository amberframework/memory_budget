#!/usr/bin/env ruby
# frozen_string_literal: true
require "digest"
require "json"
require "fileutils"

# Copies the reviewed shared implementation into an app's development tooling.
package_root = File.expand_path("..", __dir__)
destination_root = File.expand_path(ARGV.fetch(0))
manifest_path = File.join(package_root, "PACKAGE_PINS.json")
manifest = JSON.parse(File.read(manifest_path))
abort "Unsupported package manifest" unless manifest.fetch("schema_version") == 1 && manifest.fetch("package_name") == "memory_budget"
def verify_bundle(root, manifest)
  paths = manifest.fetch("files").map { |entry| entry.fetch("file") }
  abort "Bundle paths must be unique and nonempty" if paths.empty? || paths.uniq != paths
  manifest.fetch("files").each do |entry|
    relative = entry.fetch("file")
    abort "Invalid bundle path" if relative.start_with?("/") || relative.split("/").any? { |part| ["..", ".", ""].include?(part) }
    path = File.join(root, relative)
    abort "Bundle must contain ordinary files" unless File.file?(path) && !File.symlink?(path)
    abort "Bundle SHA-256 mismatch: #{relative}" unless Digest::SHA256.file(path).hexdigest == entry.fetch("sha256")
  end
  paths
end
verify_bundle(package_root, manifest)
manifest.fetch("files").each do |entry|
  relative = entry.fetch("file")
  abort "Invalid bundle path" if relative.start_with?("/") || relative.split("/").include?("..")
  source = File.join(package_root, relative)
  abort "Package SHA-256 mismatch: #{relative}" unless Digest::SHA256.file(source).hexdigest == entry.fetch("sha256")
end
bundle_root = File.join(destination_root, "performance", "vendor", "memory_budget")
if File.exist?(bundle_root)
  abort "Existing memory-budget bundle requires --upgrade" unless ARGV.include?("--upgrade")
  previous_manifest = JSON.parse(File.read(File.join(bundle_root, "PACKAGE_PINS.json")))
  previous_paths = verify_bundle(bundle_root, previous_manifest)
  actual_paths = Dir.glob(File.join(bundle_root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.map { |path| path.delete_prefix(bundle_root + "/") }
  abort "Existing bundle file roster differs" unless actual_paths.sort == (previous_paths + ["PACKAGE_PINS.json"]).sort
  (previous_paths - manifest.fetch("files").map { |entry| entry.fetch("file") }).each { |path| File.delete(File.join(bundle_root, path)) }
end
manifest.fetch("files").each do |entry|
  relative = entry.fetch("file")
  destination = File.join(bundle_root, relative)
  FileUtils.mkdir_p(File.dirname(destination))
  FileUtils.cp(File.join(package_root, relative), destination)
end
FileUtils.cp(manifest_path, File.join(bundle_root, "PACKAGE_PINS.json"))
FileUtils.mkdir_p(File.join(destination_root, "performance", "results"))
File.write(File.join(destination_root, "performance", "results", ".gitignore"), "*\n!.gitignore\n")
puts "Installed hash-verified memory_budget #{manifest.fetch('package_version')} in #{destination_root}"
