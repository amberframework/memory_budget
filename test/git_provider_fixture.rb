# frozen_string_literal: true
require_relative "../scripts/git_provider"

module GitProviderFixture
  def prepare_dependency_git_profile
    profile_path = File.join(@package, "toolchain.normal.json")
    profile = JSON.parse(File.read(profile_path))
    root = File.realpath(@temporary)
    unless profile.key?("native_component_manifest_sha256")
      directory = File.join(root, "fixture native directory")
      FileUtils.mkdir_p(directory)
      native = {"schema_version" => 1, "profile" => "dependency-native-fixture",
        "platform" => MemoryBudget::NativeEnvironment.platform,
        "directories" => [MemoryBudget::NativeEnvironment.snapshot_directory(directory)], "files" => [],
        "environment" => {"CRYSTAL_LIBRARY_PATH" => [directory], "DYLD_LIBRARY_PATH" => [directory],
          "PKG_CONFIG_LIBDIR" => [], "PKG_CONFIG_PATH" => []}, "loader_trace" => false}
      @environment["MEMORY_BUDGET_NATIVE_COMPONENT_LOCK"] = File.join(root, "dependency-native.json")
      File.write(@environment.fetch("MEMORY_BUDGET_NATIVE_COMPONENT_LOCK"), JSON.pretty_generate(native) + "\n")
      profile["native_component_manifest_sha256"] = hash(@environment.fetch("MEMORY_BUDGET_NATIVE_COMPONENT_LOCK"))
    end
    @git_backend = File.join(root, "reviewed git backend")
    @git_helpers = File.join(root, "reviewed git helpers")
    @git_delegate = File.join(root, "private git delegate")
    unless File.exist?(@git_backend)
      write_executable(@git_backend, <<~RUBY_FIXTURE)
        #!#{RbConfig.ruby}
        if ARGV == ["--version"]
          puts "git version fixture-1"
        elsif ARGV == ["--exec-path"]
          puts ENV.fetch("GIT_EXEC_PATH", ENV.fetch("FIXTURE_GIT_HELPERS", "/missing"))
        elsif ARGV == ["rev-parse", "HEAD"]
          puts "#{'a' * 40}"
        else
          abort "Unexpected Git fixture operation"
        end
      RUBY_FIXTURE
      FileUtils.mkdir_p(@git_helpers)
      File.write(File.join(@git_helpers, "helper-data"), "reviewed helper bytes\n")
      File.symlink(@git_backend, File.join(@git_helpers, "git-alias"))
      @git_external_helper = File.join(root, "external git helper")
      write_executable(@git_external_helper, "#!#{RbConfig.ruby}\nputs 'external helper'\n")
      File.symlink(@git_external_helper, File.join(@git_helpers, "external-alias"))
      FileUtils.mkdir_p(@git_delegate)
      File.chmod(0o700, @git_delegate)
      File.symlink(@git_backend, File.join(@git_delegate, "git"))
    end
    @environment["FIXTURE_GIT_HELPERS"] = @git_helpers
    @git_manifest = {"schema_version" => 1, "profile" => "dependency-git-fixture",
      "platform" => MemoryBudget::NativeEnvironment.platform, "delegate_directory" => @git_delegate,
      "provider" => {"provider" => "Executable Ruby Git fixture under the admitted Ruby runtime",
        "version" => "git version fixture-1", "git_path" => @git_backend, "git_sha256" => hash(@git_backend),
        "exec_path" => @git_helpers, "exec_roster" => MemoryBudget::GitProvider.helper_roster(@git_helpers),
        "resolved_helper_files" => [@git_backend, File.join(root, "external git helper")].sort.map { |path|
          {"path" => path, "sha256" => hash(path), "bytes" => File.size(path), "mode" => File.stat(path).mode & 0o7777} }}}
    @git_lock = File.join(root, "git-provider.json")
    File.write(@git_lock, JSON.pretty_generate(@git_manifest) + "\n")
    @environment["MEMORY_BUDGET_GIT_PROVIDER_LOCK"] = @git_lock
    profile.merge!("schema_version" => 3, "git_provider_manifest_sha256" => hash(@git_lock))
    write_profile("normal", profile)
  end
end
