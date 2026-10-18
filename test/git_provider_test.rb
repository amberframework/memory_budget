# frozen_string_literal: true
require_relative "portable_toolchain_test"

class GitProviderTest < PortableToolchainTest
  def self.runnable_methods
    instance_methods(false).grep(/^test_/).map(&:to_s)
  end

  def setup
    super
    prepare_dependency_git_profile
    @git_profile = JSON.parse(File.read(File.join(@package, "toolchain.normal.json")))
  end

  def save_git_manifest
    File.write(@git_lock, JSON.pretty_generate(@git_manifest) + "\n")
    @git_profile["git_provider_manifest_sha256"] = hash(@git_lock)
    write_profile("normal", @git_profile)
  end

  def test_bootstrap_restores_private_git_alias_and_reviewed_config
    @environment.merge!("GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "core.sshCommand", "GIT_CONFIG_VALUE_0" => "foreign")
    @environment["RUBYOPT"] = nil
    script = File.join(@temporary, "capture_git_environment.rb")
    File.write(script, <<~RUBY_FIXTURE)
      if $PROGRAM_NAME.end_with?("/run_specs.rb")
        ENV["GIT_EXEC_PATH"] = "/foreign"
        ENV["GIT_CONFIG_COUNT"] = "1"
        ENV["GIT_CONFIG_KEY_0"] = "foreign"
      end
    RUBY_FIXTURE
    @environment["RUBYOPT"] = "-r#{Shellwords.escape(script)}"
    source = File.read(@backend).sub('"fixture_compiled" => true', '"git_path" => ENV.fetch("PATH").split(File::PATH_SEPARATOR).first, "git_exec" => ENV.fetch("GIT_EXEC_PATH"), "git_config_count" => ENV["GIT_CONFIG_COUNT"], "git_allow" => ENV.fetch("GIT_ALLOW_PROTOCOL"), "fixture_compiled" => true')
    write_executable(@backend, source)
    @git_profile["compiler_sha256"] = hash(@backend)
    write_profile("normal", @git_profile)
    output, errors, status = bootstrap("--version")
    assert status.success?, output + errors
    actual = JSON.parse(output)
    assert_equal @git_delegate, actual.fetch("git_path")
    assert_equal @git_helpers, actual.fetch("git_exec")
    assert_nil actual.fetch("git_config_count")
    assert_equal "https:file", actual.fetch("git_allow")
  end

  def test_missing_required_git_lock_refuses
    @environment["MEMORY_BUDGET_GIT_PROVIDER_LOCK"] = nil
    assert_rejected("Git provider requires MEMORY_BUDGET_GIT_PROVIDER_LOCK", "--version")
  end

  def test_git_capability_requires_schema_three
    write_profile("normal", @git_profile.merge("schema_version" => 2))
    assert_rejected("Git provider requires toolchain profile schema 3", "--version")
  end

  def test_missing_git_hash_refuses
    write_profile("normal", @git_profile.reject { |key, _| key == "git_provider_manifest_sha256" })
    assert_rejected("git_provider_manifest_sha256 must be a SHA-256", "--version")
  end

  def test_changed_backend_refuses_then_restores
    original = File.binread(@git_backend)
    File.open(@git_backend, "a") { |file| file.puts "# mutation" }
    assert_rejected("Git provider backend SHA-256 mismatch", "--version")
    File.binwrite(@git_backend, original)
    _output, errors, status = bootstrap("--version")
    assert status.success?, errors
  end

  def test_changed_regular_helper_refuses_then_restores
    path = File.join(@git_helpers, "helper-data")
    original = File.read(path)
    File.write(path, "changed")
    assert_rejected("Git provider helper roster differs", "--version")
    File.write(path, original)
    _output, errors, status = bootstrap("--version")
    assert status.success?, errors
  end

  def test_extra_helper_refuses_then_restores
    path = File.join(@git_helpers, "extra")
    File.write(path, "extra")
    assert_rejected("Git provider helper roster differs", "--version")
    File.unlink(path)
    _output, errors, status = bootstrap("--version")
    assert status.success?, errors
  end

  def test_changed_alias_refuses_then_restores
    path = File.join(@git_helpers, "git-alias")
    File.unlink(path)
    File.symlink("helper-data", path)
    assert_rejected("Git provider helper roster differs", "--version")
    File.unlink(path)
    File.symlink(@git_backend, path)
    _output, errors, status = bootstrap("--version")
    assert status.success?, errors
  end

  def test_omitted_external_target_refuses
    @git_manifest["provider"]["resolved_helper_files"] = []
    save_git_manifest
    assert_rejected("Git provider resolved helper target roster differs", "--version")
  end

  def test_private_delegate_extra_entry_refuses_then_restores
    path = File.join(@git_delegate, "foreign")
    File.write(path, "other executable")
    assert_rejected("Git delegate directory requires exactly its admitted backend alias", "--version")
    File.unlink(path)
    _output, errors, status = bootstrap("--version")
    assert status.success?, errors
  end

  def test_git_version_mismatch_refuses
    @git_manifest["provider"]["version"] = "git version other"
    save_git_manifest
    assert_rejected("Git provider version mismatch", "--version")
  end

  def test_profile_drift_during_git_version_refuses_before_operation
    profile = File.join(@package, "toolchain.normal.json")
    source = File.read(@git_backend).sub('puts "git version fixture-1"', "File.open(#{profile.inspect}, 'a') { |file| file.write(' ') }; puts \"git version fixture-1\"")
    write_executable(@git_backend, source)
    @git_manifest["provider"]["git_sha256"] = hash(@git_backend)
    @git_manifest["provider"]["resolved_helper_files"].find { |row| row.fetch("path") == @git_backend }.merge!("sha256" => hash(@git_backend), "bytes" => File.size(@git_backend))
    save_git_manifest
    assert_rejected("Selected toolchain profile SHA-256 mismatch", "--version")
  end

  def test_legacy_compiler_profile_keeps_its_scope_and_installer_requires_git_capability
    @preserve_legacy_installer_profile = true
    @environment["MEMORY_BUDGET_GIT_PROVIDER_LOCK"] = nil
    legacy = @git_profile.reject { |key, _| key == "git_provider_manifest_sha256" }.merge("schema_version" => 2)
    write_profile("normal", legacy)
    _output, errors, status = bootstrap("--version")
    assert status.success?, errors
    output, errors, status, project = dependencies
    refute status.success?, output + errors
    assert_includes output + errors, "Frozen dependency installation requires toolchain profile schema 3"
    refute File.exist?(File.join(project, "fixture-install.json"))
  end
  def mutate_dependency_git_after(phase, target)
    source = File.read(@minecart)
    operation = "File.open(#{target.inspect}, 'a') { |file| file.puts '# changed during child' }; "
    if phase == :version
      source = source.sub('puts ENV.fetch("FIXTURE_TOOL_VERSION", "Minecart fixture-1")', operation + 'puts ENV.fetch("FIXTURE_TOOL_VERSION", "Minecart fixture-1")')
    else
      source = source.sub('exit ENV.fetch("FIXTURE_INSTALL_EXIT", "0").to_i', operation + 'exit ENV.fetch("FIXTURE_INSTALL_EXIT", "0").to_i')
    end
    write_executable(@minecart, source)
    @git_profile["minecart_sha256"] = hash(@minecart)
    write_profile("normal", @git_profile)
  end

  def restore_dependency_fixture(project, git_source, minecart_source)
    write_executable(@git_backend, git_source)
    write_executable(@minecart, minecart_source)
    @git_profile["minecart_sha256"] = hash(@minecart)
    write_profile("normal", @git_profile)
    FileUtils.remove_entry(project)
    output, errors, status, restored = dependencies
    assert status.success?, output + errors
    assert File.file?(File.join(restored, "fixture-install.json"))
  end

  def test_git_change_after_minecart_version_refuses_before_install
    git_source, minecart_source = File.read(@git_backend), File.read(@minecart)
    mutate_dependency_git_after(:version, @git_backend)
    output, errors, status, project = dependencies
    refute status.success?, output + errors
    assert_includes output + errors, "Git provider backend SHA-256 mismatch"
    refute File.exist?(File.join(project, "fixture-install.json"))
    restore_dependency_fixture(project, git_source, minecart_source)
  end

  def test_git_change_after_install_refuses_success
    git_source, minecart_source = File.read(@git_backend), File.read(@minecart)
    mutate_dependency_git_after(:install, @git_backend)
    output, errors, status, project = dependencies
    refute status.success?, output + errors
    assert_includes output + errors, "Git provider backend SHA-256 mismatch"
    assert File.exist?(File.join(project, "fixture-install.json"))
    restore_dependency_fixture(project, git_source, minecart_source)
  end

  def test_git_manifest_change_after_minecart_version_refuses_before_install
    mutate_dependency_git_after(:version, @git_lock)
    output, errors, status, project = dependencies
    refute status.success?, output + errors
    assert_includes output + errors, "Git provider manifest SHA-256 mismatch"
    refute File.exist?(File.join(project, "fixture-install.json"))
  end

  def test_installed_bundle_keeps_schema_three_capability
    destination = File.join(@temporary, "installed schema three")
    output, errors, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "scripts/install_bundle.rb"), destination)
    assert status.success?, output + errors
    bootstrap_path = File.join(destination, "performance/vendor/memory_budget/scripts/budget.rb")
    environment = @environment.merge("MEMORY_BUDGET_TOOLCHAIN_LOCK" => File.join(@package, "toolchain.normal.json"))
    output, errors, status = Open3.capture3(environment, RbConfig.ruby, bootstrap_path, "--version", chdir: destination)
    assert status.success?, output + errors
    assert JSON.parse(output).fetch("fixture_compiled")
  end
  def test_external_target_bytes_refuse_then_restore
    path = File.join(File.realpath(@temporary), "external git helper")
    original = File.read(path)
    File.open(path, "a") { |file| file.puts "# external mutation" }
    assert_rejected("Git provider resolved helper bytes/mode differ", "--version")
    File.write(path, original)
    _output, errors, status = bootstrap("--version")
    assert status.success?, errors
  end

  def test_private_delegate_permissions_refuse_then_restore
    File.chmod(0o755, @git_delegate)
    assert_rejected("Git delegate directory must be owned by this account with mode 0700", "--version")
    File.chmod(0o700, @git_delegate)
    _output, errors, status = bootstrap("--version")
    assert status.success?, errors
  end

  def test_candidate_generator_discovers_the_exact_backend_and_helper_family
    delegate = File.join(File.realpath(@temporary), "generated git delegate")
    config = {"profile" => "generated fixture provider", "git_path" => @git_backend,
      "git_sha256" => hash(@git_backend), "git_version" => "git version fixture-1", "delegate_directory" => delegate}
    path = File.join(@temporary, "git-roots.json")
    File.write(path, JSON.pretty_generate(config))
    output, errors, status = Open3.capture3(@environment, RbConfig.ruby, File.join(ROOT, "scripts/prepare_git_manifest.rb"), path)
    assert status.success?, output + errors
    manifest = JSON.parse(output)
    assert_equal delegate, manifest.fetch("delegate_directory")
    assert_equal @git_manifest.fetch("provider").fetch("exec_roster"), manifest.fetch("provider").fetch("exec_roster")
    assert_equal @git_manifest.fetch("provider").fetch("resolved_helper_files"), manifest.fetch("provider").fetch("resolved_helper_files")
    assert_equal 0o700, File.stat(delegate).mode & 0o7777
    assert_equal @git_backend, File.readlink(File.join(delegate, "git"))
  end

  def test_generator_wrong_backend_pin_refuses_before_execution_or_creation
    marker = File.join(@temporary, "git-was-executed")
    source = File.read(@git_backend).sub('if ARGV == ["--version"]', "File.write(#{marker.inspect}, 'unexpected'); if ARGV == [\"--version\"]")
    write_executable(@git_backend, source)
    delegate = File.join(File.realpath(@temporary), "refused git delegate")
    config = {"profile" => "refused fixture", "git_path" => @git_backend,
      "git_sha256" => "0" * 64, "git_version" => "git version fixture-1", "delegate_directory" => delegate}
    path = File.join(@temporary, "refused-git-roots.json")
    File.write(path, JSON.generate(config))
    output, errors, status = Open3.capture3(@environment, RbConfig.ruby, File.join(ROOT, "scripts/prepare_git_manifest.rb"), path)
    refute status.success?, output + errors
    assert_includes errors, "Git discovery backend SHA-256 mismatch"
    refute File.exist?(delegate)
    refute File.exist?(marker)
  end

  def test_source_identity_command_uses_admitted_git
    output, errors, status = Open3.capture3(@environment, RbConfig.ruby, File.join(@package, "scripts/source_commit.rb"), chdir: @temporary)
    assert status.success?, output + errors
    assert_equal "a" * 40, output.strip
  end
end
