require "./spec_helper"
require "../src/memory_budget/read_c_allocation_evidence"

private def c_fixture(filename : String) : String
  File.read(File.join(__DIR__, "fixtures", "c", filename))
end

describe MemoryBudget::ReadCAllocationEvidence do
  describe "#read_window_observations" do
    it "enforces calls and requested bytes across all 21 recorded windows" do
      coverage = MemoryBudget::CAllocationCoverage.from_json(c_fixture("labels_released_10_run1.checkpoint.json"))
      reader = MemoryBudget::ReadCAllocationEvidence.new(c_fixture("labels_released_10_run1.tsv"), coverage)
      {640_u64, 639_u64}.each do |maximum|
        policy = MemoryBudget::ScenarioMemoryPolicy.new("c_labels", "c_window", [MemoryBudget::MemoryMetricLimit.new("c_requested_bytes", maximum), MemoryBudget::MemoryMetricLimit.new("c_allocation_calls", 10_u64)])
        verdict = MemoryBudget::VerifyScenarioMemoryBudget.new(policy, reader.read_window_observations(policy), MemoryBudget::ReadCAllocationEvidence.available_capabilities).perform
        verdict.passed?.should eq(maximum == 640_u64)
      end
      policy = MemoryBudget::ScenarioMemoryPolicy.new("c_labels", "c_window", [MemoryBudget::MemoryMetricLimit.new("c_allocation_calls", 9_u64)])
      MemoryBudget::VerifyScenarioMemoryBudget.new(policy, reader.read_window_observations(policy), MemoryBudget::ReadCAllocationEvidence.available_capabilities).perform.verdict_status.should eq("exceeded")
    end

    it "refuses every reported form of instrument coverage loss" do
      raw = c_fixture("labels_released_10_run1.checkpoint.json")
      {"thread_overflow_events", "site_overflow_events", "fiber_overflow_events", "live_insert_overflows", "live_missing_on_release", "walk_limit_events"}.each do |field|
        changed = raw.sub("\"#{field}\": 0", "\"#{field}\": 21")
        changed.should_not eq(raw)
        expect_raises(MemoryBudget::MemoryBudgetError, "incomplete coverage") do
          MemoryBudget::ReadCAllocationEvidence.new(c_fixture("labels_released_10_run1.tsv"), MemoryBudget::CAllocationCoverage.from_json(changed))
        end
      end
    end

    it "refuses a missing window instead of taking the remaining maximum" do
      coverage = MemoryBudget::CAllocationCoverage.from_json(c_fixture("labels_released_10_run1.checkpoint.json"))
      truncated = c_fixture("labels_released_10_run1.tsv").lines.reject(&.includes?("\t20\tthread\t")).join("\n")
      reader = MemoryBudget::ReadCAllocationEvidence.new(truncated, coverage)
      policy = MemoryBudget::ScenarioMemoryPolicy.new("c_labels", "c_window", [MemoryBudget::MemoryMetricLimit.new("c_requested_bytes", 100_000_u64)])
      expect_raises(MemoryBudget::MemoryBudgetError, "Missing or duplicated") { reader.read_window_observations(policy) }
    end
  end

  describe "#read_owned_site_observations" do
    it "attributes all 21 optimized releases to their allocation source" do
      coverage = MemoryBudget::CAllocationCoverage.from_json(c_fixture("corefoundation_string_released_1_run1.checkpoint.json"))
      reader = MemoryBudget::ReadCAllocationEvidence.new(c_fixture("corefoundation_string_released_1_run1.symbolized.tsv"), coverage)
      policy = MemoryBudget::ScenarioMemoryPolicy.new("cf_string", "c_allocation_owner", [MemoryBudget::MemoryMetricLimit.new("c_requested_bytes", 1680_u64), MemoryBudget::MemoryMetricLimit.new("c_owned_live_bytes", 0_u64)])
      observations = reader.read_owned_site_observations(policy, "cases.cr:98", 21_u64)
      MemoryBudget::VerifyScenarioMemoryBudget.new(policy, observations, MemoryBudget::ReadCAllocationEvidence.available_capabilities).perform.passed?.should be_true
      expect_raises(MemoryBudget::MemoryBudgetError, "Missing allocation-owner") { reader.read_owned_site_observations(policy, "missing.cr:999", 21_u64) }
      expect_raises(MemoryBudget::MemoryBudgetError, "coverage mismatch") { reader.read_owned_site_observations(policy, "cases.cr:98", 22_u64) }
    end

    it "advertises its proven allocation-owner scope" do
      MemoryBudget::ReadCAllocationEvidence.available_capabilities.any? { |capability| capability.measurement_scope == "c_allocation_owner" }.should be_true
      MemoryBudget::ReadCAllocationEvidence.available_capabilities.any? { |capability| capability.measurement_scope == "c_free_call_site" }.should be_false
    end
  end
end
