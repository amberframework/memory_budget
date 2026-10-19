# frozen_string_literal: true
require "digest"
require "etc"
require "find"
require "json"

module MemoryBudget
  # Admits a reviewed native search path, including every file and link in it.
  # Loaded-image and behavior checks remain the consumer's acceptance evidence.
  module NativeEnvironment
    class AdmissionError < StandardError; end
    VARIABLES = %w[CRYSTAL_LIBRARY_PATH DYLD_LIBRARY_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_PATH].freeze
    PLATFORM_KEYS = %w[sysname release version machine].freeze

    class Identity
      attr_reader :path, :sha256, :manifest

      def initialize(path, sha256, manifest)
        @path, @sha256, @manifest = path.freeze, sha256.freeze, NativeEnvironment.deep_freeze(manifest)
      end

      def environment
        NativeEnvironment.require_condition(Digest::SHA256.file(path).hexdigest == sha256, "Native manifest SHA-256 mismatch")
        NativeEnvironment.validate_manifest(manifest)
        NativeEnvironment.require_condition(Digest::SHA256.file(path).hexdigest == sha256, "Native manifest changed during admission")
        manifest.fetch("environment").each_with_object({
          "MEMORY_BUDGET_NATIVE_COMPONENT_LOCK" => path,
          "DYLD_PRINT_LIBRARIES" => manifest.fetch("loader_trace") ? "1" : nil
        }) { |(key, paths), result| result[key] = paths.join(File::PATH_SEPARATOR) }
      end
    end

    module_function

    def require_condition(condition, message)
      raise AdmissionError, message unless condition
    end

    def object_keys(value, required, description)
      require_condition(value.is_a?(Hash) && value.keys.sort == required.sort,
        "Invalid #{description} fields; expected #{required.join(', ')}")
    end

    def deep_freeze(value)
      value.each { |key, entry| deep_freeze(key); deep_freeze(entry) } if value.is_a?(Hash)
      value.each { |entry| deep_freeze(entry) } if value.is_a?(Array)
      value.freeze
    end

    def platform
      PLATFORM_KEYS.each_with_object({}) { |key, result| result[key] = Etc.uname.fetch(key.to_sym) }
    end

    def canonical_path(path)
      require_condition(path.is_a?(String) && path.start_with?("/") &&
        !path.match?(/[\x00\r\n:]/) && File.expand_path(path) == path,
        "Native paths must be absolute normalized paths without search-path separators")
      path
    end

    def snapshot_entry(path)
      path = canonical_path(path)
      require_condition(File.realpath(File.dirname(path)) == File.dirname(path), "Native entry parent must be a physical directory: #{path}")
      stat = File.lstat(path)
      base = {"mode" => stat.mode & 0o7777}
      if stat.symlink?
        base.merge("kind" => "symlink", "target" => File.readlink(path), "resolved_path" => File.realpath(path))
      elsif stat.file?
        base.merge("kind" => "file", "sha256" => Digest::SHA256.file(path).hexdigest)
      elsif stat.directory?
        base.merge("kind" => "directory")
      else
        raise AdmissionError, "Native entry must be an ordinary file, directory or symlink: #{path}"
      end
    end

    def snapshot_directory(path)
      path = canonical_path(path)
      require_condition(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path,
        "Native roster root must be a physical versioned directory: #{path}")
      entries = []
      Find.find(path) do |entry|
        next if entry == path
        entries << snapshot_entry(entry).merge("file" => entry.delete_prefix(path + "/"))
      end
      {"path" => path, "mode" => File.stat(path).mode & 0o7777, "entries" => entries.sort_by { |row| row.fetch("file") }}
    end

    # Recompute the full physical roster rather than trusting listed files alone.
    def validate_manifest(manifest)
      object_keys(manifest, %w[schema_version profile platform directories files environment loader_trace], "native manifest")
      require_condition(manifest["schema_version"] == 1, "Unsupported native manifest schema")
      require_condition(manifest["profile"].is_a?(String) && !manifest["profile"].strip.empty?, "Native manifest requires a profile identity")
      require_condition(manifest["platform"] == platform, "Native platform identity differs")
      require_condition([true, false].include?(manifest["loader_trace"]), "Native loader_trace must be a boolean")
      directories = manifest["directories"]
      files = manifest["files"]
      require_condition(directories.is_a?(Array) && !directories.empty? && files.is_a?(Array), "Native directories and files must be arrays")
      directories.each { |row| object_keys(row, %w[path mode entries], "native directory") }
      roots = directories.map { |row| canonical_path(row.fetch("path")) }
      require_condition(roots.uniq == roots, "Native directory roots must be unique")
      require_condition(roots.none? { |root| roots.any? { |other| root != other && root.start_with?(other + "/") } }, "Native directory roots must have separate rosters")
      admitted = {}
      directories.each do |row|
        object_keys(row, %w[path mode entries], "native directory")
        actual = snapshot_directory(row.fetch("path"))
        require_condition(actual == row, "Native directory roster differs: #{row.fetch('path')}")
        admitted[row.fetch("path")] = {"kind" => "directory"}
        row.fetch("entries").each { |entry| admitted[File.join(row.fetch("path"), entry.fetch("file"))] = entry }
      end
      files.each do |row|
        require_condition(row.is_a?(Hash), "Native required file must be an object")
        path = canonical_path(row.fetch("path"))
        require_condition(!admitted.key?(path), "Native required files must be unique and outside directory rosters")
        actual = snapshot_entry(path).merge("path" => path)
        require_condition(actual["kind"] != "directory" && actual == row, "Native required file identity differs: #{path}")
        admitted[path] = row
      end
      admitted.each do |path, row|
        next unless row["kind"] == "symlink"
        target = admitted[row.fetch("resolved_path")]
        require_condition(target && %w[file directory].include?(target["kind"]), "Native symlink target must have its own admitted physical entry: #{path}")
      end
      environment = manifest["environment"]
      object_keys(environment, VARIABLES, "native environment")
      environment.each do |key, paths|
        require_condition(paths.is_a?(Array) && paths.all? { |path| admitted[path] && admitted[path]["kind"] == "directory" } && paths.uniq == paths,
          "#{key} must contain unique admitted physical directories in reviewed order")
      end
      require_condition(!environment.fetch("CRYSTAL_LIBRARY_PATH").empty? && !environment.fetch("DYLD_LIBRARY_PATH").empty?, "Native library search paths must be explicit and nonempty")
      VARIABLES.each do |key|
        aliases = {}
        environment.fetch(key).each do |root|
          admitted.each do |path, row|
            next unless File.dirname(path) == root && row["kind"] != "directory"
            resolved = row["kind"] == "symlink" ? row.fetch("resolved_path") : path
            target = admitted.fetch(resolved)
            next unless target["kind"] == "file"
            digest = target.fetch("sha256")
            name = File.basename(path)
            require_condition(!aliases.key?(name) || aliases[name] == digest, "Ambiguous native search alias: #{name} in #{key}")
            aliases[name] = digest
          end
        end
      end
      manifest
    end

    def admit(expected_sha256, path)
      require_condition(path && !path.empty?, "Native-aware profile requires MEMORY_BUDGET_NATIVE_COMPONENT_LOCK")
      path = File.expand_path(path)
      require_condition(expected_sha256.is_a?(String) && expected_sha256.match?(/\A[0-9a-f]{64}\z/), "Native manifest requires a SHA-256")
      require_condition(File.file?(path) && !File.symlink?(path), "Native manifest must be an ordinary file")
      require_condition(Digest::SHA256.file(path).hexdigest == expected_sha256, "Native manifest SHA-256 mismatch")
      manifest = validate_manifest(JSON.parse(File.read(path)))
      require_condition(Digest::SHA256.file(path).hexdigest == expected_sha256, "Native manifest changed during admission")
      Identity.new(path, expected_sha256, manifest)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, JSON::ParserError, KeyError, TypeError, ArgumentError => error
      raise AdmissionError, "Native admission failed: #{error.message}"
    end
  end
end
