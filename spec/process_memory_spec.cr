require "./spec_helper"
require "../src/memory_budget/process_memory_snapshot"

describe MemoryBudget::ProcessMemorySnapshot do
  describe ".read_process_memory" do
    it "observes a touched allocation and enforces a tight process maximum" do
      before = MemoryBudget::ProcessMemorySnapshot.read_process_memory
      allocation = Bytes.new(8 * 1024 * 1024, 0_u8)
      allocation.each_index { |index| allocation[index] = 7_u8 }
      during = MemoryBudget::ProcessMemorySnapshot.read_process_memory
      during.lifetime_peak_bytes.should be >= during.current_bytes
      during.current_bytes.should be > before.current_bytes + 4_u64 * 1024_u64 * 1024_u64
      allocation[0].should eq(7_u8)
      metric = MemoryBudget::ProcessMemorySnapshot.metric_names[0]
      policy = MemoryBudget::ScenarioMemoryPolicy.new("touched_buffer", "process", [MemoryBudget::MemoryMetricLimit.new(metric, 1_u64)],
        platform_profile: MemoryBudget::ProcessMemorySnapshot.platform_profile)
      verdict = MemoryBudget::VerifyScenarioMemoryBudget.new(policy, during.observations_for(policy), MemoryBudget::ProcessMemorySnapshot.available_capabilities).perform
      verdict.verdict_status.should eq("exceeded")
    end

    it "keeps lifetime peak monotonic across a later checkpoint" do
      first = MemoryBudget::ProcessMemorySnapshot.read_process_memory
      second = MemoryBudget::ProcessMemorySnapshot.read_process_memory
      second.lifetime_peak_bytes.should be >= first.lifetime_peak_bytes
    end

    it "reads its process through the external public backend" do
      snapshot = MemoryBudget::ProcessMemorySnapshot.read_process_memory_for(Process.pid.to_i64)
      snapshot.current_bytes.should be > 0_u64
      snapshot.lifetime_peak_bytes.should be >= snapshot.current_bytes
      expect_raises(MemoryBudget::MemoryBudgetError) { MemoryBudget::ProcessMemorySnapshot.read_process_memory_for(0_i64) }
      expect_raises(MemoryBudget::MemoryBudgetError) { MemoryBudget::ProcessMemorySnapshot.read_process_memory_for(Int32::MAX.to_i64) }
    end
  end
end
