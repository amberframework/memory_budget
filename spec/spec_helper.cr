require "spec"
require "../src/memory_budget"

module MemoryBudgetSpecSupport
  def memory_policy(maximum : UInt64 = 64_u64, per_item : UInt64 = 0_u64, count : UInt64 = 1_u64)
    MemoryBudget::ScenarioMemoryPolicy.new(
      scenario_name: "render_records",
      measurement_scope: "fiber",
      item_count: count,
      list_of_limits: [MemoryBudget::MemoryMetricLimit.new("crystal_requested_bytes", maximum, per_item)]
    )
  end

  def memory_observation(value : UInt64 = 32_u64, scope : String = "fiber", complete : Bool = true)
    MemoryBudget::ObservedMemoryMeasurement.new(
      scenario_name: "render_records", metric_name: "crystal_requested_bytes",
      measurement_scope: scope, measured_value: value, has_complete_coverage: complete
    )
  end

  def memory_capability
    MemoryBudget::AvailableMemoryCapability.new("crystal_requested_bytes", "fiber", "test", "1")
  end

  def memory_verdict(policy = memory_policy, observations = [memory_observation], capabilities = [memory_capability])
    MemoryBudget::VerifyScenarioMemoryBudget.new(policy, observations, capabilities).perform
  end
end
