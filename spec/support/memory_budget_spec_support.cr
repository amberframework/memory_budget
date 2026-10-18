module MemoryBudgetSpecSupport
  def memory_policy(maximum : UInt64 = 64_u64, per_item : UInt64 = 0_u64, count : UInt64 = 1_u64) : MemoryBudget::ScenarioMemoryPolicy
    MemoryBudget::ScenarioMemoryPolicy.new(
      scenario_name: "render_records",
      measurement_scope: "fiber",
      item_count: count,
      list_of_limits: [MemoryBudget::MemoryMetricLimit.new("crystal_requested_bytes", maximum, per_item)]
    )
  end

  def memory_observation(value : UInt64 = 32_u64, scope : String = "fiber", has_complete_coverage : Bool = true) : MemoryBudget::ObservedMemoryMeasurement
    MemoryBudget::ObservedMemoryMeasurement.new(
      scenario_name: "render_records", metric_name: "crystal_requested_bytes",
      measurement_scope: scope, measured_value: value, has_complete_coverage: has_complete_coverage
    )
  end

  def memory_capability : MemoryBudget::AvailableMemoryCapability
    MemoryBudget::AvailableMemoryCapability.new("crystal_requested_bytes", "fiber", "test", "1")
  end

  def memory_verdict(policy : MemoryBudget::ScenarioMemoryPolicy = memory_policy, list_of_measurements : Array(MemoryBudget::ObservedMemoryMeasurement) = [memory_observation], list_of_capabilities : Array(MemoryBudget::AvailableMemoryCapability) = [memory_capability]) : MemoryBudget::MemoryBudgetVerdict
    MemoryBudget::VerifyScenarioMemoryBudget.new(policy, list_of_measurements, list_of_capabilities).perform
  end
end
