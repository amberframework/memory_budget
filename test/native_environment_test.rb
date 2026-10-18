# frozen_string_literal: true
require_relative "portable_toolchain_test"
require_relative "../scripts/native_environment"

class NativeEnvironmentTest < PortableToolchainTest
  def self.runnable_methods
    instance_methods(false).grep(/^test_/).map(&:to_s)
  end

  def setup
    super
    @native_root = File.join(File.realpath(@temporary), "native prefix with spaces", "lib")
    @pkgconfig_root = File.join(File.realpath(@temporary), "native prefix with spaces", "pkgconfig")
    [@native_root, @pkgconfig_root].each { |path| FileUtils.mkdir_p(path) }
    @library = File.join(@native_root, "libfixture.1.dylib")
    File.write(@library, "reviewed native library fixture\n")
    @alias = File.join(@native_root, "libfixture.dylib")
    File.symlink("libfixture.1.dylib", @alias)
    File.write(File.join(@pkgconfig_root, "fixture.pc"), "Version: fixture-1\n")
    @native_lock = File.join(@temporary, "native.manifest.json")
    @manifest = {
      "schema_version" => 1, "profile" => "native-fixture-1",
      "platform" => MemoryBudget::NativeEnvironment.platform,
      "directories" => [@native_root, @pkgconfig_root].map { |path| MemoryBudget::NativeEnvironment.snapshot_directory(path) },
      "files" => [], "loader_trace" => false,
      "environment" => {
        "CRYSTAL_LIBRARY_PATH" => [@native_root], "DYLD_LIBRARY_PATH" => [@native_root],
        "PKG_CONFIG_LIBDIR" => [@pkgconfig_root], "PKG_CONFIG_PATH" => []
      }
    }
    @native_profile = @profile.merge("schema_version" => 2)
    @environment["MEMORY_BUDGET_NATIVE_COMPONENT_LOCK"] = @native_lock
    @environment["NATIVE_CAPTURE_LOG"] = File.join(@temporary, "native-calls.jsonl")
    @capture_hook = File.join(@temporary, "native_capture.rb")
    File.write(@capture_hook, <<~RUBY)
      require "json"
      if $PROGRAM_NAME.end_with?("/run_specs.rb")
        # Exercise restoration after an actual Ruby exec; loader variables are
        # also independently observed to be stripped by Apple Ruby on the Mini.
        %w[CRYSTAL_LIBRARY_PATH DYLD_LIBRARY_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_PATH].each { |key| ENV.delete(key) }
        if ENV["NATIVE_MUTATE_AT_BOUNDARY"]
          File.open(ENV.fetch("NATIVE_MUTATE_AT_BOUNDARY"), "a") { |file| file.puts "boundary mutation" }
        end
      end
      module Kernel
        alias_method :atlas_native_original_system, :system
        def system(*arguments, **options)
          if arguments.first.is_a?(Hash)
            File.open(ENV.fetch("NATIVE_CAPTURE_LOG"), "a") { |file| file.puts JSON.generate({"kind" => "system", "environment" => arguments.first}) }
          end
          result = atlas_native_original_system(*arguments, **options)
          if ENV["NATIVE_MUTATE_AFTER_CHILD"] && $PROGRAM_NAME.end_with?("/run_specs.rb")
            File.open(ENV.fetch("NATIVE_MUTATE_AFTER_CHILD"), "a") { |file| file.puts "child mutation" }
          end
          result
        end
      end
      class << Process
        alias_method :atlas_native_original_spawn, :spawn
        def spawn(*arguments, **options)
          if arguments.first.is_a?(Hash)
            File.open(ENV.fetch("NATIVE_CAPTURE_LOG"), "a") { |file| file.puts JSON.generate({"kind" => "spawn", "environment" => arguments.first}) }
          end
          atlas_native_original_spawn(*arguments, **options)
        end
      end
    RUBY
    @environment["RUBYOPT"] = "-r#{Shellwords.escape(@capture_hook)}"
    @environment["NATIVE_MUTATE_AT_BOUNDARY"] = nil
    @environment["NATIVE_MUTATE_AFTER_CHILD"] = nil
    write_native_manifest
  end

  def write_native_manifest
    File.write(@native_lock, JSON.pretty_generate(@manifest) + "\n")
    @native_profile["native_component_manifest_sha256"] = hash(@native_lock)
    write_profile("normal", @native_profile)
  end

  def assert_native_environment(environment)
    @manifest.fetch("environment").each { |key, paths| assert_equal paths.join(File::PATH_SEPARATOR), environment.fetch(key) }
    assert_equal @native_lock, environment.fetch("MEMORY_BUDGET_NATIVE_COMPONENT_LOCK")
  end

  def test_schema_two_bootstrap_restores_each_native_value_after_ruby_exec
    output, errors, status = bootstrap("spec", "--", "--no-color")
    assert status.success?, output + errors
    captures = File.readlines(@environment.fetch("NATIVE_CAPTURE_LOG")).map { |line| JSON.parse(line) }
    assert_equal 1, captures.size
    assert_native_environment(captures.first.fetch("environment"))
    assert_nil captures.first.fetch("environment").fetch("DYLD_PRINT_LIBRARIES")
    assert_includes JSON.parse(output).fetch("arguments"), "--threads"
  end

  def test_original_wrapper_admission_survives_internal_backend_transition
    output, errors, status = bootstrap("--version")
    assert status.success?, output + errors
    assert_equal hash(@wrapper), @native_profile.fetch("wrapper_sha256")
    assert_equal [["env", "CRYSTAL_PATH"], ["--version"]], File.readlines(@compiler_log).map { |line| JSON.parse(line) }
  end

  def test_direct_backend_profile_remains_usable
    @environment["MEMORY_BUDGET_COMPILER"] = "/bin/echo"
    @environment["MEMORY_BUDGET_STDLIB"] = @stdlib
    write_profile("normal", @native_profile.reject { |key, _| key == "wrapper_sha256" }.merge("compiler_sha256" => hash("/bin/echo")))
    output, errors, status = bootstrap("native-fixture")
    assert status.success?, output + errors
    assert_equal "native-fixture\n", output
  end

  def test_missing_manifest_lock_refuses_before_compiler
    @environment["MEMORY_BUDGET_NATIVE_COMPONENT_LOCK"] = nil
    assert_rejected("requires MEMORY_BUDGET_NATIVE_COMPONENT_LOCK", "--version")
  end

  def test_schema_one_with_native_field_is_refused
    write_profile("normal", @native_profile.merge("schema_version" => 1))
    assert_rejected("Native components require toolchain profile schema 2", "--version")
  end

  def test_schema_one_with_explicit_native_lock_is_refused
    write_profile("normal", @profile)
    assert_rejected("Native component lock requires toolchain profile schema 2", "--version")
  end

  def test_schema_two_requires_native_hash
    write_profile("normal", @native_profile.reject { |key, _| key == "native_component_manifest_sha256" })
    assert_rejected("native_component_manifest_sha256 must be a SHA-256", "--version")
  end

  def test_manifest_hash_drift_refuses
    File.open(@native_lock, "a") { |file| file.puts " " }
    assert_rejected("Native manifest SHA-256 mismatch", "--version")
  end

  def test_library_byte_change_and_restore
    bytes = File.binread(@library)
    File.write(@library, bytes + "changed")
    assert_rejected("Native directory roster differs", "--version")
    File.binwrite(@library, bytes)
    output, errors, status = bootstrap("--version")
    assert status.success?, output + errors
  end

  def test_file_mode_change_refuses
    File.chmod(0o600, @library)
    assert_rejected("Native directory roster differs", "--version")
  end

  def test_missing_library_refuses
    File.unlink(@library)
    assert_rejected("Native admission failed", "--version")
  end

  def test_unlisted_directory_entry_refuses
    File.write(File.join(@native_root, "unexpected.dylib"), "unexpected")
    assert_rejected("Native directory roster differs", "--version")
  end

  def test_changed_alias_refuses
    File.unlink(@alias)
    File.symlink("./libfixture.1.dylib", @alias)
    assert_rejected("Native directory roster differs", "--version")
  end

  def test_unrostered_external_alias_target_refuses
    external = File.join(File.realpath(@temporary), "unlisted.dylib")
    File.write(external, "outside closure")
    File.unlink(@alias)
    File.symlink(external, @alias)
    @manifest["directories"][0] = MemoryBudget::NativeEnvironment.snapshot_directory(@native_root)
    write_native_manifest
    assert_rejected("symlink target must have its own admitted physical entry", "--version")
  end

  def test_ambiguous_library_basename_refuses
    other = File.join(File.realpath(@temporary), "other lib")
    FileUtils.mkdir_p(other)
    File.write(File.join(other, "libfixture.1.dylib"), "different provider")
    @manifest["directories"] << MemoryBudget::NativeEnvironment.snapshot_directory(other)
    @manifest["environment"]["DYLD_LIBRARY_PATH"] << other
    write_native_manifest
    assert_rejected("Ambiguous native search alias", "--version")
  end

  def test_unknown_environment_root_refuses
    @manifest["environment"]["DYLD_LIBRARY_PATH"] = ["/unknown/lib"]
    write_native_manifest
    assert_rejected("unique admitted physical directories", "--version")
  end

  def test_wrong_platform_refuses
    @manifest["platform"]["machine"] = "different-machine"
    write_native_manifest
    assert_rejected("Native platform identity differs", "--version")
  end

  def test_boundary_native_mutation_is_caught_before_compiler_operation
    @environment["NATIVE_MUTATE_AT_BOUNDARY"] = @library
    assert_rejected("Native directory roster differs", "--version")
    assert_equal [["env", "CRYSTAL_PATH"]], File.readlines(@compiler_log).map { |line| JSON.parse(line) }
  end

  def test_profile_mutation_at_ruby_boundary_is_caught
    @environment["NATIVE_MUTATE_AT_BOUNDARY"] = File.join(@package, "toolchain.normal.json")
    assert_rejected("Selected toolchain profile SHA-256 mismatch", "--version")
  end

  def test_profile_byte_drift_during_stdlib_discovery_is_caught
    source = File.read(@backend).sub('puts ENV.fetch("FIXTURE_STDLIB")', 'File.open(ENV.fetch("FIXTURE_PROFILE_TO_MUTATE"), "a") { |file| file.puts " " }; puts ENV.fetch("FIXTURE_STDLIB")')
    write_executable(@backend, source)
    @native_profile["compiler_sha256"] = hash(@backend)
    write_native_manifest
    @environment["FIXTURE_PROFILE_TO_MUTATE"] = File.join(@package, "toolchain.normal.json")
    assert_rejected("Selected toolchain profile SHA-256 mismatch", "--version")
    assert_equal [["env", "CRYSTAL_PATH"]], File.readlines(@compiler_log).map { |line| JSON.parse(line) }
  end

  def test_wrapper_mutation_at_ruby_boundary_is_caught
    @environment["NATIVE_MUTATE_AT_BOUNDARY"] = @wrapper
    assert_rejected("Selected wrapper SHA-256 mismatch", "--version")
  end

  def test_native_mutation_after_compiler_operation_is_caught
    @environment["NATIVE_MUTATE_AFTER_CHILD"] = @library
    assert_rejected("Native directory roster differs", "--version")
    assert_equal ["--version"], JSON.parse(File.readlines(@compiler_log).last)
  end

  def test_loader_trace_is_reviewed_manifest_state
    @manifest["loader_trace"] = true
    write_native_manifest
    output, errors, status = bootstrap("--version")
    assert status.success?, output + errors
    capture = JSON.parse(File.readlines(@environment.fetch("NATIVE_CAPTURE_LOG")).last)
    assert_equal "1", capture.fetch("environment").fetch("DYLD_PRINT_LIBRARIES")
  end

  def test_installed_bundle_preserves_native_entrypoint
    destination = File.join(@temporary, "native installed consumer")
    output, errors, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "scripts/install_bundle.rb"), destination)
    assert status.success?, output + errors
    environment = @environment.merge("MEMORY_BUDGET_TOOLCHAIN_LOCK" => File.join(@package, "toolchain.normal.json"))
    bootstrap = File.join(destination, "performance/vendor/memory_budget/scripts/budget.rb")
    output, errors, status = Open3.capture3(environment, RbConfig.ruby, bootstrap, "--version", chdir: destination)
    assert status.success?, output + errors
    assert_native_environment(JSON.parse(File.readlines(@environment.fetch("NATIVE_CAPTURE_LOG")).last).fetch("environment"))
  end

  def test_relocated_native_prefix_requires_a_new_reviewed_manifest
    previous = @native_root
    parent = File.join(File.realpath(@temporary), "relocated ordinary native prefix")
    FileUtils.mkdir_p(parent)
    @native_root = File.join(parent, "lib")
    FileUtils.mv(previous, @native_root)
    assert_rejected("Native roster root must be a physical versioned directory", "--version")
    @manifest["directories"][0] = MemoryBudget::NativeEnvironment.snapshot_directory(@native_root)
    @manifest["environment"].each_value { |paths| paths.map! { |path| path == previous ? @native_root : path } }
    write_native_manifest
    output, errors, status = bootstrap("--version")
    assert status.success?, output + errors
    assert_native_environment(JSON.parse(File.readlines(@environment.fetch("NATIVE_CAPTURE_LOG")).last).fetch("environment"))
  end

  def test_manifest_generator_covers_nested_pkgconfig_and_required_header
    nested = File.join(@native_root, "pkgconfig")
    FileUtils.mkdir_p(nested)
    File.write(File.join(nested, "nested.pc"), "Version: fixture-1\n")
    header = File.join(File.realpath(@temporary), "fixture.h")
    File.write(header, "/* native header fixture */\n")
    config = {"profile" => "generated-native", "environment" => @manifest.fetch("environment").merge("PKG_CONFIG_PATH" => [nested]), "files" => [header], "loader_trace" => false}
    config_path = File.join(@temporary, "native-roots.json")
    File.write(config_path, JSON.generate(config))
    output, errors, status = Open3.capture3(RbConfig.ruby, File.join(@package, "scripts/prepare_native_manifest.rb"), config_path)
    assert status.success?, output + errors
    @manifest = JSON.parse(output)
    assert_equal 2, @manifest.fetch("directories").size
    assert_equal hash(header), @manifest.fetch("files").first.fetch("sha256")
    write_native_manifest
    output, errors, status = bootstrap("--version")
    assert status.success?, output + errors
    assert_native_environment(JSON.parse(File.readlines(@environment.fetch("NATIVE_CAPTURE_LOG")).last).fetch("environment"))
    File.open(header, "a") { |file| file.puts "/* changed header */" }
    assert_rejected("Native required file identity differs", "--version")
  end

  def test_app_template_passes_admitted_native_environment_to_every_child_kind
    # Executable fixture programs exercise the real app runner's process and
    # identity boundaries. Actual Crystal/native behavior has separate receipts.
    verdict = {"scenario_name" => "fixture", "verdict_status" => "passed", "list_of_violations" => [], "list_of_capabilities" => ["fixture"], "list_of_measurements" => []}
    spec_program = "#!#{RbConfig.ruby}\nif ENV['MEMORY_BUDGET_INJECT_REGRESSION'] == '1'\n warn 'fixture exceeded'\n exit 1\nend\nputs #{("MEMORY_BUDGET_OBSERVATION_JSON=" + JSON.generate(verdict)).inspect}\nputs '1 examples, 0 failures, 0 errors, 0 pending'\n"
    checker_program = "#!#{RbConfig.ruby}\nrequire 'json'\nFile.write(ARGV.fetch(3), #{JSON.generate({"list_of_errors" => [], "list_of_verdicts" => [verdict]}).inspect})\n"
    write_executable(@backend, <<~RUBY)
      #!#{RbConfig.ruby}
      if ARGV == ["env", "CRYSTAL_PATH"]
        puts ENV.fetch("FIXTURE_STDLIB")
      else
        destination = ARGV.fetch(ARGV.index("-o") + 1)
        content = ARGV.fetch(1).end_with?("/src/cli.cr") ? #{checker_program.inspect} : #{spec_program.inspect}
        File.write(destination, content)
        File.chmod(0o755, destination)
      end
    RUBY
    @native_profile["compiler_sha256"] = hash(@backend)
    write_native_manifest
    write_executable(File.join(@bin, "git"), "#!/bin/sh\nprintf '%s\\n' '#{'a' * 40}'\n")
    project = File.join(@temporary, "ordinary native app fixture")
    _output, errors, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "scripts/install_bundle.rb"), project)
    assert status.success?, errors
    runner = File.join(project, "performance/run_memory_budgets.rb")
    FileUtils.cp(File.join(ROOT, "templates/run_memory_budgets.rb"), runner)
    File.write(File.join(project, "performance/memory_budget.json"), JSON.generate({"list_of_required_scenarios" => ["fixture"], "list_of_policies" => [{"scenario_name" => "fixture"}]}))
    environment = @environment.merge("MEMORY_BUDGET_TOOLCHAIN_LOCK" => File.join(@package, "toolchain.normal.json"))
    output, errors, status = Open3.capture3(environment, RbConfig.ruby, runner, "--self-test", chdir: project)
    assert status.success?, output + errors
    captures = File.readlines(@environment.fetch("NATIVE_CAPTURE_LOG")).map { |line| JSON.parse(line) }
    assert_equal 5, captures.count { |row| row.fetch("kind") == "spawn" }
    assert_equal 2, captures.count { |row| row.fetch("kind") == "system" }
    captures.each { |row| assert_native_environment(row.fetch("environment")) }
    report = JSON.parse(File.read(File.join(project, "performance/results/memory-budget-report.json")))
    assert_equal true, report.fetch("passed")
    assert_equal @native_profile.fetch("native_component_manifest_sha256"), report.fetch("native_component_manifest_sha256")
  end
end
