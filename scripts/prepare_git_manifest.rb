#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative "git_provider"

# Discover a candidate from an independently pinned Git backend. Review and pin
# its output in a schema-3 profile before using the ordinary installer.
created_directory = nil
begin
  abort "Usage: ruby scripts/prepare_git_manifest.rb git-roots.json" unless ARGV.length == 1
  config = JSON.parse(File.read(ARGV.first))
  MemoryBudget::GitProvider.keys(config, %w[profile git_path git_sha256 git_version delegate_directory], "Git roots configuration")
  git = config.fetch("git_path")
  MemoryBudget::GitProvider.physical_file(git)
  pin = config.fetch("git_sha256")
  MemoryBudget::GitProvider.require_condition(pin.is_a?(String) && pin.match?(/\A[0-9a-f]{64}\z/) &&
    Digest::SHA256.file(git).hexdigest == pin, "Git discovery backend SHA-256 mismatch")
  environment = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }
  environment.merge!("GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_TERMINAL_PROMPT" => "0")
  version, errors, status = Open3.capture3(environment, git, "--version")
  MemoryBudget::GitProvider.require_condition(status.success? && version.strip == config.fetch("git_version"), "Git discovery version mismatch: #{version.strip} #{errors.strip}")
  MemoryBudget::GitProvider.require_condition(Digest::SHA256.file(git).hexdigest == pin, "Git discovery backend changed")
  directory, errors, status = Open3.capture3(environment, git, "--exec-path")
  MemoryBudget::GitProvider.require_condition(status.success?, "Git helper discovery failed: #{errors.strip}")
  directory = directory.strip
  roster = MemoryBudget::GitProvider.helper_roster(directory)
  targets = roster.select { |row| row["kind"] == "symlink" }.map { |row| row.fetch("resolved_path") }
    .reject { |path| path.start_with?(directory + "/") }.uniq.sort
  provider = {"provider" => "Reviewed installed Git", "version" => version.strip, "git_path" => git,
    "git_sha256" => pin, "exec_path" => directory, "exec_roster" => roster,
    "resolved_helper_files" => targets.map { |path| {"path" => path, "sha256" => Digest::SHA256.file(path).hexdigest,
      "bytes" => File.size(path), "mode" => File.stat(path).mode & 0o7777} }}
  MemoryBudget::GitProvider.validate_provider(provider)
  delegate = MemoryBudget::NativeEnvironment.canonical_path(config.fetch("delegate_directory"))
  MemoryBudget::GitProvider.require_condition(File.realpath(File.dirname(delegate)) == File.dirname(delegate), "Git delegate parent must be physical")
  unless File.exist?(delegate) || File.symlink?(delegate)
    Dir.mkdir(delegate, 0o700)
    created_directory = [delegate, File.stat(delegate).dev, File.stat(delegate).ino]
    File.symlink(git, File.join(delegate, "git"))
  end
  manifest = {"schema_version" => 1, "profile" => config.fetch("profile"),
    "platform" => MemoryBudget::NativeEnvironment.platform, "provider" => provider, "delegate_directory" => delegate}
  MemoryBudget::GitProvider.validate_manifest(manifest)
  puts JSON.pretty_generate(manifest)
rescue MemoryBudget::GitProvider::AdmissionError, MemoryBudget::NativeEnvironment::AdmissionError,
       JSON::ParserError, Errno::ENOENT, Errno::EACCES, KeyError => error
  if created_directory
    directory, device, inode = created_directory
    if File.directory?(directory) && !File.symlink?(directory) && File.stat(directory).dev == device &&
       File.stat(directory).ino == inode && Dir.children(directory) == ["git"] &&
       File.symlink?(File.join(directory, "git")) && File.readlink(File.join(directory, "git")) == git
      File.unlink(File.join(directory, "git"))
      Dir.rmdir(directory)
    end
  end
  abort "Git manifest candidate failed: #{error.message}"
end
