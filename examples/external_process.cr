require "../src/memory_budget"
require "../src/memory_budget/process_memory_snapshot"

raise ArgumentError.new("Usage: external-process PID SCENARIO MAXIMUM_BYTES") unless ARGV.size == 3
process_id = ARGV[0].to_i64
scenario_name = ARGV[1]
maximum = ARGV[2].to_u64
metric_name = MemoryBudget::ProcessMemorySnapshot.metric_names[1]
policy = MemoryBudget::ScenarioMemoryPolicy.new(scenario_name, "process", [MemoryBudget::MemoryMetricLimit.new(metric_name, maximum)],
  platform_profile: MemoryBudget::ProcessMemorySnapshot.platform_profile, measurement_window: "live_process_lifetime")
snapshot = MemoryBudget::ProcessMemorySnapshot.read_process_memory_for(process_id)
verdict = MemoryBudget::VerifyScenarioMemoryBudget.new(policy, snapshot.observations_for(policy), MemoryBudget::ProcessMemorySnapshot.available_capabilities).perform
STDOUT.puts verdict.to_json
exit(verdict.passed? ? 0 : 2)
