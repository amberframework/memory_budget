# frozen_string_literal: true
require_relative "portable_toolchain_test"
require_relative "../scripts/prepare_toolchain_profile"

class ToolchainCandidateTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @fixture = PortableToolchainTest.new("toolchain_candidate_fixture")
    @fixture.setup
    @fixture.prepare_dependency_git_profile
    @environment = @fixture.instance_variable_get(:@environment)
    @root = File.realpath(@fixture.instance_variable_get(:@temporary))
    @backend = @fixture.instance_variable_get(:@backend)
    @wrapper = @fixture.instance_variable_get(:@wrapper)
    @stdlib = @fixture.instance_variable_get(:@stdlib)
    @minecart = @fixture.instance_variable_get(:@minecart)
    @log = @fixture.instance_variable_get(:@compiler_log)
    @commit = "c" * 40
    @version = "Crystal 1.21.0 [#{@commit}]\nLLVM: fixture"
    @fixture.write_executable(@backend, <<~RUBY_FIXTURE)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("FIXTURE_COMPILER_LOG"), "a") { |file| file.puts(JSON.generate(ARGV)) }
      if ARGV == ["--version"]
        puts ENV.fetch("FIXTURE_COMPILER_VERSION", #{@version.inspect})
        File.write(ENV.fetch("FIXTURE_METADATA_MUTATE"), "changed bytes") if ENV["FIXTURE_METADATA_MUTATE"]
      elsif ARGV == ["env", "CRYSTAL_PATH"]
        puts ENV.fetch("FIXTURE_STDLIB")
      else
        abort "Unexpected compiler fixture command"
      end
    RUBY_FIXTURE
    @provenance = File.join(@root, "installation-receipt.json")
    File.write(@provenance, JSON.generate({"provider" => "Executable fixture", "source_commit" => @commit}))
    pin = ->(path) { {"path" => path, "sha256" => Digest::SHA256.file(path).hexdigest} }
    @config = {"schema_version" => 1, "profile" => "new-installed-toolchain-fixture",
      "compiler" => {"entrypoint" => pin.call(@wrapper), "backend" => pin.call(@backend),
        "stdlib_root" => @stdlib, "stdlib_sha256" => @fixture.stdlib_hash, "source_commit" => @commit, "version" => @version},
      "ruby" => {"backend" => pin.call(RbConfig.ruby), "launcher" => pin.call(RbConfig.ruby), "version" => RUBY_DESCRIPTION},
      "minecart" => {"executable" => pin.call(@minecart), "version" => "Minecart fixture-1"},
      "native_manifest" => pin.call(@environment.fetch("MEMORY_BUDGET_NATIVE_COMPONENT_LOCK")),
      "git_manifest" => pin.call(@environment.fetch("MEMORY_BUDGET_GIT_PROVIDER_LOCK")), "provenance" => [pin.call(@provenance)]}
    @config_path = File.join(@root, "prepare.json")
    @destination = File.join(@root, "new candidate with spaces")
    write_config
  end

  def teardown
    @fixture.teardown
  end

  def write_config
    File.write(@config_path, JSON.pretty_generate(@config) + "\n")
  end

  def prepare(destination = @destination)
    Open3.capture3(@environment, RbConfig.ruby, File.join(ROOT, "scripts", "prepare_toolchain_profile.rb"), @config_path, destination)
  end

  def assert_prepared(destination = @destination)
    output, errors, status = prepare(destination)
    assert status.success?, output + errors
    draft = JSON.parse(File.read(File.join(destination, "DRAFT_PROFILE.json")))
    assert_equal "UNADMITTED", draft.fetch("status")
    assert_equal 4, draft.fetch("metadata").size
    draft
  end

  def test_preserves_exact_inputs_and_requires_review_before_bootstrap
    draft = assert_prepared
    assert_equal File.binread(@config_path), File.binread(File.join(@destination, "INPUT_CONFIGURATION.json"))
    draft.fetch("retained_inputs").each do |row|
      assert_equal row.fetch("sha256"), Digest::SHA256.file(File.join(@destination, row.fetch("file"))).hexdigest
    end
    assert_equal Digest::SHA256.file(@backend).hexdigest, draft.fetch("proposed_profile").fetch("compiler_sha256")
    calls = File.binread(@log)
    environment = @environment.merge("MEMORY_BUDGET_TOOLCHAIN_LOCK" => File.join(@destination, "DRAFT_PROFILE.json"))
    output, errors, status = Open3.capture3(environment, RbConfig.ruby, File.join(ROOT, "scripts", "budget.rb"), "--version")
    refute status.success?, output + errors
    assert_includes errors, "Invalid toolchain profile"
    assert_equal calls, File.binread(@log)
    reviewed_path = File.join(@root, "reviewed-profile.json")
    File.write(reviewed_path, JSON.pretty_generate(draft.fetch("proposed_profile")) + "\n")
    environment.merge!("MEMORY_BUDGET_TOOLCHAIN_LOCK" => reviewed_path,
      "MEMORY_BUDGET_TOOLCHAIN_PROFILE_SHA256" => Digest::SHA256.file(reviewed_path).hexdigest,
      "MEMORY_BUDGET_RUBY_LAUNCHER" => RbConfig.ruby)
    output, errors, status = Open3.capture3(environment, RbConfig.ruby, File.join(ROOT, "scripts", "toolchain_profile.rb"), "--json")
    assert status.success?, errors
    assert_equal Digest::SHA256.file(reviewed_path).hexdigest, JSON.parse(output).fetch("profile_sha256")
  end

  def test_inspection_reads_bytes_without_executing_observed_tools
    paths = {"profile" => @config.fetch("profile"), "compiler_entrypoint" => @wrapper, "stdlib_root" => @stdlib,
      "ruby_launcher" => RbConfig.ruby, "minecart_path" => @minecart, "compiler_source_commit" => @commit,
      "compiler_version" => @version, "minecart_version" => "Minecart fixture-1",
      "native_manifest" => @environment.fetch("MEMORY_BUDGET_NATIVE_COMPONENT_LOCK"),
      "git_manifest" => @environment.fetch("MEMORY_BUDGET_GIT_PROVIDER_LOCK"), "provenance_files" => [@provenance]}
    path = File.join(@root, "paths.json")
    File.write(path, JSON.pretty_generate(paths) + "\n")
    output, errors, status = Open3.capture3(@environment, RbConfig.ruby,
      File.join(ROOT, "scripts", "prepare_toolchain_profile.rb"), "--inspect", path)
    assert status.success?, errors
    observed = JSON.parse(output)
    assert_equal "UNREVIEWED_INPUTS", observed.fetch("status")
    assert_equal 0, observed.fetch("commands_executed")
    refute File.exist?(@log)
    @config = observed.fetch("proposed_configuration")
    assert_equal [File.realpath(path), @provenance], @config.fetch("provenance").map { |row| row.fetch("path") }
    write_config
    assert_prepared
  end

  def test_wrong_backend_pin_refuses_before_metadata_and_restores
    original = @config.fetch("compiler").fetch("backend").fetch("sha256")
    @config.fetch("compiler").fetch("backend")["sha256"] = "0" * 64
    write_config
    output, errors, status = prepare
    refute status.success?, output + errors
    assert_includes errors, "Compiler backend SHA-256 mismatch"
    refute File.exist?(@log)
    refute File.exist?(@destination)
    @config.fetch("compiler").fetch("backend")["sha256"] = original
    write_config
    assert_prepared
  end

  def test_stdlib_and_provenance_mutations_refuse_before_metadata_then_restore
    [File.join(@stdlib, "prelude.cr"), @provenance].each do |path|
      bytes = File.binread(path)
      File.write(path, "changed bytes")
      output, errors, status = prepare
      refute status.success?, output + errors
      assert_includes errors, "SHA-256 mismatch"
      refute File.exist?(@log)
      File.binwrite(path, bytes)
    end
    assert_prepared
  end

  def test_declared_ruby_must_match_the_actual_interpreter_then_restore
    @config.fetch("ruby")["version"] = "a different Ruby"
    write_config
    output, errors, status = prepare
    refute status.success?, output + errors
    assert_includes errors, "declared Ruby backend/version"
    refute File.exist?(@log)
    @config.fetch("ruby")["version"] = RUBY_DESCRIPTION
    write_config
    assert_prepared
  end

  def test_changed_provenance_after_real_metadata_refuses_and_preserves_failure
    bytes = File.binread(@provenance)
    @environment["FIXTURE_METADATA_MUTATE"] = @provenance
    output, errors, status = prepare
    refute status.success?, output + errors
    assert_includes errors, "Provenance receipt SHA-256 mismatch"
    assert File.file?(File.join(@destination, "compiler-version.stdout"))
    refute File.exist?(File.join(@destination, "DRAFT_PROFILE.json"))
    assert_equal false, JSON.parse(File.read(File.join(@destination, "PREPARATION_FAILURE.json"))).fetch("admitted")
    @environment["FIXTURE_METADATA_MUTATE"] = nil
    File.binwrite(@provenance, bytes)
    assert_prepared(File.join(@root, "restored candidate"))
  end

  def test_wrong_full_version_refuses_and_restores
    @environment["FIXTURE_COMPILER_VERSION"] = "Crystal 1.21.0 [#{@commit}]\nLLVM: different"
    output, errors, status = prepare
    refute status.success?, output + errors
    assert_includes errors, "Metadata version differs: compiler-version"
    refute File.exist?(File.join(@destination, "DRAFT_PROFILE.json"))
    @environment["FIXTURE_COMPILER_VERSION"] = nil
    assert_prepared(File.join(@root, "restored candidate"))
  end

  def test_existing_destination_is_preserved
    Dir.mkdir(@destination)
    marker = File.join(@destination, "INPUT_CONFIGURATION.json")
    File.write(marker, "existing owner data")
    output, errors, status = prepare
    refute status.success?, output + errors
    assert_includes errors, "destination must be new"
    assert_equal "existing owner data", File.read(marker)
    assert_equal ["INPUT_CONFIGURATION.json"], Dir.children(@destination)
  end

  def test_wrapper_and_native_manifest_changes_refuse_before_metadata_then_restore
    [@wrapper, @environment.fetch("MEMORY_BUDGET_NATIVE_COMPONENT_LOCK"), @environment.fetch("MEMORY_BUDGET_GIT_PROVIDER_LOCK")].each do |path|
      bytes = File.binread(path)
      File.write(path, "changed bytes")
      output, errors, status = prepare
      refute status.success?, output + errors
      assert_includes errors, "SHA-256 mismatch"
      refute File.exist?(@log)
      File.binwrite(path, bytes)
    end
    assert_prepared
  end

  def test_installed_bundle_prepares_the_same_unadmitted_profile
    consumer = File.join(@root, "consumer")
    output, errors, status = Open3.capture3(@environment, RbConfig.ruby, File.join(ROOT, "scripts", "install_bundle.rb"), consumer)
    assert status.success?, output + errors
    helper = File.join(consumer, "performance", "vendor", "memory_budget", "scripts", "prepare_toolchain_profile.rb")
    assert File.file?(helper), "The canonical package roster must include the candidate helper"
    output, errors, status = Open3.capture3(@environment, RbConfig.ruby, helper, @config_path, @destination)
    assert status.success?, output + errors
    assert_equal "UNADMITTED", JSON.parse(File.read(File.join(@destination, "DRAFT_PROFILE.json"))).fetch("status")
  end

  def test_metadata_deadline_and_output_cap_are_actual_guards
    Dir.mkdir(@destination)
    helper = MemoryBudget::ToolchainCandidate
    error = assert_raises(helper::PreparationError) do
      helper.metadata({}, [RbConfig.ruby, "-e", "sleep 30"], @destination, "sleep-control", seconds: 0.1)
    end
    assert_includes error.message, "Metadata deadline exceeded"
    error = assert_raises(helper::PreparationError) do
      helper.metadata({}, [RbConfig.ruby, "-e", "STDOUT.write('x' * 1048577)"], @destination, "output-control")
    end
    assert_includes error.message, "Metadata output cap exceeded"
    result = helper.metadata({}, [RbConfig.ruby, "-e", "puts 'restored metadata'"], @destination, "restored-control")
    assert_equal "restored metadata", result.fetch("output")
    assert_equal true, result.fetch("terminal_ownership").fetch("direct_child_reaped")
    assert_equal true, result.fetch("terminal_ownership").fetch("owned_group_absent")
  end

  def test_successful_direct_exit_with_an_owned_descendant_refuses_and_cleans_up
    Dir.mkdir(@destination)
    helper = MemoryBudget::ToolchainCandidate
    code = "child=Process.spawn(RbConfig.ruby,'-e','sleep 30'); puts JSON.generate({root:Process.pid,child:child})"
    error = assert_raises(helper::PreparationError) do
      helper.metadata({}, [RbConfig.ruby, "-rjson", "-rrbconfig", "-e", code], @destination, "orphan-control")
    end
    assert_includes error.message, "left an owned process group alive"
    root_pid = JSON.parse(File.read(File.join(@destination, "orphan-control.stdout"))).fetch("root")
    assert_raises(Errno::ESRCH) { Process.kill(0, -root_pid) }
    result = helper.metadata({}, [RbConfig.ruby, "-e", "puts 'restored'"], @destination, "orphan-restored")
    assert_equal true, result.fetch("terminal_ownership").fetch("owned_group_absent")
  end
end
