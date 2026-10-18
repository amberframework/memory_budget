#!/usr/bin/env ruby
# frozen_string_literal: true
require "fileutils"
require "timeout"
require "uri"
require_relative "toolchain_profile"

module MemoryBudget
  # Preserve the inputs and observations needed to review a new installed build.
  # The draft envelope requires an explicit review/extraction step before use.
  module ToolchainCandidate
    class PreparationError < StandardError; end
    module_function

    def require_condition(condition, message)
      raise PreparationError, message unless condition
    end

    def keys(object, expected, description)
      require_condition(object.is_a?(Hash) && object.keys.sort == expected.sort, "Invalid #{description} fields")
    end

    def pinned_file(row, description)
      keys(row, %w[path sha256], description)
      path = ToolchainProfile.executable(row.fetch("path"), "", description)
      require_condition(row["sha256"].is_a?(String) && row["sha256"].match?(/\A[0-9a-f]{64}\z/) &&
        Digest::SHA256.file(path).hexdigest == row["sha256"], "#{description} SHA-256 mismatch")
      path
    end

    def pinned_data(row, description)
      keys(row, %w[path sha256], description)
      path = File.expand_path(row.fetch("path"))
      require_condition(File.file?(path) && !File.symlink?(path), "#{description} must be an ordinary file")
      require_condition(File.size(path) <= 32 * 1024 * 1024, "#{description} exceeds the preparation input cap")
      require_condition(row["sha256"].is_a?(String) && row["sha256"].match?(/\A[0-9a-f]{64}\z/) &&
        Digest::SHA256.file(path).hexdigest == row["sha256"], "#{description} SHA-256 mismatch")
      path
    end

    # Read local bytes without executing any observed tool. The returned values
    # require review against installation/source receipts before preparation.
    def inspect_paths(path)
      require_condition(File.file?(path) && !File.symlink?(path) && File.size(path) <= 1024 * 1024, "Inspection paths must be an ordinary file within 1 MiB")
      bytes = File.binread(path)
      paths = JSON.parse(bytes)
      keys(paths, %w[profile compiler_entrypoint stdlib_root ruby_launcher minecart_path compiler_source_commit compiler_version compiler_provenance minecart_version native_manifest git_manifest provenance_files], "inspection paths")
      pin = lambda do |file|
        physical = File.realpath(file)
        require_condition(File.file?(physical), "Inspection requires ordinary file bytes: #{file}")
        {"path" => physical, "sha256" => Digest::SHA256.file(physical).hexdigest}
      end
      entrypoint = ToolchainProfile.executable(paths.fetch("compiler_entrypoint"), "", "Compiler entrypoint")
      backend = ToolchainProfile.compiler_backend(entrypoint)
      stdlib = File.realpath(paths.fetch("stdlib_root"))
      require_condition(File.file?(File.join(stdlib, "prelude.cr")), "Inspection standard library prelude is missing")
      require_condition(paths["provenance_files"].is_a?(Array) && !paths["provenance_files"].empty?, "Inspection requires installation/source provenance files")
      config = {"schema_version" => 1, "profile" => paths.fetch("profile"),
        "compiler" => {"entrypoint" => pin.call(entrypoint), "backend" => pin.call(backend),
          "stdlib_root" => stdlib, "stdlib_sha256" => ToolchainProfile.stdlib_sha256(stdlib),
          "source_commit" => paths.fetch("compiler_source_commit"), "version" => paths.fetch("compiler_version"),
          "provenance" => pin.call(paths.fetch("compiler_provenance"))},
        "ruby" => {"backend" => pin.call(RbConfig.ruby), "launcher" => pin.call(paths.fetch("ruby_launcher")), "version" => RUBY_DESCRIPTION},
        "minecart" => {"executable" => pin.call(paths.fetch("minecart_path")), "version" => paths.fetch("minecart_version")},
        "native_manifest" => pin.call(paths.fetch("native_manifest")), "git_manifest" => pin.call(paths.fetch("git_manifest")),
        "provenance" => ([File.expand_path(path)] + paths.fetch("provenance_files")).uniq.map { |file| pin.call(file) }}
      {"inspection_schema_version" => 1, "status" => "UNREVIEWED_INPUTS", "commands_executed" => 0,
        "input_paths_sha256" => Digest::SHA256.hexdigest(bytes), "proposed_configuration" => config}
    end

    def validate_inputs(config)
      keys(config, %w[schema_version profile compiler ruby minecart native_manifest git_manifest provenance], "toolchain preparation")
      require_condition(config["schema_version"] == 1 && config["profile"].is_a?(String) && !config["profile"].strip.empty?, "Preparation requires schema 1 and a profile identity")
      compiler = config.fetch("compiler")
      keys(compiler, %w[entrypoint backend stdlib_root stdlib_sha256 source_commit version provenance], "compiler preparation")
      entrypoint = pinned_file(compiler.fetch("entrypoint"), "Compiler entrypoint")
      backend = pinned_file(compiler.fetch("backend"), "Compiler backend")
      require_condition(ToolchainProfile.compiler_backend(entrypoint) == backend, "Compiler wrapper selects a different backend")
      require_condition(compiler["source_commit"].is_a?(String) && compiler["source_commit"].match?(/\A[0-9a-f]{40}\z/), "Compiler source commit must be exact")
      require_condition(compiler["version"].is_a?(String) && !compiler["version"].strip.empty?, "Expected full compiler version is required")
      stdlib = File.realpath(compiler.fetch("stdlib_root"))
      require_condition(File.file?(File.join(stdlib, "prelude.cr")), "Standard library prelude is missing")
      require_condition(compiler["stdlib_sha256"].is_a?(String) && compiler["stdlib_sha256"].match?(/\A[0-9a-f]{64}\z/) &&
        ToolchainProfile.stdlib_sha256(stdlib) == compiler["stdlib_sha256"], "Standard library SHA-256 mismatch")
      ruby = config.fetch("ruby")
      keys(ruby, %w[backend launcher version], "Ruby preparation")
      ruby_backend = pinned_file(ruby.fetch("backend"), "Ruby backend")
      launcher = pinned_file(ruby.fetch("launcher"), "Ruby launcher")
      require_condition(File.realpath(RbConfig.ruby) == ruby_backend && ruby["version"] == RUBY_DESCRIPTION, "Preparation must run under the declared Ruby backend/version")
      minecart = config.fetch("minecart")
      keys(minecart, %w[executable version], "Minecart preparation")
      installer = pinned_file(minecart.fetch("executable"), "Minecart backend")
      require_condition(minecart["version"].is_a?(String) && !minecart["version"].strip.empty?, "Expected full Minecart version is required")
      native_path = pinned_data(config.fetch("native_manifest"), "Native manifest")
      git_path = pinned_data(config.fetch("git_manifest"), "Git manifest")
      native = NativeEnvironment.admit(config.fetch("native_manifest").fetch("sha256"), native_path)
      git = GitProvider.admit(config.fetch("git_manifest").fetch("sha256"), git_path)
      provenance = config.fetch("provenance")
      require_condition(provenance.is_a?(Array) && !provenance.empty?, "At least one reviewed installation/source provenance receipt is required")
      provenance_paths = provenance.map { |row| pinned_data(row, "Provenance receipt") }
      require_condition(provenance_paths.uniq == provenance_paths && provenance_paths.sum { |path| File.size(path) } <= 32 * 1024 * 1024,
        "Provenance paths must be unique and fit the aggregate input cap")
      compiler_provenance = pinned_data(compiler.fetch("provenance"), "Compiler source provenance")
      attribution = JSON.parse(File.read(compiler_provenance))
      keys(attribution, %w[schema_version status compiler_source_commit compiler_backend_sha256 stdlib_sha256 source_url source_archive_sha256 installation_receipt_sha256], "compiler source attribution")
      require_condition(attribution["schema_version"] == 1 && attribution["status"] == "REVIEWED_SOURCE_ATTRIBUTION", "Compiler source attribution requires explicit reviewed status")
      require_condition(attribution["compiler_source_commit"] == compiler.fetch("source_commit") &&
        attribution["compiler_backend_sha256"] == compiler.fetch("backend").fetch("sha256") &&
        attribution["stdlib_sha256"] == compiler.fetch("stdlib_sha256"), "Compiler source attribution source/backend/stdlib differs")
      url = URI.parse(attribution.fetch("source_url"))
      require_condition(url.scheme == "https" && url.host && !url.userinfo &&
        attribution["source_archive_sha256"].is_a?(String) && attribution["source_archive_sha256"].match?(/\A[0-9a-f]{64}\z/),
        "Compiler source attribution requires an HTTPS source URL and archive SHA-256")
      receipt_hashes = attribution["installation_receipt_sha256"]
      retained_hashes = provenance.map { |row| row.fetch("sha256") }
      require_condition(receipt_hashes.is_a?(Array) && !receipt_hashes.empty? && receipt_hashes.uniq == receipt_hashes &&
        receipt_hashes.all? { |pin| retained_hashes.include?(pin) }, "Compiler source attribution installation receipts are not retained")
      require_condition(([native_path, git_path, compiler_provenance] + provenance_paths).sum { |path| File.size(path) } <= 64 * 1024 * 1024,
        "All retained manifest/provenance inputs must fit the 64 MiB aggregate cap")
      {"entrypoint" => entrypoint, "backend" => backend, "stdlib_root" => stdlib,
        "ruby_backend" => ruby_backend, "ruby_launcher" => launcher, "minecart" => installer,
        "native_manifest" => native_path, "git_manifest" => git_path, "compiler_provenance" => compiler_provenance, "provenance" => provenance_paths,
        "environment" => native.environment.merge(git.environment)}
    end

    def metadata(environment, command, directory, label, seconds: 15)
      require_condition(seconds.positive? && seconds <= 15, "Metadata deadline must be finite and at most 15 seconds")
      output_path = File.join(directory, "#{label}.stdout")
      error_path = File.join(directory, "#{label}.stderr")
      pid = nil
      status = nil
      group_alive = false
      receipt = nil
      begin
        File.open(output_path, "wb") do |output|
          File.open(error_path, "wb") do |errors|
            pid = Process.spawn(environment, *command, out: output, err: errors, pgroup: true)
            group_alive = true
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            loop do
              waited = Process.waitpid2(pid, Process::WNOHANG)
              if waited
                status = waited.last
                break
              end
              require_condition(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < seconds, "Metadata deadline exceeded: #{label}")
              require_condition(File.size(output_path) + File.size(error_path) <= 1024 * 1024, "Metadata output cap exceeded: #{label}")
              sleep 0.01
            end
          end
        end
        group_alive = begin
          Process.kill(0, -pid)
          true
        rescue Errno::ESRCH
          false
        end
        require_condition(!group_alive, "Metadata child left an owned process group alive: #{label}")
        require_condition(File.size(output_path) + File.size(error_path) <= 1024 * 1024, "Metadata output cap exceeded: #{label}")
        require_condition(status.success?, "Metadata command failed: #{label} (#{status.exitstatus})")
        receipt = {"command" => command, "exit_status" => status.exitstatus,
          "stdout_file" => File.basename(output_path), "stdout_sha256" => Digest::SHA256.file(output_path).hexdigest,
          "stderr_file" => File.basename(error_path), "stderr_sha256" => Digest::SHA256.file(error_path).hexdigest,
          "output" => File.read(output_path).strip}
      ensure
        terminal = cleanup_metadata(pid, status) if pid
        receipt["terminal_ownership"] = terminal if receipt
      end
    end

    def cleanup_metadata(pid, status)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      reaped = !status.nil?
      loop do
        unless reaped
          begin
            waited = Process.waitpid2(pid, Process::WNOHANG)
            if waited
              status = waited.last
              reaped = true
            end
          rescue Errno::ECHILD
            reaped = true
          end
        end
        group_exists = begin
          Process.kill(0, -pid)
          true
        rescue Errno::ESRCH
          false
        rescue Errno::EPERM
          true
        end
        return {"pid" => pid, "direct_child_reaped" => true, "owned_group_absent" => true} if reaped && !group_exists
        if group_exists
          begin
            Process.kill("KILL", -pid)
          rescue Errno::ESRCH, Errno::EPERM
            # macOS can briefly refuse signals while a child exits. Acceptance
            # still requires actual reaping and group absence within this bound.
            nil
          end
        end
        require_condition(Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline, "Owned metadata cleanup is not terminal: #{pid}")
        sleep 0.01
      end
    end

    def prepare(config_path, destination)
      created = nil
      require_condition(File.file?(config_path) && !File.symlink?(config_path) && File.size(config_path) <= 1024 * 1024, "Preparation configuration must be an ordinary file within 1 MiB")
      config_bytes = File.binread(config_path)
      config = JSON.parse(config_bytes)
      selected = validate_inputs(config)
      destination = File.expand_path(destination)
      require_condition(!File.exist?(destination) && !File.symlink?(destination), "Preparation destination must be new")
      require_condition(File.directory?(File.dirname(destination)) && File.realpath(File.dirname(destination)) == File.dirname(destination), "Preparation parent must be physical")
      Dir.mkdir(destination, 0o700)
      created = [File.stat(destination).dev, File.stat(destination).ino]
      File.binwrite(File.join(destination, "INPUT_CONFIGURATION.json"), config_bytes)
      retained = []
      ([selected.fetch("native_manifest"), selected.fetch("git_manifest"), selected.fetch("compiler_provenance")] + selected.fetch("provenance")).each_with_index do |path, index|
        name = "input-#{index}.bytes"
        FileUtils.cp(path, File.join(destination, name))
        retained << {"source_path" => path, "file" => name, "sha256" => Digest::SHA256.file(path).hexdigest}
      end
      results = []
      operations = [
        ["compiler-version", [selected.fetch("backend"), "--version"], config.fetch("compiler").fetch("version").strip],
        ["compiler-path", [selected.fetch("backend"), "env", "CRYSTAL_PATH"], nil],
        ["minecart-version", [selected.fetch("minecart"), "--version"], config.fetch("minecart").fetch("version").strip],
        ["git-version", [JSON.parse(File.read(selected.fetch("git_manifest"))).fetch("provider").fetch("git_path"), "--version"],
          JSON.parse(File.read(selected.fetch("git_manifest"))).fetch("provider").fetch("version")]
      ]
      operations.each do |label, command, expected|
        require_condition(File.binread(config_path) == config_bytes, "Preparation configuration changed before metadata")
        require_condition(validate_inputs(config) == selected, "Preparation identities changed before metadata")
        result = metadata(selected.fetch("environment"), command, destination, label)
        results << result
        require_condition(File.binread(config_path) == config_bytes, "Preparation configuration changed during metadata")
        require_condition(validate_inputs(config) == selected, "Preparation identities changed during metadata")
        if expected
          require_condition(result.fetch("output") == expected, "Metadata version differs: #{label}")
        else
          paths = result.fetch("output").split(File::PATH_SEPARATOR).select { |path| File.directory?(path) }.map { |path| File.realpath(path) }
          require_condition(paths.include?(selected.fetch("stdlib_root")), "Compiler metadata selects a different standard library")
        end
      end
      compiler = config.fetch("compiler")
      profile = {"schema_version" => 3, "profile" => config.fetch("profile"), "counter_protocol" => 1,
        "compiler_sha256" => compiler.fetch("backend").fetch("sha256"), "compiler_commit" => compiler.fetch("source_commit"),
        "compiler_provenance_sha256" => compiler.fetch("provenance").fetch("sha256"),
        "stdlib_sha256" => compiler.fetch("stdlib_sha256"), "ruby_sha256" => config.fetch("ruby").fetch("backend").fetch("sha256"),
        "ruby_version" => RUBY_DESCRIPTION, "ruby_launcher_sha256" => config.fetch("ruby").fetch("launcher").fetch("sha256"),
        "minecart_sha256" => config.fetch("minecart").fetch("executable").fetch("sha256"), "minecart_version" => config.fetch("minecart").fetch("version"),
        "native_component_manifest_sha256" => config.fetch("native_manifest").fetch("sha256"),
        "git_provider_manifest_sha256" => config.fetch("git_manifest").fetch("sha256")}
      profile["wrapper_sha256"] = compiler.fetch("entrypoint").fetch("sha256") if selected.fetch("entrypoint") != selected.fetch("backend")
      draft = {"draft_schema_version" => 1, "status" => "UNADMITTED", "proposed_profile" => profile,
        "bounds" => {"metadata_command_seconds" => 15, "metadata_command_output_bytes" => 1048576,
          "cli_work_seconds" => 75, "terminal_cleanup_seconds" => 2, "retained_input_bytes" => 67108864},
        "input_configuration_sha256" => Digest::SHA256.hexdigest(config_bytes), "retained_inputs" => retained,
        "observed_paths" => selected.reject { |key, _value| key == "environment" }, "metadata" => results,
        "qualification" => "Metadata only; compiler/spec/tutorial/native and public-device acceptance remain pending"}
      File.write(File.join(destination, "DRAFT_PROFILE.json"), JSON.pretty_generate(draft) + "\n")
      draft
    rescue StandardError => error
      if created && File.directory?(destination) && !File.symlink?(destination) &&
         [File.stat(destination).dev, File.stat(destination).ino] == created &&
         File.file?(File.join(destination, "INPUT_CONFIGURATION.json"))
        File.write(File.join(destination, "PREPARATION_FAILURE.json"), JSON.pretty_generate({"prepared" => false, "admitted" => false,
          "error" => error.message, "metadata" => results || []}) + "\n")
      end
      raise
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    abort "Usage: ruby scripts/prepare_toolchain_profile.rb --inspect INPUT_PATHS.json | CONFIGURATION.json NEW_OUTPUT_DIRECTORY" unless ARGV.length == 2
    Timeout.timeout(75) do
      if ARGV.first == "--inspect"
        puts JSON.pretty_generate(MemoryBudget::ToolchainCandidate.inspect_paths(ARGV.last))
      else
        draft = MemoryBudget::ToolchainCandidate.prepare(ARGV[0], ARGV[1])
        puts "Prepared #{draft.fetch('status')} toolchain draft in #{File.expand_path(ARGV[1])}"
      end
    end
  rescue MemoryBudget::ToolchainCandidate::PreparationError, MemoryBudget::ToolchainProfile::AdmissionError,
         MemoryBudget::NativeEnvironment::AdmissionError, MemoryBudget::GitProvider::AdmissionError,
         JSON::ParserError, KeyError, TypeError, ArgumentError, Errno::ENOENT, Errno::EACCES, Timeout::Error, URI::InvalidURIError => error
    abort "Toolchain candidate preparation failed: #{error.message}"
  end
end
