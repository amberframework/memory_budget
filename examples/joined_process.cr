require "../src/memory_budget"
require "../src/memory_budget/allocation_memory_snapshot"

maximum_bytes = ARGV.first?.try(&.to_u64) || 65_536_u64
list_of_results = Array(String).new(20)
snapshot = MemoryBudget::AllocationMemorySnapshot.measure_process_allocations do
  completed = Channel(Nil).new
  spawn do
    20.times { |index| list_of_results << "record_#{index}" }
    completed.send(nil)
  end
  completed.receive
end
raise "Joined-worker result changed" unless list_of_results.size == 20 && list_of_results.last == "record_19"
policy = MemoryBudget::ScenarioMemoryPolicy.new("joined_records", "joined_process", [MemoryBudget::MemoryMetricLimit.new("crystal_requested_bytes", maximum_bytes)])
verdict = MemoryBudget::VerifyScenarioMemoryBudget.new(policy, snapshot.observations_for(policy), MemoryBudget::AllocationMemorySnapshot.available_capabilities).perform
STDOUT.puts verdict.to_json
exit(verdict.passed? ? 0 : 2)
