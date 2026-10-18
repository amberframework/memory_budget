# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "open3"
require "rbconfig"
require "yaml"
require "shellwords"

class PortableToolchainTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @temporary = Dir.mktmpdir("atlas-portable-")
    @package = File.join(@temporary, "package")
    FileUtils.mkdir_p(@package)
    %w[scripts templates runtime_overlay].each { |path| FileUtils.cp_r(File.join(ROOT, path), @package) }
    @prefix = File.join(@temporary, "ordinary-prefix")
    @bin = File.join(@prefix, "bin")
    FileUtils.mkdir_p(@bin)
    @stdlib = File.join(@prefix, "share", "crystal", "src")
    FileUtils.mkdir_p(@stdlib)
    File.write(File.join(@stdlib, "prelude.cr"), "# fixture standard library\n")
    @compiler_log = File.join(@temporary, "compiler-calls.jsonl")
    @backend = File.join(@prefix, "libexec", "crystal-alpha-bin")
    FileUtils.mkdir_p(File.dirname(@backend))
    write_executable(@backend, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("FIXTURE_COMPILER_LOG"), "a") { |file| file.puts(JSON.generate(ARGV)) }
      if ARGV == ["env", "CRYSTAL_PATH"]
        puts ENV.fetch("FIXTURE_STDLIB")
      else
        puts JSON.generate({"fixture_compiled" => true, "arguments" => ARGV, "stdlib" => ENV.fetch("CRYSTAL_PATH"), "workers" => ENV.fetch("CRYSTAL_WORKERS"), "allocation" => ENV.fetch("MEMORY_BUDGET_REQUIRE_ALLOCATION")})
      end
    RUBY
    @wrapper = File.join(@bin, "crystal-alpha")
    write_executable(@wrapper, "#!/bin/sh\nexec #{Shellwords.escape(@backend)} \"$@\"\n")
    @minecart = File.join(@bin, "minecart")
    write_executable(@minecart, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      if ARGV == ["--version"]
        puts ENV.fetch("FIXTURE_TOOL_VERSION", "Minecart fixture-1")
      else
        File.write("fixture-install.json", JSON.generate({"arguments" => ARGV, "workers" => ENV.fetch("CRYSTAL_WORKERS")}))
        File.open("shard.lock", "a") { |file| file.puts "# fixture mutation" } if ENV["FIXTURE_MUTATE_LOCK"] == "1"
        exit ENV.fetch("FIXTURE_INSTALL_EXIT", "0").to_i
      end
    RUBY
    @profile = {
      "schema_version" => 1, "profile" => "portable-fixture-v1", "counter_protocol" => 1,
      "compiler_sha256" => hash(@backend), "wrapper_sha256" => hash(@wrapper),
      "stdlib_sha256" => stdlib_hash, "ruby_sha256" => hash(RbConfig.ruby),
      "minecart_sha256" => hash(@minecart), "minecart_version" => "Minecart fixture-1"
    }
    @environment = {
      "PATH" => @bin + File::PATH_SEPARATOR + ENV.fetch("PATH"),
      "FIXTURE_STDLIB" => @stdlib, "FIXTURE_COMPILER_LOG" => @compiler_log,
      "MEMORY_BUDGET_COMPILER" => @wrapper, "CRYSTAL_CACHE_DIR" => File.join(@temporary, "private cache"),
      "MEMORY_BUDGET_TOOLCHAIN_LOCK" => nil, "MEMORY_BUDGET_STDLIB" => nil,
      "MEMORY_BUDGET_TOOLCHAIN_PROFILE_SHA256" => nil,
      "MEMORY_BUDGET_RUBY_LAUNCHER" => nil, "MEMORY_BUDGET_MINECART" => nil,
      "RUBYOPT" => nil, "FIXTURE_TOOL_VERSION" => nil, "FIXTURE_MUTATE_LOCK" => nil, "FIXTURE_INSTALL_EXIT" => nil
    }
    write_profile("normal", @profile)
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary && File.exist?(@temporary)
  end

  def hash(path)
    Digest::SHA256.file(path).hexdigest
  end

  def stdlib_hash
    Digest::SHA256.hexdigest(Dir.glob(File.join(@stdlib, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.map { |path| "#{hash(path)}  #{path.delete_prefix(@stdlib + "/")}\n" }.join)
  end

  def write_executable(path, content)
    File.write(path, content)
    File.chmod(0o755, path)
  end

  def write_profile(label, profile)
    path = File.join(@package, "toolchain.#{label}.json")
    File.write(path, JSON.pretty_generate(profile) + "\n")
    path
  end

  def bootstrap(*arguments)
    Open3.capture3(@environment, RbConfig.ruby, File.join(@package, "scripts", "budget.rb"), *arguments, chdir: @temporary)
  end

  def relocate_prefix(label)
    old_prefix = @prefix
    @prefix = File.join(@temporary, label)
    FileUtils.mv(old_prefix, @prefix)
    @bin = File.join(@prefix, "bin")
    @stdlib = File.join(@prefix, "share", "crystal", "src")
    @backend = File.join(@prefix, "libexec", "crystal-alpha-bin")
    @wrapper = File.join(@bin, "crystal-alpha")
    @minecart = File.join(@bin, "minecart")
    write_executable(@wrapper, "#!/bin/sh\nexec #{Shellwords.escape(@backend)} \"$@\"\n")
    @environment["PATH"] = @bin + File::PATH_SEPARATOR + ENV.fetch("PATH")
    @environment["FIXTURE_STDLIB"] = @stdlib
    @environment["MEMORY_BUDGET_COMPILER"] = @wrapper
    @profile["wrapper_sha256"] = hash(@wrapper)
    write_profile("normal", @profile)
  end

  def assert_rejected(fragment, *arguments)
    output, errors, status = bootstrap(*arguments)
    refute status.success?, output + errors
    assert_includes errors, fragment
  end

  def test_quoted_prefix_with_spaces_forwards_exact_arguments
    relocate_prefix("ordinary prefix with spaces")
    output, errors, status = bootstrap("build", "input with spaces.cr", "-Dfiber_allocation_tally")
    assert status.success?, errors
    data = JSON.parse(output)
    assert_equal ["build", "input with spaces.cr", "-Dfiber_allocation_tally"], data.fetch("arguments")
    assert_equal "1", data.fetch("workers")
    assert_equal "1", data.fetch("allocation")
    assert File.file?(File.join(@environment.fetch("CRYSTAL_CACHE_DIR"), "budget-stdlib", "fiber", "allocation_tally.cr"))
  end

  def test_full_identity_selects_right_ruby_among_shared_backends
    File.delete(File.join(@package, "toolchain.normal.json"))
    write_profile("a-wrong-ruby", @profile.merge("ruby_sha256" => "0" * 64))
    write_profile("b-right-ruby", @profile)
    output, errors, status = bootstrap("--version")
    assert status.success?, errors
    assert JSON.parse(output).fetch("fixture_compiled")
  end

  def test_full_identity_selects_right_stdlib_among_shared_backends
    File.delete(File.join(@package, "toolchain.normal.json"))
    write_profile("a-wrong-stdlib", @profile.merge("stdlib_sha256" => "0" * 64))
    write_profile("b-right-stdlib", @profile)
    output, errors, status = bootstrap("--version")
    assert status.success?, errors
    assert JSON.parse(output).fetch("fixture_compiled")
  end

  def test_double_quoted_backend_path_with_spaces
    relocate_prefix("quoted prefix with spaces")
    write_executable(@wrapper, "#!/bin/sh\nexec \"#{@backend}\" \"$@\"\n")
    write_profile("normal", @profile.merge("wrapper_sha256" => hash(@wrapper)))
    output, errors, status = bootstrap("--version")
    assert status.success?, errors
    assert JSON.parse(output).fetch("fixture_compiled")
  end

  def test_changed_wrapper_is_rejected_before_backend_execution
    File.open(@wrapper, "a") { |file| file.puts "# changed launcher" }
    assert_rejected("wrapper SHA-256 mismatch", "--version")
    refute File.exist?(@compiler_log)
  end

  def test_script_wrapper_requires_its_own_reviewed_hash
    write_profile("normal", @profile.reject { |key, _| key == "wrapper_sha256" })
    assert_rejected("script wrapper requires wrapper_sha256", "--version")
    refute File.exist?(@compiler_log)
  end

  def test_direct_native_backend_profile_uses_its_backend_hash
    @environment["MEMORY_BUDGET_COMPILER"] = "/bin/echo"
    @environment["MEMORY_BUDGET_STDLIB"] = @stdlib
    profile = @profile.reject { |key, _| key == "wrapper_sha256" }.merge("compiler_sha256" => hash("/bin/echo"))
    write_profile("normal", profile)
    output, errors, status = bootstrap("fixture-native-arguments")
    assert status.success?, errors
    assert_equal "fixture-native-arguments\n", output
  end

  def test_package_versions_and_all_declared_file_pins_match
    manifest = JSON.parse(File.read(File.join(ROOT, "PACKAGE_PINS.json")))
    version = YAML.load_file(File.join(ROOT, "shard.yml")).fetch("version")
    assert_equal version, manifest.fetch("package_version")
    assert_includes File.read(File.join(ROOT, "src", "memory_budget.cr")), "VERSION = #{version.to_json}"
    manifest.fetch("files").each do |entry|
      assert_equal entry.fetch("sha256"), hash(File.join(ROOT, entry.fetch("file"))), entry.fetch("file")
    end
  end

  def test_installed_bundle_retains_working_portable_entrypoints
    destination = File.join(@temporary, "installed bundle consumer")
    output, errors, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "scripts", "install_bundle.rb"), destination)
    assert status.success?, output + errors
    bootstrap_path = File.join(destination, "performance", "vendor", "memory_budget", "scripts", "budget.rb")
    environment = @environment.merge("MEMORY_BUDGET_TOOLCHAIN_LOCK" => File.join(@package, "toolchain.normal.json"))
    result, failures, executed = Open3.capture3(environment, RbConfig.ruby, bootstrap_path, "--version", chdir: destination)
    assert executed.success?, failures
    assert JSON.parse(result).fetch("fixture_compiled")
    installer_path = File.join(File.dirname(bootstrap_path), "install_frozen_dependencies.rb")
    assert File.file?(installer_path)
  end

  def test_missing_profile_rejects_before_backend_execution
    File.delete(File.join(@package, "toolchain.normal.json"))
    assert_rejected("No approved memory-budget toolchain profile", "--version")
    refute File.exist?(@compiler_log)
  end

  def test_changed_backend_is_rejected_before_execution
    File.open(@backend, "a") { |file| file.puts "# changed backend" }
    assert_rejected("Compiler SHA-256 mismatch", "--version")
    refute File.exist?(@compiler_log)
  end

  def test_changed_stdlib_is_rejected
    File.open(File.join(@stdlib, "prelude.cr"), "a") { |file| file.puts "# changed stdlib" }
    assert_rejected("Stdlib SHA-256 mismatch", "--version")
  end

  def test_wrong_ruby_is_rejected_before_backend_execution
    write_profile("normal", @profile.merge("ruby_sha256" => "0" * 64))
    assert_rejected("Ruby SHA-256 mismatch", "--version")
    refute File.exist?(@compiler_log)
  end

  def test_ambiguous_matching_profiles_require_explicit_selection
    write_profile("second", @profile.merge("profile" => "another-label"))
    assert_rejected("Ambiguous approved memory-budget toolchain profiles", "--version")
    @environment["MEMORY_BUDGET_TOOLCHAIN_LOCK"] = File.join(@package, "toolchain.second.json")
    output, errors, status = bootstrap("--version")
    assert status.success?, errors
    assert JSON.parse(output).fetch("fixture_compiled")
  end

  def test_explicit_wrong_profile_cannot_fall_back
    @environment["MEMORY_BUDGET_TOOLCHAIN_LOCK"] = write_profile("wrong", @profile.merge("compiler_sha256" => "0" * 64))
    assert_rejected("Compiler SHA-256 mismatch", "--version")
  end

  def test_missing_ruby_pin_rejects_profile
    profile = @profile.reject { |key, _| key == "ruby_sha256" }
    write_profile("normal", profile)
    assert_rejected("ruby_sha256 must be a SHA-256", "--version")
  end

  def test_path_lookup_and_relocated_prefix
    relocate_prefix("relocated-prefix")
    @environment["MEMORY_BUDGET_COMPILER"] = nil
    output, errors, status = bootstrap("--version")
    assert status.success?, errors
    assert JSON.parse(output).fetch("fixture_compiled")
  end

  def test_declared_ruby_launcher_pin_is_enforced
    write_profile("normal", @profile.merge("ruby_launcher_sha256" => "0" * 64))
    assert_rejected("Ruby launcher SHA-256 mismatch", "--version")
  end

  def test_unavailable_optional_launcher_profile_preserves_another_complete_match
    write_profile("a-unavailable-launcher", @profile.merge("ruby_launcher_sha256" => "0" * 64))
    @environment["MEMORY_BUDGET_RUBY_LAUNCHER"] = File.join(@bin, "missing-ruby")
    output, errors, status = bootstrap("--version")
    assert status.success?, errors
    assert JSON.parse(output).fetch("fixture_compiled")
  end

  def test_explicit_profile_hash_drift_rejects
    @environment["MEMORY_BUDGET_TOOLCHAIN_LOCK"] = File.join(@package, "toolchain.normal.json")
    @environment["MEMORY_BUDGET_TOOLCHAIN_PROFILE_SHA256"] = "0" * 64
    assert_rejected("Toolchain profile SHA-256 mismatch", "--version")
  end

  def test_runtime_overlay_tamper_is_rejected
    File.open(File.join(@package, "runtime_overlay", "fiber.cr"), "a") { |file| file.puts "# fixture mutation" }
    assert_rejected("Runtime overlay SHA-256 mismatch", "--version")
    assert_equal [["env", "CRYSTAL_PATH"]], File.readlines(@compiler_log).map { |line| JSON.parse(line) }
  end

  def test_prepared_stdlib_drift_is_rejected
    _output, errors, status = bootstrap("--version")
    assert status.success?, errors
    File.write(File.join(@environment.fetch("CRYSTAL_CACHE_DIR"), "budget-stdlib", "unexpected.cr"), "# unexpected\n")
    assert_rejected("Prepared stdlib source mismatch", "--version")
  end

  def prepare_dependency_project
    project = File.join(@temporary, "consumer with spaces")
    FileUtils.mkdir_p(project)
    File.write(File.join(project, "shard.yml"), "name: fixture\nversion: 0.1.0\ndependencies:\n  example:\n    github: fixture/example\n    commit: #{'a' * 40}\n")
    File.write(File.join(project, "shard.lock"), "version: 2.0\nshards:\n  example:\n    version: 0.1.0\n    checksum: git-tree:#{'a' * 40}\n")
    bundle = File.join(project, "performance", "vendor", "memory_budget")
    FileUtils.mkdir_p(File.dirname(bundle))
    FileUtils.cp_r(@package, bundle)
    guard = File.join(@temporary, "machine-prefix-guard.rb")
    File.write(guard, <<~RUBY)
      class << File
        alias_method :atlas_fixture_realpath, :realpath
        def realpath(path, *arguments)
          raise "Fixture refused machine-specific Minecart prefix" if path == "/opt/homebrew/bin/minecart"
          atlas_fixture_realpath(path, *arguments)
        end
      end
    RUBY
    [project, guard]
  end

  def dependency_step
    workflow = YAML.load_file(File.join(@package, "templates", "memory-budgets.yml"))
    workflow.fetch("jobs").fetch("memory-budgets").fetch("steps").find { |step| step["name"] == "Install checksum-locked dependencies" }.fetch("run")
  end

  def dependencies(extra = {})
    project, guard = prepare_dependency_project
    yield project if block_given?
    environment = @environment.merge("RUBYOPT" => "-r#{Shellwords.escape(guard)}").merge(extra)
    output, errors, status = Open3.capture3(environment, "/bin/bash", "-c", dependency_step, chdir: project)
    [output, errors, status, project]
  end

  def test_real_dependency_workflow_uses_verified_tool_in_ordinary_prefix
    relocate_prefix("ordinary prefix with spaces")
    output, errors, status, project = dependencies
    assert status.success?, output + errors
    receipt = JSON.parse(File.read(File.join(project, "fixture-install.json")))
    assert_equal ["install", "--frozen", "--skip-ai-docs", "--jobs=1"], receipt.fetch("arguments")
    assert_equal "1", receipt.fetch("workers")
    assert File.file?(File.join(project, "performance", "results", "dependency-toolchain.json"))
  end

  def test_altered_dependency_tool_rejects_before_install
    File.open(@minecart, "a") { |file| file.puts "# altered tool" }
    output, errors, status, project = dependencies
    refute status.success?, output + errors
    assert_includes output + errors, "Minecart SHA-256 mismatch"
    refute File.exist?(File.join(project, "fixture-install.json"))
  end

  def test_missing_dependency_tool_rejects
    output, errors, status, project = dependencies("MEMORY_BUDGET_MINECART" => File.join(@bin, "missing"))
    refute status.success?, output + errors
    assert_includes output + errors, "Minecart executable is unavailable"
    refute File.exist?(File.join(project, "fixture-install.json"))
  end

  def test_dependency_tool_version_mismatch_rejects_before_install
    output, errors, status, project = dependencies("FIXTURE_TOOL_VERSION" => "Minecart unexpected")
    refute status.success?, output + errors
    assert_includes output + errors, "Minecart version mismatch"
    refute File.exist?(File.join(project, "fixture-install.json"))
  end

  def test_default_minecart_identity_admits_the_complete_measured_version
    measured_version = "Minecart 2025.11.25.8 (2026-10-06)"
    default_profile = JSON.parse(File.read(File.join(ROOT, "toolchain.darwin-arm64.json")))
    @profile["minecart_version"] = default_profile.fetch("minecart_version")
    write_profile("normal", @profile)
    output, errors, status, project = dependencies("FIXTURE_TOOL_VERSION" => measured_version)
    assert status.success?, output + errors
    receipt = JSON.parse(File.read(File.join(project, "performance", "results", "dependency-toolchain.json")))
    assert_equal measured_version, receipt.fetch("minecart_version")
    assert File.file?(File.join(project, "fixture-install.json"))
  end

  def test_changed_minecart_build_date_rejects_before_install
    @profile["minecart_version"] = "Minecart 2025.11.25.8 (2026-10-06)"
    write_profile("normal", @profile)
    output, errors, status, project = dependencies("FIXTURE_TOOL_VERSION" => "Minecart 2025.11.25.8 (2026-10-07)")
    refute status.success?, output + errors
    assert_includes output + errors, "Minecart version mismatch"
    refute File.exist?(File.join(project, "fixture-install.json"))
  end

  def test_frozen_install_failure_is_reported
    output, errors, status, project = dependencies("FIXTURE_INSTALL_EXIT" => "7")
    refute status.success?, output + errors
    assert_includes output + errors, "Frozen dependency install failed"
    assert File.file?(File.join(project, "fixture-install.json"))
  end

  def test_frozen_install_pin_drift_is_rejected
    output, errors, status, _project = dependencies("FIXTURE_MUTATE_LOCK" => "1")
    refute status.success?, output + errors
    assert_includes output + errors, "Dependency pins changed"
  end

  def test_missing_checksum_rejects_before_install
    output, errors, status, project = dependencies do |root|
      path = File.join(root, "shard.lock")
      File.write(path, File.read(path).lines.reject { |line| line.include?("checksum:") }.join)
    end
    refute status.success?, output + errors
    assert_includes output + errors, "Every locked dependency requires an immutable checksum"
    refute File.exist?(File.join(project, "fixture-install.json"))
  end

  def test_missing_locked_dependency_rejects_before_install
    output, errors, status, project = dependencies do |root|
      File.write(File.join(root, "shard.lock"), "version: 2.0\nshards: {}\n")
    end
    refute status.success?, output + errors
    assert_includes output + errors, "Dependency lock is missing a required shard"
    refute File.exist?(File.join(project, "fixture-install.json"))
  end
end
