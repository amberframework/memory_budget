#!/usr/bin/env ruby
# frozen_string_literal: true
require "digest"
require "json"
require "open3"
require "fileutils"
require "timeout"

project_root = File.expand_path("..", __dir__)
Dir.chdir(project_root)
bundle_root = File.join(project_root, "performance", "vendor", "memory_budget")
manifest = JSON.parse(File.read(File.join(bundle_root, "PACKAGE_PINS.json")))
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
abort "A nonempty unique scenario roster is required" unless !required_scenarios.empty? && required_scenarios.uniq == required_scenarios
abort "Policy roster differs" unless contract.fetch("list_of_policies").map { |policy| policy.fetch("scenario_name") }.sort == required_scenarios.sort
def source_tree_sha256
  Digest::SHA256.hexdigest(Dir.glob("{src,spec,config,performance}/**/*").select { |path| File.file?(path) && !path.start_with?("performance/results/") }.sort.map { |path| "#{Digest::SHA256.file(path).hexdigest}  #{path}\n" }.join)
end
source_sha256 = source_tree_sha256
results_root = File.join(project_root, "performance", "results")
FileUtils.mkdir_p(results_root)
source_commit, _error, source_status = Open3.capture3("git", "rev-parse", "HEAD")
abort "Cannot identify source commit" unless source_status.success?
command = [RbConfig.ruby, File.join(bundle_root, "scripts", "budget.rb"), "spec", "spec/performance/memory_budget_spec.cr", "-Dfiber_allocation_tally", "-Dwithout_mt"]
list_of_runs = []
has_passed = true
[{"label" => "baseline", "injected" => false}, {"label" => "sensitivity", "injected" => true}].each do |run|
  next if run.fetch("injected") && !ARGV.include?("--self-test")
  stdout_path = File.join(results_root, "memory-budget-#{run.fetch('label')}.stdout.txt")
  stderr_path = File.join(results_root, "memory-budget-#{run.fetch('label')}.stderr.txt")
  environment = {"MEMORY_BUDGET_PROJECT_ROOT" => project_root, "MEMORY_BUDGET_INJECT_REGRESSION" => run.fetch("injected") ? "1" : "0"}
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
  expected_failure = run.fetch("injected")
  passed = !has_timed_out && (expected_failure ? (process_status && !process_status.success? && output.include?("exceeded")) : (process_status && process_status.success? && output.include?("0 failures, 0 errors")))
  observations = output.lines.select { |line| line.include?("MEMORY_BUDGET_OBSERVATION_JSON=") }.map { |line| JSON.parse(line.split("MEMORY_BUDGET_OBSERVATION_JSON=", 2).last) }
  unless expected_failure
    passed &&= observations.map { |verdict| verdict.fetch("scenario_name") }.sort == required_scenarios.sort
    observations.each do |verdict|
      passed &&= verdict.fetch("verdict_status") == "passed" && verdict.fetch("list_of_violations").empty?
      policy = contract.fetch("list_of_policies").find { |candidate| candidate.fetch("scenario_name") == verdict.fetch("scenario_name") }
      measurements = verdict.fetch("list_of_measurements")
      passed &&= policy && measurements.map { |measurement| measurement.fetch("metric_name") }.sort == policy.fetch("list_of_limits").map { |limit| limit.fetch("metric_name") }.sort
      measurements.each do |measurement|
        passed &&= measurement.fetch("has_complete_coverage") && measurement.fetch("scenario_name") == verdict.fetch("scenario_name") && policy && measurement.fetch("measurement_scope") == policy.fetch("measurement_scope")
      end
    end
  end
  has_passed &&= !!passed
  list_of_runs << {"label" => run.fetch("label"), "exit_status" => process_status && process_status.exitstatus, "timed_out" => has_timed_out, "accepted" => !!passed, "observations" => observations, "stdout" => File.basename(stdout_path), "stderr" => File.basename(stderr_path)}
  puts output
end
has_passed &&= source_tree_sha256 == source_sha256 && Digest::SHA256.file(policy_path).hexdigest == policy_sha256
report = {"schema_version" => 1, "source_commit" => source_commit.strip, "source_tree_sha256" => source_sha256, "policy_sha256" => policy_sha256, "bundle_manifest_sha256" => Digest::SHA256.file(File.join(bundle_root, "PACKAGE_PINS.json")).hexdigest, "list_of_runs" => list_of_runs, "passed" => has_passed}
File.write(File.join(results_root, "memory-budget-report.json"), JSON.pretty_generate(report) + "\n")
exit(has_passed ? 0 : 2)
