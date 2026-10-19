# frozen_string_literal: true
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../scripts/native_environment"

# Physical files are real private fixtures. Linux/Darwin platform identities are
# logical test inputs; these controls establish zero ELF linking/loading proof.
class NativeEnvironmentBehavior
  Native = MemoryBudget::NativeEnvironment
  ROOT = File.realpath(File.join(__dir__, ".."))

  def initialize(output)
    @output = File.expand_path(output)
    raise "Fresh canonical evidence root required" if File.exist?(@output) || File.symlink?(@output)
    raise "Evidence root must be contained in the admitted output parent" unless File.dirname(@output) == File.realpath(ENV.fetch("MEMORY_BUDGET_TEST_OUTPUT_PARENT"))
    Dir.mkdir(@output, 0o700)
    @temporary = File.join(@output, "tmp")
    Dir.mkdir(@temporary, 0o700)
    @cases = []
    @children = []
  end

  def assert(value, message = "Expected behavior did not hold")
    raise message unless value
  end

  def refuse(message)
    begin
      yield
    rescue Native::AdmissionError => error
      assert(error.message.include?(message), "Wanted #{message.inspect}; actual #{error.message.inspect}")
      return
    end
    raise "Expected refusal: #{message}"
  end

  def logical_platform(system)
    {"sysname" => system, "release" => "logical-test-release", "version" => "logical-test-version", "machine" => "logical-test-machine"}
  end

  def with_platform(mod, value)
    previous = mod.method(:platform)
    mod.define_singleton_method(:platform) { value.dup }
    yield
  ensure
    mod.define_singleton_method(:platform, previous)
  end

  def fixture(schema = 2, system = "Linux", trace = false)
    with_platform(Native, logical_platform(system)) do
      @root = Dir.mktmpdir("fixture-", @temporary)
      @lib = File.join(@root, "versioned native prefix with spaces", "lib")
      @pkg = File.join(@root, "versioned native prefix with spaces", "pkgconfig")
      [@lib, @pkg].each { |path| FileUtils.mkdir_p(path) }
      @provider = File.join(@lib, system == "Linux" ? "libfixture.so.1" : "libfixture.1.dylib")
      @alias = File.join(@lib, system == "Linux" ? "libfixture.so" : "libfixture.dylib")
      File.binwrite(@provider, "native provider fixture bytes\n")
      File.symlink(File.basename(@provider), @alias)
      File.write(File.join(@pkg, "fixture.pc"), "Version: fixture-1\n")
      loader = system == "Linux" && schema == 2 ? "LD_LIBRARY_PATH" : "DYLD_LIBRARY_PATH"
      @manifest = {"schema_version" => schema, "profile" => "platform-fixture-v2", "platform" => Native.platform,
        "directories" => [@lib, @pkg].map { |path| Native.snapshot_directory(path) }, "files" => [],
        "environment" => {"CRYSTAL_LIBRARY_PATH" => [@lib], loader => [@lib], "PKG_CONFIG_LIBDIR" => [@pkg], "PKG_CONFIG_PATH" => []},
        "loader_trace" => trace}
      @manifest["loader_family"] = system == "Darwin" ? "darwin_dyld" : "elf_ld" if schema == 2
      @lock = File.join(@root, "native.manifest.json")
      write_manifest
      yield
    ensure
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end
  end

  def write_manifest
    File.binwrite(@lock, JSON.pretty_generate(@manifest) + "\n")
    @identity = Native.admit(Digest::SHA256.file(@lock).hexdigest, @lock)
  end

  def with_environment(values)
    saved = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def old_helper
    namespace = Module.new
    path = File.join(ROOT, "test/fixtures/native_environment_schema1.rb")
    namespace.module_eval(File.binread(path), path)
    namespace.const_get(:MemoryBudget).const_get(:NativeEnvironment)
  end

  def test_schema_one_darwin_environment_is_exactly_legacy
    fixture(1, "Darwin") do
      legacy = old_helper
      with_platform(legacy, Native.platform) do
        previous = legacy.admit(Digest::SHA256.file(@lock).hexdigest, @lock).environment
        assert(@identity.environment == previous, "Valid schema1 Darwin behavior changed")
      end
    end
  end

  def test_schema_two_darwin_trace_and_paths
    fixture(2, "Darwin", true) do
      values = @identity.environment
      assert(values.fetch("DYLD_LIBRARY_PATH") == @lib && values.fetch("DYLD_PRINT_LIBRARIES") == "1")
      assert(values.fetch("LD_LIBRARY_PATH").nil? && values.fetch("LD_DEBUG").nil?)
    end
  end

  def test_schema_two_elf_trace_and_paths
    fixture(2, "Linux", true) do
      values = @identity.environment
      assert(values.fetch("LD_LIBRARY_PATH") == @lib && values.fetch("LD_DEBUG") == "libs")
      assert(values.fetch("DYLD_LIBRARY_PATH").nil? && values.fetch("DYLD_PRINT_LIBRARIES").nil?)
    end
  end

  def test_false_trace_explicitly_clears_both_families
    fixture do
      values = @identity.environment
      assert(values.fetch("LD_DEBUG").nil? && values.fetch("DYLD_PRINT_LIBRARIES").nil? && values.fetch("LD_DEBUG_OUTPUT").nil?)
    end
  end

  def test_ambient_loader_changes_are_removed_without_mutating_parent
    fixture do
      ambient = {"LD_PRELOAD" => "/foreign/preload.so", "DYLD_INSERT_LIBRARIES" => "/foreign/preload.dylib", "LD_UNREVIEWED" => "foreign"}
      with_environment(ambient) do
        values = @identity.environment
        assert(ambient.all? { |key, value| values.key?(key) && values[key].nil? && ENV[key] == value })
      end
    end
  end

  def test_environment_is_rebuilt_after_boundary_deletion_and_restoration
    fixture do
      expected = @identity.environment
      with_environment(@manifest.fetch("environment").keys.to_h { |key| [key, nil] }) do
        assert(@identity.environment == expected)
        ENV["LD_LIBRARY_PATH"] = "/foreign/lib"
        assert(@identity.environment.fetch("LD_LIBRARY_PATH") == @lib)
      end
      assert(@identity.environment == expected)
    end
  end

  def test_old_helper_refuses_required_schema_two
    fixture do
      legacy = old_helper
      with_platform(legacy, Native.platform) do
        begin
          legacy.admit(Digest::SHA256.file(@lock).hexdigest, @lock)
        rescue StandardError => error
          assert(error.is_a?(legacy.const_get(:AdmissionError)), "Expected the original native admission error class")
          assert(error.message.include?("Invalid native manifest fields"))
        else
          raise "Old native helper silently admitted schema2"
        end
      end
      assert(@identity.environment.fetch("LD_LIBRARY_PATH") == @lib)
    end
  end

  def test_missing_loader_family_refuses_and_restores
    fixture do
      original = @manifest.delete("loader_family")
      refuse("Invalid native manifest fields") { Native.validate_manifest(@manifest) }
      @manifest["loader_family"] = original
      assert(Native.validate_manifest(@manifest) == @manifest)
    end
  end

  def test_wrong_loader_family_refuses_and_restores
    fixture do
      @manifest["loader_family"] = "darwin_dyld"
      refuse("Native loader family differs from platform") { Native.validate_manifest(@manifest) }
      @manifest["loader_family"] = "elf_ld"
      assert(Native.validate_manifest(@manifest) == @manifest)
    end
  end

  def test_unknown_schema_and_noninteger_schema_refuse
    fixture do
      [3, 2.0, "2"].each do |value|
        @manifest["schema_version"] = value
        refuse("Unsupported native manifest schema") { Native.validate_manifest(@manifest) }
      end
      @manifest["schema_version"] = 2
      assert(Native.validate_manifest(@manifest) == @manifest)
    end
  end

  def test_wrong_actual_platform_refuses_and_restores
    fixture do
      @manifest["platform"]["machine"] = "foreign-machine"
      refuse("Native platform identity differs") { Native.validate_manifest(@manifest) }
      @manifest["platform"] = Native.platform
      assert(Native.validate_manifest(@manifest) == @manifest)
    end
  end

  def test_unknown_platform_family_refuses
    fixture do
      with_platform(Native, logical_platform("UnknownOS")) do
        @manifest["platform"] = Native.platform
        refuse("Native loader family differs from platform") { Native.validate_manifest(@manifest) }
      end
    end
  end

  def test_provider_byte_drift_refuses_and_restores
    fixture do
      bytes = File.binread(@provider)
      File.binwrite(@provider, bytes + "changed")
      refuse("Native directory roster differs") { @identity.environment }
      File.binwrite(@provider, bytes)
      assert(@identity.environment.fetch("LD_LIBRARY_PATH") == @lib)
    end
  end

  def test_provider_mode_drift_refuses_and_restores
    fixture do
      mode = File.stat(@provider).mode & 0o7777
      File.chmod(mode ^ 0o100, @provider)
      refuse("Native directory roster differs") { @identity.environment }
      File.chmod(mode, @provider)
      assert(@identity.environment.fetch("LD_LIBRARY_PATH") == @lib)
    end
  end

  def test_alias_target_drift_refuses_and_restores
    fixture do
      File.unlink(@alias)
      File.symlink("./" + File.basename(@provider), @alias)
      refuse("Native directory roster differs") { @identity.environment }
      File.unlink(@alias)
      File.symlink(File.basename(@provider), @alias)
      assert(@identity.environment.fetch("LD_LIBRARY_PATH") == @lib)
    end
  end

  def test_foreign_alias_provider_refuses
    fixture do
      foreign = File.join(@root, "foreign.so")
      File.write(foreign, "foreign")
      File.unlink(@alias)
      File.symlink(foreign, @alias)
      @manifest["directories"][0] = Native.snapshot_directory(@lib)
      refuse("symlink target must have its own admitted physical entry") { Native.validate_manifest(@manifest) }
    end
  end

  def test_unlisted_provider_refuses_and_restores
    fixture do
      extra = File.join(@lib, "extra.so")
      File.write(extra, "foreign")
      refuse("Native directory roster differs") { @identity.environment }
      File.unlink(extra)
      assert(@identity.environment.fetch("LD_LIBRARY_PATH") == @lib)
    end
  end

  def test_ambiguous_provider_search_order_refuses
    fixture do
      other = File.join(@root, "other lib")
      Dir.mkdir(other)
      File.write(File.join(other, File.basename(@provider)), "different bytes")
      @manifest["directories"] << Native.snapshot_directory(other)
      @manifest["environment"]["LD_LIBRARY_PATH"] << other
      refuse("Ambiguous native search alias") { Native.validate_manifest(@manifest) }
    end
  end

  def test_elf_environment_rejects_darwin_key_and_restores
    fixture do
      value = @manifest["environment"].delete("LD_LIBRARY_PATH")
      @manifest["environment"]["DYLD_LIBRARY_PATH"] = value
      refuse("Invalid native environment fields") { Native.validate_manifest(@manifest) }
      @manifest["environment"].delete("DYLD_LIBRARY_PATH")
      @manifest["environment"]["LD_LIBRARY_PATH"] = value
      assert(Native.validate_manifest(@manifest) == @manifest)
    end
  end

  def test_empty_or_unadmitted_loader_directory_refuses
    fixture do
      [[], ["/foreign/lib"]].each do |paths|
        @manifest["environment"]["LD_LIBRARY_PATH"] = paths
        expected = paths.empty? ? "Native library search paths must be explicit" : "unique admitted physical directories"
        refuse(expected) { Native.validate_manifest(@manifest) }
      end
      @manifest["environment"]["LD_LIBRARY_PATH"] = [@lib]
      assert(Native.validate_manifest(@manifest) == @manifest)
    end
  end

  def test_manifest_bytes_drift_refuses_and_restores
    fixture do
      bytes = File.binread(@lock)
      File.binwrite(@lock, bytes + " ")
      refuse("Native manifest SHA-256 mismatch") { @identity.environment }
      File.binwrite(@lock, bytes)
      assert(@identity.environment.fetch("LD_LIBRARY_PATH") == @lib)
    end
  end

  def test_held_manifest_is_immutable
    fixture do
      begin
        @identity.manifest.fetch("environment").fetch("LD_LIBRARY_PATH") << "/foreign"
      rescue FrozenError
        assert(@identity.environment.fetch("LD_LIBRARY_PATH") == @lib)
      else
        raise "Held manifest unexpectedly mutable"
      end
    end
  end

  def test_configuration_version_and_loader_fields_are_required
    fixture do
      config = {"schema_version" => 2, "loader_family" => "elf_ld", "profile" => "fixture", "environment" => @manifest.fetch("environment"), "files" => [], "loader_trace" => false}
      assert(Native.validate_configuration(config) == {"schema_version" => 2, "loader_family" => "elf_ld"})
      family = config.delete("loader_family")
      refuse("Invalid native roots configuration fields") { Native.validate_configuration(config) }
      config["loader_family"] = family
      assert(Native.validate_configuration(config).fetch("schema_version") == 2)
    end
  end

  def test_configuration_paths_require_arrays_and_canonical_values
    fixture do
      config = {"schema_version" => 2, "loader_family" => "elf_ld", "profile" => "fixture", "environment" => @manifest.fetch("environment").dup, "files" => [], "loader_trace" => false}
      config["environment"]["LD_LIBRARY_PATH"] = @lib
      refuse("search paths must be arrays") { Native.validate_configuration(config) }
      config["environment"]["LD_LIBRARY_PATH"] = ["relative/path"]
      refuse("Native paths must be absolute") { Native.validate_configuration(config) }
      config["environment"]["LD_LIBRARY_PATH"] = [@lib]
      assert(Native.validate_configuration(config).fetch("loader_family") == "elf_ld")
    end
  end

  def test_legacy_configuration_keeps_original_shape
    fixture(1, "Darwin") do
      config = {"profile" => "fixture", "environment" => @manifest.fetch("environment"), "files" => [], "loader_trace" => false}
      assert(Native.validate_configuration(config) == {"schema_version" => 1})
    end
  end

  def child(arguments, label)
    environment = ENV.to_h
    environment.keys.grep(/\A(?:DYLD_|LD_)/).each { |key| environment[key] = nil }
    environment["TMPDIR"] = @temporary
    output, errors, status = Open3.capture3(environment, RbConfig.ruby, *arguments)
    File.binwrite(File.join(@output, label + ".stdout"), output)
    File.binwrite(File.join(@output, label + ".stderr"), errors)
    assert(output.bytesize + errors.bytesize <= 1024 * 1024, "Finite fixture child raw bytes required")
    @children << {"label" => label, "argv" => [RbConfig.ruby] + arguments,
      "exit_status" => status.exitstatus, "pid" => status.pid, "waited_terminal" => true,
      "stdout_sha256" => Digest::SHA256.hexdigest(output), "stderr_sha256" => Digest::SHA256.hexdigest(errors)}
    assert(status.success? && errors.empty?, "Fixture child failed: #{errors}")
    JSON.parse(output)
  end

  def platform_hook
    path = File.join(@root, "logical_platform.rb")
    File.write(path, "require 'etc'\nEtc.define_singleton_method(:uname) { #{Native.platform.transform_keys(&:to_sym).inspect} }\n")
    path
  end

  def test_actual_generator_caller_with_logical_elf_and_darwin_inputs
    ["Darwin", "Linux"].each do |system|
      fixture(2, system) do
        config = {"schema_version" => 2, "loader_family" => @manifest.fetch("loader_family"), "profile" => "fixture", "environment" => @manifest.fetch("environment"), "files" => [], "loader_trace" => false}
        path = File.join(@root, "config.json")
        File.write(path, JSON.generate(config))
        actual = child(["-r", platform_hook, File.join(ROOT, "scripts/prepare_native_manifest.rb"), path], "generator-" + system)
        assert(actual.fetch("schema_version") == 2 && actual.fetch("loader_family") == config.fetch("loader_family"))
        assert(Native.validate_manifest(actual) == actual)
      end
    end
  end

  def test_actual_ruby_boundary_rebuilds_native_environment
    fixture do
      program = "require 'json'; require ARGV.fetch(0); n=MemoryBudget::NativeEnvironment; p=ARGV.fetch(1); i=n.admit(Digest::SHA256.file(p).hexdigest,p); puts JSON.generate(i.environment)"
      actual = child(["-r", platform_hook, "-e", program, File.join(ROOT, "scripts/native_environment.rb"), @lock], "ruby-boundary")
      assert(actual.fetch("LD_LIBRARY_PATH") == @lib && actual.fetch("CRYSTAL_LIBRARY_PATH") == @lib)
      assert(actual.fetch("DYLD_PRINT_LIBRARIES").nil? && actual.fetch("LD_DEBUG").nil?)
      assert(actual.fetch("MEMORY_BUDGET_NATIVE_COMPONENT_LOCK") == @lock)
    end
  end

  def run
    names = self.class.instance_methods(false).grep(/^test_/).map(&:to_s).sort
    names.each do |name|
      begin
        send(name)
        @cases << {"case" => name, "passed" => true}
      rescue StandardError => error
        @cases << {"case" => name, "passed" => false, "error" => {"type" => error.class.name, "message" => error.message}}
      end
    end
    passed = @cases.all? { |entry| entry.fetch("passed") }
    assert(Dir.children(@temporary).empty?, "Private fixture directories remain")
    value = {"passed" => passed, "authored_tests" => names, "test_count" => names.size,
      "cases" => @cases, "actual_ruby_children" => @children, "temporary_fixtures_absent" => true,
      "ELF_link_or_loaded_provider_acceptance" => false, "new_compiler_jobs" => 0,
      "scope" => "Real physical fixture/hash/alias/environment and Ruby caller behavior; logical platform injection; actual native loader/ELF execution remains pending"}
    File.write(File.join(@output, "RESULT.json"), JSON.pretty_generate(value) + "\n")
    puts JSON.generate(value)
    passed ? 0 : 1
  end
end

abort "Usage: ruby test_native_environment.rb FRESH_OWNED_EVIDENCE_ROOT" unless ARGV.length == 1
exit NativeEnvironmentBehavior.new(ARGV.fetch(0)).run
