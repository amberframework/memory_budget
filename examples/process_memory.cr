require "../src/memory_budget"
require "../src/memory_budget/process_memory_snapshot"

# The command boundary selects a product limit; 64 MiB is an example, not an app SLA.
maximum_bytes = ARGV.first?.try(&.to_u64) || 67_108_864_u64
allocation = Bytes.new(8 * 1024 * 1024, 1_u8)
allocation.each_index { |index| allocation[index] = 7_u8 }
raise "Touched-buffer correctness failed" unless allocation[4096] == 7_u8
metric_name = MemoryBudget::ProcessMemorySnapshot.metric_names[1]
policy = MemoryBudget::ScenarioMemoryPolicy.new("touched_buffer", "process", [MemoryBudget::MemoryMetricLimit.new(metric_name, maximum_bytes)],
  platform_profile: MemoryBudget::ProcessMemorySnapshot.platform_profile, cache_state: "cold", measurement_window: "fresh_process_lifetime")
snapshot = MemoryBudget::ProcessMemorySnapshot.read_process_memory
verdict = MemoryBudget::VerifyScenarioMemoryBudget.new(policy, snapshot.observations_for(policy), MemoryBudget::ProcessMemorySnapshot.available_capabilities).perform
STDOUT.puts verdict.to_json
exit(verdict.passed? ? 0 : 2)
