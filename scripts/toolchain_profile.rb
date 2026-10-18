# frozen_string_literal: true
require "digest"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require_relative "native_environment"

module MemoryBudget
  # Resolves ordinary installation paths, then admits their exact identities.
  module ToolchainProfile
    class AdmissionError < StandardError; end

    class Identity
      attr_reader :profile_path, :profile, :compiler_path, :entrypoint_path, :stdlib_root

      def initialize(profile_path, profile, compiler_path, entrypoint_path, stdlib_root, profile_sha256 = Digest::SHA256.file(profile_path).hexdigest)
        @profile_path, @profile = profile_path, profile
        @compiler_path, @entrypoint_path, @stdlib_root = compiler_path, entrypoint_path, stdlib_root
        @profile_sha256 = profile_sha256
      end

      def environment
        ToolchainProfile.read_admitted_profile(profile_path, @profile_sha256)
        raise AdmissionError, "Compiler SHA-256 mismatch" unless Digest::SHA256.file(compiler_path).hexdigest == profile.fetch("compiler_sha256")
        raise AdmissionError, "Ruby SHA-256 mismatch" unless Digest::SHA256.file(RbConfig.ruby).hexdigest == profile.fetch("ruby_sha256")
        raise AdmissionError, "Stdlib SHA-256 mismatch" unless ToolchainProfile.stdlib_sha256(stdlib_root) == profile.fetch("stdlib_sha256")
        if profile.key?("wrapper_sha256") && Digest::SHA256.file(entrypoint_path).hexdigest != profile.fetch("wrapper_sha256")
          raise AdmissionError, "wrapper SHA-256 mismatch"
        end
        {"MEMORY_BUDGET_COMPILER" => entrypoint_path, "MEMORY_BUDGET_TOOLCHAIN_LOCK" => profile_path,
         "MEMORY_BUDGET_TOOLCHAIN_PROFILE_SHA256" => @profile_sha256,
         "MEMORY_BUDGET_COMPILER_ENTRYPOINT" => entrypoint_path,
         "MEMORY_BUDGET_STDLIB" => stdlib_root}.merge(ToolchainProfile.native_environment(profile))
      end

      def to_h
        environment
        result = {"profile" => profile.fetch("profile"), "profile_path" => profile_path,
         "profile_sha256" => @profile_sha256,
         "compiler_path" => compiler_path, "compiler_sha256" => Digest::SHA256.file(compiler_path).hexdigest,
         "entrypoint_path" => entrypoint_path, "entrypoint_sha256" => Digest::SHA256.file(entrypoint_path).hexdigest,
         "stdlib_root" => stdlib_root, "stdlib_sha256" => profile.fetch("stdlib_sha256"),
         "ruby_path" => File.realpath(RbConfig.ruby), "ruby_sha256" => Digest::SHA256.file(RbConfig.ruby).hexdigest,
         "counter_protocol" => profile.fetch("counter_protocol")}
        if profile.key?("ruby_launcher_sha256")
          launcher = ToolchainProfile.executable(ENV["MEMORY_BUDGET_RUBY_LAUNCHER"], "ruby", "Ruby launcher")
          result.merge!("ruby_launcher_path" => launcher, "ruby_launcher_sha256" => Digest::SHA256.file(launcher).hexdigest)
        end
        if profile["schema_version"] == 2
          result["native_component_manifest_sha256"] = profile.fetch("native_component_manifest_sha256")
          result["native_environment"] = ToolchainProfile.native_environment(profile)
        end
        result
      end
    end

    module_function

    def executable(explicit_path, command, description)
      path = explicit_path || ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |entry| File.join(entry, command) }.find { |entry| File.file?(entry) && File.executable?(entry) }
      raise AdmissionError, "#{description} executable is unavailable; install the admitted tool and check PATH" unless path && File.file?(path) && File.executable?(path)
      File.realpath(path)
    end

    def compiler_backend(entrypoint)
      source = File.binread(entrypoint, 4096)
      return entrypoint unless source.start_with?("#!")
      commands = source.lines.reject { |line| line.lstrip.start_with?("#") }.map do |line|
        tokens = Shellwords.split(line)
        position = tokens.index("exec")
        tokens.drop(position + 1) if position
      end.compact
      if commands.size != 1 || commands.first.empty? || commands.first.drop(1) != ["$@"]
        raise AdmissionError, "Unrecognized Crystal-alpha wrapper; use a reviewed static absolute exec wrapper or admitted backend profile"
      end
      backend = commands.first.first
      unless backend.start_with?("/") && !backend.match?(/[\$`\n]/)
        raise AdmissionError, "Crystal-alpha wrapper must declare a static absolute backend path"
      end
      executable(backend, "crystal-alpha", "Crystal-alpha backend")
    rescue ArgumentError => error
      raise AdmissionError, "Invalid Crystal-alpha wrapper: #{error.message}"
    end

    def stdlib_sha256(root)
      paths = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort
      Digest::SHA256.hexdigest(paths.map { |path| "#{Digest::SHA256.file(path).hexdigest}  #{path.delete_prefix(root + "/")}\n" }.join)
    end

    def read_profile(path)
      profile = JSON.parse(File.read(path))
      raise AdmissionError, "Invalid toolchain profile #{path}" unless profile.is_a?(Hash) && [1, 2].include?(profile["schema_version"])
      raise AdmissionError, "Toolchain profile requires a nonblank profile identity: #{path}" unless profile["profile"].is_a?(String) && !profile["profile"].strip.empty?
      raise AdmissionError, "Unsupported toolchain counter protocol: #{path}" unless profile["counter_protocol"] == 1
      %w[compiler_sha256 stdlib_sha256 ruby_sha256].each { |key| verify_hash_field(profile, key, path) }
      %w[wrapper_sha256 ruby_launcher_sha256 minecart_sha256].each { |key| verify_hash_field(profile, key, path) if profile.key?(key) }
      if profile["schema_version"] == 2
        verify_hash_field(profile, "native_component_manifest_sha256", path)
      elsif profile.key?("native_component_manifest_sha256")
        raise AdmissionError, "Native components require toolchain profile schema 2: #{path}"
      end
      profile
    end

    def verify_hash_field(profile, key, path)
      raise AdmissionError, "#{key} must be a SHA-256 in #{path}" unless profile[key].is_a?(String) && profile[key].match?(/\A[0-9a-f]{64}\z/)
    end

    def read_admitted_profile(path, expected_hash)
      unless path && expected_hash && expected_hash.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(path).hexdigest == expected_hash
        raise AdmissionError, "Selected toolchain profile SHA-256 mismatch"
      end
      profile = read_profile(path)
      raise AdmissionError, "Selected toolchain profile changed during admission" unless Digest::SHA256.file(path).hexdigest == expected_hash
      profile
    end

    def native_environment(profile)
      lock = ENV["MEMORY_BUDGET_NATIVE_COMPONENT_LOCK"]
      if profile["schema_version"] == 2
        NativeEnvironment.admit(profile.fetch("native_component_manifest_sha256"), lock).environment
      else
        raise AdmissionError, "Native component lock requires toolchain profile schema 2" if lock
        {}
      end
    rescue NativeEnvironment::AdmissionError => error
      raise AdmissionError, error.message
    end

    # The bootstrap admits the wrapper, then delegates to its backend. Recheck
    # that same selection at the Ruby boundary instead of selecting a new profile.
    def revalidate_selection
      profile = read_admitted_profile(ENV["MEMORY_BUDGET_TOOLCHAIN_LOCK"], ENV["MEMORY_BUDGET_TOOLCHAIN_PROFILE_SHA256"])
      raise AdmissionError, "Ruby SHA-256 mismatch" unless Digest::SHA256.file(RbConfig.ruby).hexdigest == profile.fetch("ruby_sha256")
      if profile.key?("ruby_launcher_sha256")
        launcher = executable(ENV["MEMORY_BUDGET_RUBY_LAUNCHER"], "ruby", "Ruby launcher")
        raise AdmissionError, "Ruby launcher SHA-256 mismatch" unless Digest::SHA256.file(launcher).hexdigest == profile.fetch("ruby_launcher_sha256")
      end
      raise AdmissionError, "Selected compiler entrypoint is missing" unless ENV["MEMORY_BUDGET_COMPILER_ENTRYPOINT"]
      backend = executable(ENV["MEMORY_BUDGET_COMPILER"], "crystal-alpha", "Admitted Crystal-alpha backend")
      entrypoint = executable(ENV["MEMORY_BUDGET_COMPILER_ENTRYPOINT"], "crystal-alpha", "Admitted Crystal-alpha entrypoint")
      unless compiler_backend(entrypoint) == backend && Digest::SHA256.file(backend).hexdigest == profile.fetch("compiler_sha256")
        raise AdmissionError, "Selected compiler/backend SHA-256 mismatch"
      end
      if entrypoint != backend && !profile.key?("wrapper_sha256")
        raise AdmissionError, "Selected script wrapper requires wrapper_sha256"
      end
      if profile.key?("wrapper_sha256") && Digest::SHA256.file(entrypoint).hexdigest != profile.fetch("wrapper_sha256")
        raise AdmissionError, "Selected wrapper SHA-256 mismatch"
      end
      unless ENV["MEMORY_BUDGET_COMPILER_SHA256"] == profile.fetch("compiler_sha256") && ENV["MEMORY_BUDGET_STDLIB_SHA256"] == profile.fetch("stdlib_sha256")
        raise AdmissionError, "Selected compiler/stdlib profile differs"
      end
      native_environment(profile)
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => error
      raise AdmissionError, "Selected toolchain admission failed: #{error.message}"
    end

    def resolve(package_root)
      entrypoint = executable(ENV["MEMORY_BUDGET_COMPILER"], "crystal-alpha", "Crystal-alpha")
      compiler = compiler_backend(entrypoint)
      explicit_profile = ENV["MEMORY_BUDGET_TOOLCHAIN_LOCK"]
      paths = explicit_profile ? [File.expand_path(explicit_profile)] : Dir.glob(File.join(package_root, "toolchain.*.json")).sort
      raise AdmissionError, "No approved memory-budget toolchain profile; install a reviewed profile or set MEMORY_BUDGET_TOOLCHAIN_LOCK" if paths.empty?
      if expected_hash = ENV["MEMORY_BUDGET_TOOLCHAIN_PROFILE_SHA256"]
        unless explicit_profile && Digest::SHA256.file(paths.first).hexdigest == expected_hash
          raise AdmissionError, "Toolchain profile SHA-256 mismatch"
        end
      end
      compiler_hash = Digest::SHA256.file(compiler).hexdigest
      ruby_hash = Digest::SHA256.file(RbConfig.ruby).hexdigest
      entrypoint_hash = Digest::SHA256.file(entrypoint).hexdigest
      profiles = paths.map do |path|
        profile_sha256 = expected_hash || Digest::SHA256.file(path).hexdigest
        profile = read_admitted_profile(path, profile_sha256)
        [path, profile, profile_sha256]
      end
      reasons = []
      candidates = profiles.select do |path, profile|
        errors = []
        errors << "Compiler SHA-256 mismatch" unless profile.fetch("compiler_sha256") == compiler_hash
        errors << "Ruby SHA-256 mismatch" unless profile.fetch("ruby_sha256") == ruby_hash
        errors << "script wrapper requires wrapper_sha256" if entrypoint != compiler && !profile.key?("wrapper_sha256")
        errors << "wrapper SHA-256 mismatch" if profile.key?("wrapper_sha256") && profile.fetch("wrapper_sha256") != entrypoint_hash
        if profile.key?("ruby_launcher_sha256")
          begin
            launcher = executable(ENV["MEMORY_BUDGET_RUBY_LAUNCHER"], "ruby", "Ruby launcher")
            errors << "Ruby launcher SHA-256 mismatch" unless profile.fetch("ruby_launcher_sha256") == Digest::SHA256.file(launcher).hexdigest
          rescue AdmissionError => error
            errors << error.message
          end
        end
        reasons << "#{File.basename(path)}: #{errors.join(', ')}" unless errors.empty?
        errors.empty?
      end
      raise AdmissionError, "No approved memory-budget toolchain profile matches: #{reasons.join('; ')}" if candidates.empty?
      stdlib_root = ENV["MEMORY_BUDGET_STDLIB"]
      unless stdlib_root
        output, errors, status = Open3.capture3(compiler, "env", "CRYSTAL_PATH")
        raise AdmissionError, "Compiler path lookup failed: #{errors.strip}" unless status.success?
        stdlib_root = output.strip.split(File::PATH_SEPARATOR).find { |path| File.file?(File.join(path, "prelude.cr")) }
      end
      raise AdmissionError, "Cannot locate approved Crystal standard library; supply its installed path with MEMORY_BUDGET_STDLIB" unless stdlib_root && File.file?(File.join(stdlib_root, "prelude.cr"))
      stdlib_root = File.realpath(stdlib_root)
      stdlib_hash = stdlib_sha256(stdlib_root)
      matches = candidates.select { |_path, profile| profile.fetch("stdlib_sha256") == stdlib_hash }
      raise AdmissionError, "No approved memory-budget toolchain profile matches: Stdlib SHA-256 mismatch" if matches.empty?
      if matches.size > 1
        raise AdmissionError, "Ambiguous approved memory-budget toolchain profiles: #{matches.map(&:first).join(', ')}; select one with MEMORY_BUDGET_TOOLCHAIN_LOCK"
      end
      path, profile, profile_sha256 = matches.first
      native_environment(profile)
      Identity.new(path, profile, compiler, entrypoint, stdlib_root, profile_sha256)
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => error
      raise AdmissionError, "Toolchain admission failed: #{error.message}"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    abort "Usage: ruby scripts/toolchain_profile.rb [--json]" unless ARGV.empty? || ARGV == ["--json"]
    puts JSON.pretty_generate(MemoryBudget::ToolchainProfile.resolve(File.expand_path("..", __dir__)).to_h)
  rescue MemoryBudget::ToolchainProfile::AdmissionError => error
    abort error.message
  end
end
