require "spec"
require "../memory_budget"
require "./allocation_memory_snapshot"

module MemoryBudget
  # Adds the same policy enforcement used by the CI command to Crystal specs.
  module SpecExpectations
    # Measures a block under a named typed policy and fails the current example on any invalid verdict.
    def within_memory_budget(policy : ScenarioMemoryPolicy, &) : MemoryBudgetVerdict
      snapshot = case policy.measurement_scope
                 when "fiber"
                   AllocationMemorySnapshot.measure_fiber_allocations { yield }
                 when "joined_process"
                   AllocationMemorySnapshot.measure_process_allocations { yield }
                 else
                   raise MemoryBudgetError.new("Spec block scope must be fiber or joined_process")
                 end
      verdict = VerifyScenarioMemoryBudget.new(policy, snapshot.observations_for(policy), AllocationMemorySnapshot.available_capabilities).perform
      fail "#{policy.scenario_name}: #{verdict.verdict_status}: #{verdict.list_of_violations.join("; ")}" unless verdict.passed?
      verdict
    end

    # Selects a named policy from the app-owned contract before running its block.
    def within_memory_budget(scenario_name : String, *, contract : ScenarioMemoryContract, &) : MemoryBudgetVerdict
      within_memory_budget(contract.policy_for(scenario_name)) { yield }
    end

    # Preserves the proven allocation helper while using the common checker.
    def within_allocation_budget(scenario_name : String, *, calls : Int, bytes : Int, warm_up_runs : Int32 = 0, &) : MemoryBudgetVerdict
      warm_up_runs.times { yield }
      policy = ScenarioMemoryPolicy.new(scenario_name, "fiber", [MemoryMetricLimit.new("crystal_allocation_calls", calls.to_u64), MemoryMetricLimit.new("crystal_requested_bytes", bytes.to_u64)])
      within_memory_budget(policy) { yield }
    end

    # Budgets a process operation whose workers finish inside the block.
    def within_process_allocation_budget(scenario_name : String, *, calls : Int, bytes : Int, &) : MemoryBudgetVerdict
      policy = ScenarioMemoryPolicy.new(scenario_name, "joined_process", [MemoryMetricLimit.new("crystal_allocation_calls", calls.to_u64), MemoryMetricLimit.new("crystal_requested_bytes", bytes.to_u64)])
      within_memory_budget(policy) { yield }
    end

    # Checks declared input sizes against checked fixed-plus-per-item limits.
    def within_allocation_budget_per_item(scenario_name : String, *, list_of_item_counts : Enumerable(Int32),
                                          fixed_calls : Int, calls_per_item : Int, fixed_bytes : Int, bytes_per_item : Int,
                                          & : Int32 ->) : Nil
      has_measured_input = false
      list_of_item_counts.each do |count|
        has_measured_input = true
        list_of_limits = [MemoryMetricLimit.new("crystal_allocation_calls", fixed_calls.to_u64, calls_per_item.to_u64), MemoryMetricLimit.new("crystal_requested_bytes", fixed_bytes.to_u64, bytes_per_item.to_u64)]
        policy = ScenarioMemoryPolicy.new(scenario_name, "fiber", list_of_limits, count.to_u64)
        within_memory_budget(policy) { yield count }
      end
      raise MemoryBudgetError.new("At least one input size is required") unless has_measured_input
    end
  end
end

include MemoryBudget::SpecExpectations
