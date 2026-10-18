#!/usr/bin/env ruby
# frozen_string_literal: true
require "digest"
require "json"
require "open3"
require "fileutils"
require "timeout"
require "rbconfig"

# Build one identified spec executable and independently verify its raw evidence.
project_root = File.expand_path("..", __dir__)
Dir.chdir(project_root)
bundle_root = File.join(project_root, "performance", "vendor", "memory_budget")
manifest_path = File.join(bundle_root, "PACKAGE_PINS.json")
manifest = JSON.parse(File.read(manifest_path))
abort "Invalid budget bundle" unless manifest.fetch("schema_version") == 1 && manifest.fetch("package_name") == "memory_budget"
manifest.fetch("files").each do |entry|
  relative = entry.fetch("file")
  abort "Invalid bundle file path" if relative.start_with?("/") || relative.split("/").include?("..")
  abort "Budget bundle SHA-256 mismatch: #{relative}" unless Digest::SHA256.file(File.join(bundle_root, relative)).hexdigest == entry.fetch("sha256")
end
expected_paths = manifest.fetch("files").map { |entry| entry.fetch("file") } + ["PACKAGE_PINS.json"]
actual_paths = Dir.glob(File.join(bundle_root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.map { |path| path.delete_prefix(bundle_root + "/") }
abort "Budget bundle file roster differs" unless expected_paths.uniq == expected_paths && actual_paths.sort == expected_paths.sort
policy_path = File.join(project_root, "performance", "memory_budget.json")
policy_sha256 = Digest::SHA256.file(policy_path).hexdigest
contract = JSON.parse(File.read(policy_path))
required_scenarios = contract.fetch("list_of_required_scenarios")
abort "A nonempty unique scenario roster is required" unless required_scenarios.is_a?(Array) && !required_scenarios.empty? && required_scenarios.uniq == required_scenarios
abort "Policy roster differs" unless contract.fetch("list_of_policies").map { |policy| policy.fetch("scenario_name") }.sort == required_scenarios.sort

def source_tree_sha256
  paths = Dir.glob("{src,spec,config,performance,examples,bench}/**/*") + Dir.glob("lib/*/**/*") + %w[shard.yml shard.lock .crystal-flags .amber.yml]
  Digest::SHA256.hexdigest(paths.uniq.select { |path| File.file?(path) && !path.start_with?("performance/results/") }.sort.map { |path| "#{Digest::SHA256.file(path).hexdigest}  #{path}\n" }.join)
end

def execute_budget_command(command, environment, prefix)
  stdout_path = prefix + ".stdout.txt"
  stderr_path = prefix + ".stderr.txt"
  process_status = nil
  has_timed_out = false
  File.open(stdout_path, "w") do |stdout|
    File.open(stderr_path, "w") do |stderr|
      child_pid = Process.spawn(environment, *command, out: stdout, err: stderr, pgroup: true)
      begin
        Timeout.timeout(300) { _pid, process_status = Process.wait2(child_pid) }
      rescue Timeout::Error
        has_timed_out = true
        begin
          Process.kill("TERM", -child_pid)
          sleep 0.2
          Process.kill("KILL", -child_pid)
        rescue Errno::ESRCH
        end
        Process.wait(child_pid) rescue nil
      end
    end
  end
  output = File.read(stdout_path) + File.read(stderr_path)
  puts output
  {"command" => command, "exit_status" => process_status && process_status.exitstatus, "timed_out" => has_timed_out, "stdout" => File.basename(stdout_path), "stderr" => File.basename(stderr_path), "output" => output}
end

source_sha256 = source_tree_sha256
results_root = File.join(project_root, "performance", "results")
FileUtils.mkdir_p(results_root)
source_commit, _error, source_status = Open3.capture3("git", "rev-parse", "HEAD")
abort "Cannot identify source commit" unless source_status.success?
require File.join(bundle_root, "scripts", "toolchain_profile")
begin
  admitted_toolchain = MemoryBudget::ToolchainProfile.resolve(bundle_root)
rescue MemoryBudget::ToolchainProfile::AdmissionError => error
  abort error.message
end
profile_path = admitted_toolchain.profile_path
profile = admitted_toolchain.profile
compiler_profile_sha256 = Digest::SHA256.file(profile_path).hexdigest
bootstrap = [RbConfig.ruby, File.join(bundle_root, "scripts", "budget.rb")]
list_of_spec_files = ["spec/performance/memory_budget_spec.cr"]
entry_path = File.join(results_root, "memory_budget_spec_entry.cr")
File.write(entry_path, list_of_spec_files.map { |path| "require #{("../../" + path).to_json}\n" }.join)
spec_binary = File.join(results_root, "memory-budget-spec")
checker_binary = File.join(results_root, "memory-budget-check")
environment = admitted_toolchain.environment.merge("MEMORY_BUDGET_PROJECT_ROOT" => project_root, "CRYSTAL_WORKERS" => "1")
list_of_builds = []
[["spec-build", entry_path, spec_binary], ["checker-build", File.join(bundle_root, "src", "cli.cr"), checker_binary]].each do |label, source, binary|
  FileUtils.rm_f(binary)
  command = bootstrap + ["build", source, "-Dfiber_allocation_tally", "-Dwithout_mt", "-o", binary]
  result = execute_budget_command(command, environment, File.join(results_root, "memory-budget-#{label}"))
  list_of_builds << result.reject { |key, _value| key == "output" }
  break unless result.fetch("exit_status") == 0 && !result.fetch("timed_out") && File.executable?(binary)
end
list_of_errors = []
has_passed = list_of_builds.size == 2 && list_of_builds.all? { |build| build.fetch("exit_status") == 0 && !build.fetch("timed_out") }
list_of_errors << "Memory spec or common verifier compilation failed" unless has_passed
spec_executable_sha256 = File.file?(spec_binary) ? Digest::SHA256.file(spec_binary).hexdigest : nil
checker_sha256 = File.file?(checker_binary) ? Digest::SHA256.file(checker_binary).hexdigest : nil
list_of_runs = []
if has_passed
  [{"label" => "baseline", "injected" => false}, {"label" => "sensitivity", "injected" => true}].each do |run|
    next if run.fetch("injected") && !ARGV.include?("--self-test")
    label = run.fetch("label")
    run_environment = environment.merge("MEMORY_BUDGET_INJECT_REGRESSION" => run.fetch("injected") ? "1" : "0")
    result = execute_budget_command([spec_binary, "--no-color"], run_environment, File.join(results_root, "memory-budget-#{label}"))
    output = result.delete("output")
    observations = []
    passed = false
    begin
      observations = output.lines.select { |line| line.include?("MEMORY_BUDGET_OBSERVATION_JSON=") }.map { |line| JSON.parse(line.split("MEMORY_BUDGET_OBSERVATION_JSON=", 2).last) }
      if run.fetch("injected")
        passed = !result.fetch("timed_out") && result.fetch("exit_status") && result.fetch("exit_status") != 0 && output.include?("exceeded")
      else
        passed = !result.fetch("timed_out") && result.fetch("exit_status") == 0 && output.include?("0 failures, 0 errors")
        passed &&= observations.map { |verdict| verdict.fetch("scenario_name") }.sort == required_scenarios.sort
        passed &&= observations.all? { |verdict| verdict.fetch("verdict_status") == "passed" && verdict.fetch("list_of_violations").empty? }
        passed &&= observations.all? { |verdict| verdict.fetch("list_of_capabilities").uniq == verdict.fetch("list_of_capabilities") }
        list_of_capabilities = observations.flat_map { |verdict| verdict.fetch("list_of_capabilities") }.uniq
        evidence = {"schema_version" => 1, "run_id" => "spec-baseline", "source_commit" => source_commit.strip,
                    "executable_sha256" => spec_executable_sha256, "policy_sha256" => policy_sha256,
                    "compiler_version" => "#{profile.fetch('profile')}; profile-sha256=#{compiler_profile_sha256}",
                    "instrumentation_mode" => "fiber_allocation_tally/protocol-1",
                    "list_of_measurements" => observations.flat_map { |verdict| verdict.fetch("list_of_measurements") },
                    "list_of_capabilities" => list_of_capabilities}
        evidence_path = File.join(results_root, "memory-budget-evidence.json")
        verified_path = File.join(results_root, "memory-budget-verified.json")
        File.write(evidence_path, JSON.pretty_generate(evidence) + "\n")
        FileUtils.rm_f(verified_path)
        verification = execute_budget_command([checker_binary, "check", policy_path, evidence_path, verified_path], environment, File.join(results_root, "memory-budget-verifier"))
        verification.delete("output")
        verified = File.file?(verified_path) ? JSON.parse(File.read(verified_path)) : nil
        has_verified_pass = verified && verified.fetch("list_of_errors").empty? && verified.fetch("list_of_verdicts").size == required_scenarios.size && verified.fetch("list_of_verdicts").all? { |verdict| verdict.fetch("verdict_status") == "passed" && verdict.fetch("list_of_violations").empty? }
        passed &&= verification.fetch("exit_status") == 0 && !verification.fetch("timed_out") && has_verified_pass
        result["verification"] = verification
        list_of_errors << "Common typed verifier rejected baseline evidence" unless verification.fetch("exit_status") == 0 && has_verified_pass
      end
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError => error
      list_of_errors << "Invalid #{label} observations: #{error.message}"
      passed = false
    end
    has_passed &&= !!passed
    list_of_runs << result.merge("label" => label, "accepted" => !!passed, "observations" => observations)
  end
end
source_sha256_after = source_tree_sha256
policy_sha256_after = Digest::SHA256.file(policy_path).hexdigest
list_of_errors << "Source or dependency files changed during the budget run" unless source_sha256_after == source_sha256
list_of_errors << "Memory policy changed during the budget run" unless policy_sha256_after == policy_sha256
list_of_errors << "Spec executable changed during the budget run" unless !spec_executable_sha256 || Digest::SHA256.file(spec_binary).hexdigest == spec_executable_sha256
list_of_errors << "Common verifier executable changed during the budget run" unless !checker_sha256 || Digest::SHA256.file(checker_binary).hexdigest == checker_sha256
has_passed &&= list_of_errors.empty?
warn list_of_errors.join("; ") unless list_of_errors.empty?
report = {"schema_version" => 2, "source_commit" => source_commit.strip, "source_tree_sha256" => source_sha256,
          "source_tree_sha256_after" => source_sha256_after, "policy_sha256" => policy_sha256,
          "bundle_manifest_sha256" => Digest::SHA256.file(manifest_path).hexdigest,
          "spec_executable_sha256" => spec_executable_sha256, "checker_sha256" => checker_sha256,
          "compiler_profile_sha256" => compiler_profile_sha256, "instrumentation_mode" => "fiber_allocation_tally/protocol-1",
          "list_of_builds" => list_of_builds, "list_of_runs" => list_of_runs, "list_of_errors" => list_of_errors, "passed" => !!has_passed}
File.write(File.join(results_root, "memory-budget-report.json"), JSON.pretty_generate(report) + "\n")
exit(has_passed ? 0 : 2)
