# frozen_string_literal: true
require "digest"
require "json"
require "open3"
require_relative "native_environment"

module MemoryBudget
  # Verifies Git's executable family and the private path that selects it.
  module GitProvider
    class AdmissionError < StandardError; end
    PROVIDER_KEYS = %w[provider version git_path git_sha256 exec_path exec_roster resolved_helper_files].freeze

    class Identity
      attr_reader :path, :sha256, :manifest

      def initialize(path, sha256, manifest)
        @path, @sha256, @manifest = path.freeze, sha256.freeze, NativeEnvironment.deep_freeze(manifest)
      end

      def environment
        GitProvider.require_condition(Digest::SHA256.file(path).hexdigest == sha256, "Git provider manifest SHA-256 mismatch")
        GitProvider.validate_manifest(manifest)
        GitProvider.require_condition(Digest::SHA256.file(path).hexdigest == sha256, "Git provider manifest changed during admission")
        directory = manifest.fetch("delegate_directory")
        paths = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).reject { |entry| entry == directory }
        environment = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }
        environment.merge("PATH" => ([directory] + paths).join(File::PATH_SEPARATOR),
          "MEMORY_BUDGET_GIT_PROVIDER_LOCK" => path,
          "GIT_EXEC_PATH" => manifest.fetch("provider").fetch("exec_path"),
          "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL,
          "GIT_TERMINAL_PROMPT" => "0", "GIT_ALLOW_PROTOCOL" => "https:file")
      end

      def verify_version(base_environment = {})
        provider = manifest.fetch("provider")
        output, errors, status = Open3.capture3(base_environment.merge(environment), provider.fetch("git_path"), "--version")
        environment
        GitProvider.require_condition(status.success? && output.strip == provider.fetch("version"),
          "Git provider version mismatch: #{output.strip} #{errors.strip}")
        self
      end
    end

    module_function

    def require_condition(condition, message)
      raise AdmissionError, message unless condition
    end

    def keys(value, required, description)
      require_condition(value.is_a?(Hash) && value.keys.sort == required.sort, "Invalid #{description} fields")
    end

    def physical_file(path)
      NativeEnvironment.canonical_path(path)
      require_condition(File.file?(path) && !File.symlink?(path) && File.realpath(path) == path,
        "Git provider requires a physical executable file: #{path}")
      require_condition(File.executable?(path), "Git provider file is not executable: #{path}")
    end

    def helper_roster(directory)
      snapshot = NativeEnvironment.snapshot_directory(directory)
      snapshot.fetch("entries").map do |row|
        row = row.dup
        if row.fetch("kind") == "file"
          row["bytes"] = File.size(File.join(directory, row.fetch("file")))
        elsif row.fetch("kind") == "symlink"
          require_condition(File.file?(row.fetch("resolved_path")), "Git helper alias requires an ordinary file target")
        end
        row
      end
    end

    def validate_provider(provider)
      keys(provider, PROVIDER_KEYS, "Git executable provider")
      require_condition(provider["provider"].is_a?(String) && !provider["provider"].strip.empty? &&
        provider["version"].is_a?(String) && !provider["version"].strip.empty?, "Git provider and version identities are required")
      git = provider.fetch("git_path")
      physical_file(git)
      require_condition(provider["git_sha256"].is_a?(String) && provider["git_sha256"].match?(/\A[0-9a-f]{64}\z/) &&
        Digest::SHA256.file(git).hexdigest == provider["git_sha256"], "Git provider backend SHA-256 mismatch")
      directory = provider.fetch("exec_path")
      actual = helper_roster(directory)
      require_condition(provider["exec_roster"].is_a?(Array) && !provider["exec_roster"].empty? &&
        provider["exec_roster"] == actual, "Git provider helper roster differs")
      targets = actual.select { |row| row["kind"] == "symlink" }.map { |row| row.fetch("resolved_path") }
        .reject { |path| path.start_with?(directory + "/") }.uniq.sort
      files = provider.fetch("resolved_helper_files")
      require_condition(files.is_a?(Array) && files.map { |row| row["path"] }.sort == targets,
        "Git provider resolved helper target roster differs")
      files.each do |row|
        keys(row, %w[path sha256 mode bytes], "Git resolved helper target")
        physical_file(row.fetch("path"))
        path = row.fetch("path")
        require_condition(Digest::SHA256.file(path).hexdigest == row["sha256"] && File.size(path) == row["bytes"] &&
          File.stat(path).mode & 0o7777 == row["mode"], "Git provider resolved helper bytes/mode differ")
      end
      git
    end

    def validate_manifest(manifest)
      keys(manifest, %w[schema_version profile platform provider delegate_directory], "Git provider manifest")
      require_condition(manifest["schema_version"] == 1, "Unsupported Git provider manifest schema")
      require_condition(manifest["profile"].is_a?(String) && !manifest["profile"].strip.empty?, "Git provider requires a profile identity")
      require_condition(manifest["platform"] == NativeEnvironment.platform, "Git provider platform identity differs")
      git = validate_provider(manifest.fetch("provider"))
      delegate = manifest.fetch("delegate_directory")
      NativeEnvironment.canonical_path(delegate)
      require_condition(File.directory?(delegate) && !File.symlink?(delegate) && File.realpath(delegate) == delegate,
        "Git delegate directory must be physical")
      require_condition(File.stat(delegate).uid == Process.uid && File.stat(delegate).mode & 0o7777 == 0o700,
        "Git delegate directory must be owned by this account with mode 0700")
      require_condition(Dir.children(delegate) == ["git"] && File.symlink?(File.join(delegate, "git")) &&
        File.readlink(File.join(delegate, "git")) == git && File.realpath(File.join(delegate, "git")) == git,
        "Git delegate directory requires exactly its admitted backend alias")
      manifest
    rescue NativeEnvironment::AdmissionError => error
      raise AdmissionError, error.message
    end

    def admit(expected_hash, lock)
      require_condition(lock.is_a?(String) && !lock.empty?, "Git provider requires MEMORY_BUDGET_GIT_PROVIDER_LOCK")
      path = File.expand_path(lock)
      require_condition(expected_hash.is_a?(String) && expected_hash.match?(/\A[0-9a-f]{64}\z/) &&
        Digest::SHA256.file(path).hexdigest == expected_hash, "Git provider manifest SHA-256 mismatch")
      manifest = JSON.parse(File.read(path))
      validate_manifest(manifest)
      require_condition(Digest::SHA256.file(path).hexdigest == expected_hash, "Git provider manifest changed during admission")
      Identity.new(path, expected_hash, manifest)
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError, KeyError => error
      raise AdmissionError, "Git provider admission failed: #{error.message}"
    end
  end
end
