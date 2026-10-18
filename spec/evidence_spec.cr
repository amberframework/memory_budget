require "./spec_helper"
require "../src/memory_budget/verify_memory_contract_evidence"

describe MemoryBudget::VerifyMemoryContractEvidence do
  describe "#perform" do
    it "enforces the exact document and rejects missing and undeclared scenario evidence" do
      policy = MemoryBudget::ScenarioMemoryPolicy.new("render", "fiber", [MemoryBudget::MemoryMetricLimit.new("crystal_requested_bytes", 10_u64)])
      content = MemoryBudget::ScenarioMemoryContract.new([policy], ["render"]).to_json
      capability = MemoryBudget::AvailableMemoryCapability.new("crystal_requested_bytes", "fiber", "tested_backend", "1")
      measurement = MemoryBudget::ObservedMemoryMeasurement.new("render", "crystal_requested_bytes", "fiber", 10_u64)
      {"complete", "missing", "extra", "different_policy"}.each do |variant|
        list_of_measurements = variant == "missing" ? [] of MemoryBudget::ObservedMemoryMeasurement : [measurement]
        list_of_measurements << MemoryBudget::ObservedMemoryMeasurement.new("invented", "crystal_requested_bytes", "fiber", 1_u64) if variant == "extra"
        policy_hash = variant == "different_policy" ? "0" * 64 : Digest::SHA256.hexdigest(content)
        evidence = MemoryBudget::ScenarioMemoryEvidence.new("example_run", "a" * 40, "b" * 64, policy_hash,
          "crystal-alpha 1.21.0", "allocation_protocol_1", list_of_measurements, [capability])
        report = MemoryBudget::VerifyMemoryContractEvidence.new(content, evidence).perform
        report.passed?.should eq(variant == "complete")
      end
    end
  end
end
