require "./spec_helper"
include MemoryBudgetSpecSupport

describe MemoryBudget::VerifyScenarioMemoryBudget do
  describe "#perform" do
    it "accepts sufficient and exactly equal byte limits" do
      memory_verdict.passed?.should be_true
      memory_verdict(observations: [memory_observation(64_u64)]).passed?.should be_true
    end

    it "rejects an independently tightened limit" do
      verdict = memory_verdict(policy: memory_policy(31_u64))
      verdict.verdict_status.should eq("exceeded")
      verdict.list_of_violations.join.should contain("32 > 31")
    end

    it "permits an explicitly enforced zero-allocation budget" do
      memory_verdict(policy: memory_policy(0_u64), observations: [memory_observation(0_u64)]).passed?.should be_true
      memory_verdict(policy: memory_policy(0_u64)).verdict_status.should eq("exceeded")
    end

    it "computes fixed plus per-item limits" do
      policy = memory_policy(2_u64, 3_u64, 10_u64)
      memory_verdict(policy: policy).passed?.should be_true
      memory_verdict(policy: policy, observations: [memory_observation(33_u64)]).verdict_status.should eq("exceeded")
    end

    it "rejects arithmetic overflow instead of accepting a wrapped limit" do
      memory_verdict(policy: memory_policy(UInt64::MAX, 2_u64, 10_u64)).verdict_status.should eq("invalid")
    end

    it "requires every observation and capability" do
      memory_verdict(observations: [] of MemoryBudget::ObservedMemoryMeasurement).verdict_status.should eq("invalid")
      memory_verdict(capabilities: [] of MemoryBudget::AvailableMemoryCapability).verdict_status.should eq("unsupported")
    end

    it "rejects duplicated observations" do
      memory_verdict(observations: [memory_observation, memory_observation]).verdict_status.should eq("invalid")
    end

    it "rejects duplicated metric limits" do
      policy = memory_policy
      policy.list_of_limits << policy.list_of_limits.first
      memory_verdict(policy: policy).verdict_status.should eq("invalid")
    end

    it "rejects missing coverage before checking the generous byte limit" do
      memory_verdict(observations: [memory_observation(0_u64, complete: false)]).verdict_status.should eq("invalid")
    end

    it "rejects a measurement with a different scope" do
      memory_verdict(observations: [memory_observation(scope: "process")]).verdict_status.should eq("invalid")
    end

    it "rejects a measurement for a different scenario" do
      observation = MemoryBudget::ObservedMemoryMeasurement.new("other", "crystal_requested_bytes", "fiber", 0_u64)
      memory_verdict(observations: [observation]).verdict_status.should eq("invalid")
    end

    it "rejects undeclared and unmeasured metric names" do
      observation = MemoryBudget::ObservedMemoryMeasurement.new("render_records", "unknown_metric", "fiber", 0_u64)
      memory_verdict(observations: [observation]).verdict_status.should eq("invalid")
    end

    it "requires a named scenario, scope, and at least one limit" do
      memory_verdict(policy: MemoryBudget::ScenarioMemoryPolicy.new).verdict_status.should eq("invalid")
    end
  end
end

describe MemoryBudget::ScenarioMemoryContract do
  describe "#validate_contract" do
    it "requires the exact scenario roster" do
      contract = MemoryBudget::ScenarioMemoryContract.new([memory_policy], ["render_records"])
      contract.validate_contract.should be_empty
      MemoryBudget::ScenarioMemoryContract.new([memory_policy], ["missing"]).validate_contract.should_not be_empty
      MemoryBudget::ScenarioMemoryContract.new([memory_policy], ["render_records", "render_records"]).validate_contract.should_not be_empty
      MemoryBudget::ScenarioMemoryContract.new.validate_contract.should_not be_empty
    end

    it "round trips typed JSON and rejects unknown schema versions" do
      contract = MemoryBudget::ScenarioMemoryContract.new([memory_policy], ["render_records"])
      MemoryBudget::ScenarioMemoryContract.from_json(contract.to_json).validate_contract.should be_empty
      MemoryBudget::ScenarioMemoryContract.new([memory_policy], ["render_records"], 99).validate_contract.should_not be_empty
    end

    it "rejects misspelled fields and absent numeric observations" do
      expect_raises(JSON::ParseException) do
        MemoryBudget::MemoryMetricLimit.from_json(%({"metric_name":"crystal_requested_bytes","fixed_limt":64}))
      end
      expect_raises(JSON::ParseException) do
        MemoryBudget::ObservedMemoryMeasurement.from_json(%({"scenario_name":"render_records","metric_name":"crystal_requested_bytes","measurement_scope":"fiber","has_complete_coverage":true}))
      end
    end
  end
end
