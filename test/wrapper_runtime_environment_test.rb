# frozen_string_literal: true
require_relative "portable_toolchain_test"
require_relative "../scripts/toolchain_profile"

class WrapperRuntimeEnvironmentTest < PortableToolchainTest
  def self.runnable_methods
    instance_methods(false).grep(/^test_/).map(&:to_s)
  end

  def setup
    super
    @environment["LD_RUN_PATH"] = nil
    @environment["MEMORY_BUDGET_NATIVE_COMPONENT_LOCK"] = nil
    write_executable(@backend, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("FIXTURE_COMPILER_LOG"), "a") { |file| file.puts JSON.generate(ARGV) }
      if ARGV == ["env", "CRYSTAL_PATH"]
        puts ENV.fetch("FIXTURE_STDLIB")
      else
        puts JSON.generate({"arguments" => ARGV, "ld_run_path" => ENV["LD_RUN_PATH"],
          "stdlib" => ENV.fetch("CRYSTAL_PATH"), "workers" => ENV.fetch("CRYSTAL_WORKERS"),
          "allocation" => ENV.fetch("MEMORY_BUDGET_REQUIRE_ALLOCATION")})
      end
    RUBY
    @profile["compiler_sha256"] = hash(@backend)
    write_profile("normal", @profile)
  end

  def base_paths
    [File.join(@prefix, "lib"), File.join(@prefix, "opt", "openssl@4", "lib")].join(File::PATH_SEPARATOR)
  end

  def runtime_wrapper(value, extra = "")
    write_executable(@wrapper, "#!/bin/bash\nCRYSTAL_PATH=\"lib:#{@stdlib}\" LD_RUN_PATH=\"#{value}\" #{extra}exec \"#{@backend}\"  \"$@\"\n")
    @profile["wrapper_sha256"] = hash(@wrapper)
    write_profile("normal", @profile)
  end

  def restored(environment = {})
    MemoryBudget::ToolchainProfile.wrapper_runtime_environment(File.realpath(@wrapper), File.realpath(@backend), @profile, environment)
  end

  def with_fixture_environment
    previous = ENV.to_h
    @environment.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    ENV.replace(previous)
  end

  def test_actual_homebrew_ambient_prefix_form_reaches_backend_and_keeps_overlay
    relocate_prefix("ordinary prefix with spaces")
    runtime_wrapper('${LD_RUN_PATH:+${LD_RUN_PATH}:}' + base_paths)
    @environment["LD_RUN_PATH"] = "/ambient with spaces/lib"
    output, errors, status = bootstrap("spec", "--", "--no-color")
    assert status.success?, output + errors
    data = JSON.parse(output)
    assert_equal "/ambient with spaces/lib:" + base_paths, data.fetch("ld_run_path")
    assert_equal "lib:" + File.join(@environment.fetch("CRYSTAL_CACHE_DIR"), "budget-stdlib"), data.fetch("stdlib")
    assert_equal "1", data.fetch("allocation")
    assert File.file?(File.join(@environment.fetch("CRYSTAL_CACHE_DIR"), "budget-stdlib", "fiber", "allocation_tally.cr"))
    assert_equal ["spec", "--threads", "1", "--", "--no-color"], data.fetch("arguments")
  end

  def test_optional_exact_ambient_append_suffix_preserves_order
    runtime_wrapper(base_paths + '${LD_RUN_PATH:+:$LD_RUN_PATH}')
    @environment["LD_RUN_PATH"] = "/ambient/lib"
    output, errors, status = bootstrap("build", "fixture with spaces.cr")
    assert status.success?, output + errors
    assert_equal base_paths + ":/ambient/lib", JSON.parse(output).fetch("ld_run_path")
  end

  def test_literal_only_and_empty_ambient_restore_the_static_roster
    runtime_wrapper(base_paths)
    assert_equal({"LD_RUN_PATH" => base_paths}, restored("LD_RUN_PATH" => "/ambient/lib"))
    runtime_wrapper('${LD_RUN_PATH:+${LD_RUN_PATH}:}' + base_paths)
    [nil, ""].each { |value| assert_equal({"LD_RUN_PATH" => base_paths}, restored("LD_RUN_PATH" => value)) }
  end

  def test_each_supported_order_is_idempotent_across_repeated_restoration
    ['${LD_RUN_PATH:+${LD_RUN_PATH}:}' + base_paths, base_paths + '${LD_RUN_PATH:+:$LD_RUN_PATH}', base_paths].each do |value|
      runtime_wrapper(value)
      first = restored("LD_RUN_PATH" => "/ambient/lib")
      assert_equal first, restored(first)
      assert_equal first, restored(restored(first))
    end
  end

  def test_identity_environment_revalidates_and_restores_only_runtime_link_search
    runtime_wrapper('${LD_RUN_PATH:+${LD_RUN_PATH}:}' + base_paths)
    @environment["LD_RUN_PATH"] = "/ambient/lib"
    with_fixture_environment do
      identity = MemoryBudget::ToolchainProfile.resolve(@package)
      first = identity.environment
      refute first.key?("CRYSTAL_PATH")
      assert_equal "/ambient/lib:" + base_paths, first.fetch("LD_RUN_PATH")
      ENV.update(first)
      assert_equal first, identity.environment
    end
  end

  def test_revalidate_selection_restores_missing_runtime_link_search
    runtime_wrapper('${LD_RUN_PATH:+${LD_RUN_PATH}:}' + base_paths)
    with_fixture_environment do
      identity = MemoryBudget::ToolchainProfile.resolve(@package)
      ENV.update(identity.environment)
      ENV["MEMORY_BUDGET_COMPILER"] = identity.compiler_path
      ENV["MEMORY_BUDGET_COMPILER_SHA256"] = @profile.fetch("compiler_sha256")
      ENV["MEMORY_BUDGET_STDLIB_SHA256"] = @profile.fetch("stdlib_sha256")
      ENV.delete("LD_RUN_PATH")
      result = MemoryBudget::ToolchainProfile.revalidate_selection
      assert_equal({"LD_RUN_PATH" => base_paths}, result)
      refute result.key?("CRYSTAL_PATH")
      ENV.update(result)
      assert_equal result, MemoryBudget::ToolchainProfile.revalidate_selection
    end
  end

  def test_changed_wrapper_is_rejected_before_runtime_source_is_parsed
    runtime_wrapper(base_paths)
    @profile["wrapper_sha256"] = "0" * 64
    error = assert_raises(MemoryBudget::ToolchainProfile::AdmissionError) { restored }
    assert_includes error.message, "wrapper SHA-256 mismatch"
  end

  def test_changed_backend_is_rejected_before_runtime_source_is_parsed
    runtime_wrapper(base_paths)
    @profile["compiler_sha256"] = "0" * 64
    error = assert_raises(MemoryBudget::ToolchainProfile::AdmissionError) { restored }
    assert_includes error.message, "Compiler SHA-256 mismatch"
  end

  def test_changed_runtime_wrapper_is_rejected_at_the_ruby_boundary
    runtime_wrapper('${LD_RUN_PATH:+${LD_RUN_PATH}:}' + base_paths)
    hook = File.join(@temporary, "changed-runtime-wrapper.rb")
    File.write(hook, <<~RUBY)
      if $PROGRAM_NAME.end_with?("/run_specs.rb")
        File.open(ENV.fetch("MEMORY_BUDGET_COMPILER_ENTRYPOINT"), "a") { |file| file.puts "# changed runtime wrapper" }
      end
    RUBY
    @environment["RUBYOPT"] = "-r#{Shellwords.escape(hook)}"
    assert_rejected("Selected wrapper SHA-256 mismatch", "spec")
    assert_equal [["env", "CRYSTAL_PATH"]], File.readlines(@compiler_log).map { |line| JSON.parse(line) }
  end

  def test_dynamic_or_malformed_matching_assignments_are_explicitly_rejected
    ['$HOME/lib', '$(printf /dynamic/lib)', '`printf /dynamic/lib`', '/literal/lib:$OTHER',
     '/literal/lib:', 'relative/lib', '/literal/../different/lib',
     '${LD_RUN_PATH:+${LD_RUN_PATH}:}/literal/lib${LD_RUN_PATH:+:$LD_RUN_PATH}'].each do |value|
      runtime_wrapper(value)
      error = assert_raises(MemoryBudget::ToolchainProfile::AdmissionError) { restored }
      assert_includes error.message, "Unsupported wrapper LD_RUN_PATH assignment", value
    end
  end

  def test_duplicate_assignments_are_explicitly_rejected
    runtime_wrapper(base_paths, 'LD_RUN_PATH="/duplicate/lib" ')
    error = assert_raises(MemoryBudget::ToolchainProfile::AdmissionError) { restored }
    assert_includes error.message, "one literal assignment"
  end

  def test_explicit_export_assignment_reaches_the_admitted_backend
    write_executable(@wrapper, "#!/bin/sh\nexport LD_RUN_PATH=\"#{base_paths}\"\nexec \"#{@backend}\" \"$@\"\n")
    @profile["wrapper_sha256"] = hash(@wrapper)
    write_profile("normal", @profile)
    output, errors, status = bootstrap("spec")
    assert status.success?, output + errors
    assert_equal base_paths, JSON.parse(output).fetch("ld_run_path")
  end

  def test_echo_and_printf_arguments_are_rejected_in_the_full_bootstrap
    ["echo LD_RUN_PATH=\"#{base_paths}\"", "printf '%s' LD_RUN_PATH=\"#{base_paths}\""].each do |statement|
      write_executable(@wrapper, "#!/bin/sh\n#{statement}\nexec \"#{@backend}\" \"$@\"\n")
      @profile["wrapper_sha256"] = hash(@wrapper)
      write_profile("normal", @profile)
      File.delete(@compiler_log) if File.exist?(@compiler_log)
      assert_rejected("leading exec environment or an explicit export", "spec")
      assert_equal [["env", "CRYSTAL_PATH"]], File.readlines(@compiler_log).map { |line| JSON.parse(line) }
    end
  end

  def test_export_after_the_static_exec_is_rejected
    write_executable(@wrapper, "#!/bin/sh\nexec \"#{@backend}\" \"$@\"\nexport LD_RUN_PATH=\"#{base_paths}\"\n")
    @profile["wrapper_sha256"] = hash(@wrapper)
    write_profile("normal", @profile)
    assert_rejected("leading exec environment or an explicit export", "spec")
  end

  def test_unquoted_and_spaced_assignment_forms_are_explicitly_rejected
    ['LD_RUN_PATH=/literal/lib', 'LD_RUN_PATH ="/literal/lib"', "LD_RUN_PATH='/literal/lib'"].each do |assignment|
      write_executable(@wrapper, "#!/bin/sh\n#{assignment} exec \"#{@backend}\" \"$@\"\n")
      @profile["wrapper_sha256"] = hash(@wrapper)
      error = assert_raises(MemoryBudget::ToolchainProfile::AdmissionError) { restored }
      assert_includes error.message, "Unsupported wrapper LD_RUN_PATH assignment"
    end
  end

  def test_existing_wrapper_without_runtime_assignment_preserves_ambient_behavior
    assert_equal({}, restored("LD_RUN_PATH" => "/ambient/lib"))
    @environment["LD_RUN_PATH"] = "/ambient/lib"
    output, errors, status = bootstrap("--version")
    assert status.success?, output + errors
    assert_equal "/ambient/lib", JSON.parse(output).fetch("ld_run_path")
  end

  def test_direct_backend_keeps_its_existing_environment_boundary
    assert_equal({}, MemoryBudget::ToolchainProfile.wrapper_runtime_environment(File.realpath(@backend), File.realpath(@backend), @profile, "LD_RUN_PATH" => "/ambient/lib"))
  end

  def native_overlay_profile(toolchain_schema)
    directory = File.join(File.realpath(@temporary), "native library fixture")
    FileUtils.mkdir_p(directory)
    family = MemoryBudget::NativeEnvironment::LOADER_FAMILIES.fetch(MemoryBudget::NativeEnvironment.platform.fetch("sysname"))
    variables = MemoryBudget::NativeEnvironment.environment_variables(2, family)
    manifest = {"schema_version" => 2, "loader_family" => family, "profile" => "authoritative-runtime-fixture",
      "platform" => MemoryBudget::NativeEnvironment.platform,
      "directories" => [MemoryBudget::NativeEnvironment.snapshot_directory(directory)], "files" => [],
      "environment" => variables.each_with_object({}) { |key, values| values[key] = [directory] }, "loader_trace" => false}
    lock = File.join(@temporary, "native-runtime.json")
    File.write(lock, JSON.pretty_generate(manifest) + "\n")
    @environment["MEMORY_BUDGET_NATIVE_COMPONENT_LOCK"] = lock
    write_profile("normal", @profile.merge("schema_version" => 2, "native_component_manifest_sha256" => hash(lock)))
    prepare_dependency_git_profile if toolchain_schema == 3
  end

  def assert_native_overlay_authority(schema)
    runtime_wrapper('${LD_RUN_PATH:+${LD_RUN_PATH}:}' + base_paths)
    native_overlay_profile(schema)
    @environment["LD_RUN_PATH"] = "/ambient/lib"
    output, errors, status = bootstrap("--version")
    assert status.success?, output + errors
    assert_nil JSON.parse(output).fetch("ld_run_path")
    with_fixture_environment do
      identity = MemoryBudget::ToolchainProfile.resolve(@package)
      assert_nil identity.environment.fetch("LD_RUN_PATH")
    end
  end

  def test_schema_two_native_overlay_explicit_removal_is_authoritative
    assert_native_overlay_authority(2)
  end

  def test_schema_three_native_overlay_explicit_removal_is_authoritative
    assert_native_overlay_authority(3)
  end

  def admit_wrapper_source(statements)
    write_executable(@wrapper, "#!/bin/bash\n" + statements)
    @profile["wrapper_sha256"] = hash(@wrapper)
    write_profile("normal", @profile)
  end

  def test_export_followed_by_unset_is_rejected_in_the_full_bootstrap
    admit_wrapper_source("export LD_RUN_PATH=\"#{base_paths}\"\nunset LD_RUN_PATH\nexec \"#{@backend}\" \"$@\"\n")
    assert_rejected("leading exec environment or an explicit export", "spec")
    assert_equal [["env", "CRYSTAL_PATH"]], File.readlines(@compiler_log).map { |line| JSON.parse(line) }
  end

  def test_conditional_export_is_rejected_in_the_full_bootstrap
    admit_wrapper_source("if false; then\n  export LD_RUN_PATH=\"#{base_paths}\"\nfi\nexec \"#{@backend}\" \"$@\"\n")
    assert_rejected("leading exec environment or an explicit export", "spec")
    assert_equal [["env", "CRYSTAL_PATH"]], File.readlines(@compiler_log).map { |line| JSON.parse(line) }
  end

  def test_quoted_assignment_identifiers_are_rejected_before_normalization
    ["'OTHER=value'", '"OTHER=value"', 'OTHER"="value'].each do |prefix|
      admit_wrapper_source("#{prefix} LD_RUN_PATH=\"#{base_paths}\" exec \"#{@backend}\" \"$@\"\n")
      assert_rejected("leading exec environment or an explicit export", "spec")
    end
  end

  def test_extra_statements_and_shell_control_operators_require_review
    ["true\n", ":\n", "false || ", "if true; then "].each do |prefix|
      admit_wrapper_source(prefix + "LD_RUN_PATH=\"#{base_paths}\" exec \"#{@backend}\" \"$@\"\n")
      error = assert_raises(MemoryBudget::ToolchainProfile::AdmissionError) { restored }
      assert_includes error.message, "leading exec environment or an explicit export"
    end
  end

  def test_actual_raw_assignment_identifiers_and_literal_values_are_supported
    ['OTHER=value', 'OTHER="value with spaces"', "OTHER='value with spaces'"].each do |prefix|
      admit_wrapper_source("#{prefix} LD_RUN_PATH=\"#{base_paths}\" exec \"#{@backend}\" \"$@\"\n")
      output, errors, status = bootstrap("spec")
      assert status.success?, output + errors
      assert_equal base_paths, JSON.parse(output).fetch("ld_run_path")
    end
  end

  def test_unconditional_export_and_static_exec_assignments_preserve_the_overlay
    admit_wrapper_source("export LD_RUN_PATH=\"${LD_RUN_PATH:+${LD_RUN_PATH}:}#{base_paths}\"\nCRYSTAL_PATH=\"lib:#{@stdlib}\" exec \"#{@backend}\" \"$@\"\n")
    @environment["LD_RUN_PATH"] = "/ambient/lib"
    output, errors, status = bootstrap("spec")
    assert status.success?, output + errors
    data = JSON.parse(output)
    assert_equal "/ambient/lib:" + base_paths, data.fetch("ld_run_path")
    assert_equal "lib:" + File.join(@environment.fetch("CRYSTAL_CACHE_DIR"), "budget-stdlib"), data.fetch("stdlib")
  end

  def test_dynamic_neighbor_assignments_require_review
    ['OTHER="$HOME"', 'OTHER="$(printf dynamic)"', 'OTHER="`printf dynamic`"'].each do |prefix|
      admit_wrapper_source("#{prefix} LD_RUN_PATH=\"#{base_paths}\" exec \"#{@backend}\" \"$@\"\n")
      error = assert_raises(MemoryBudget::ToolchainProfile::AdmissionError) { restored }
      assert_includes error.message, "static assignment values"
    end
  end

  def test_comments_and_empty_lines_keep_the_unconditional_statement_roster
    admit_wrapper_source("# ordinary wrapper comment\n\nexport LD_RUN_PATH=\"#{base_paths}\"\n# selected backend\nexec \"#{@backend}\" \"$@\"\n")
    assert_equal({"LD_RUN_PATH" => base_paths}, restored)
  end

  def test_complete_runtime_source_is_bounded_at_4096_bytes
    runtime_wrapper(base_paths)
    source = File.binread(@wrapper)
    source += "#" + "x" * (4096 - source.bytesize - 2) + "\n"
    write_executable(@wrapper, source)
    @profile["wrapper_sha256"] = hash(@wrapper)
    assert_equal 4096, File.size(@wrapper)
    assert_equal({"LD_RUN_PATH" => base_paths}, restored)
    File.open(@wrapper, "a") { |file| file.write("#") }
    @profile["wrapper_sha256"] = hash(@wrapper)
    assert_equal 4097, File.size(@wrapper)
    error = assert_raises(MemoryBudget::ToolchainProfile::AdmissionError) { restored }
    assert_includes error.message, "complete 4096-byte admission window"
  end

  def test_vertical_whitespace_and_other_control_bytes_require_review
    ["\v", "\f", "\r", "\0", "\x7f"].each do |control|
      admit_wrapper_source(control + "CRYSTAL_PATH=\"lib:#{@stdlib}\" LD_RUN_PATH=\"#{base_paths}\" exec \"#{@backend}\" \"$@\"\n")
      assert_rejected("unsupported shell control byte", "spec")
    end
  end

  def test_ascii_space_tab_and_lf_keep_supported_shell_meaning
    admit_wrapper_source(" \tCRYSTAL_PATH=\"lib:#{@stdlib}\"\tLD_RUN_PATH=\"#{base_paths}\" \texec \"#{@backend}\" \t\"$@\" \t\n")
    output, errors, status = bootstrap("spec")
    assert status.success?, output + errors
    assert_equal base_paths, JSON.parse(output).fetch("ld_run_path")
  end

  def test_runtime_wrapper_interpreter_requires_the_reviewed_static_shell_header
    ["#!#{RbConfig.ruby}", "#!/bin/false", "#!/usr/bin/env bash", "#!/bin/bash -e", "#! /bin/bash"].each do |header|
      write_executable(@wrapper, header + "\nLD_RUN_PATH=\"#{base_paths}\" exec \"#{@backend}\" \"$@\"\n")
      @profile["wrapper_sha256"] = hash(@wrapper)
      write_profile("normal", @profile)
      assert_rejected("reviewed static shell interpreter", "spec")
    end
  end
end
