require "../../../src/memory_budget/spec_expectations"
require "../../../examples/support/memory_budget_sample_record"

describe "A record construction memory expectation" do
  it "preserves the record and rejects an actual allocation regression" do
    list_of_records = Array(MemoryBudgetSampleRecord).new(1)
    list_of_extra_buffers = Array(Bytes).new(1)
    should_inject_regression = ENV["MEMORY_BUDGET_INJECT_REGRESSION"]? == "1"
    list_of_limits = [
      MemoryBudget::MemoryMetricLimit.new("crystal_allocation_calls", 1_u64),
      MemoryBudget::MemoryMetricLimit.new("crystal_requested_bytes", instance_sizeof(MemoryBudgetSampleRecord).to_u64),
    ]
    policy = MemoryBudget::ScenarioMemoryPolicy.new("construct_record", "fiber", list_of_limits)

    begin
      verdict = within_memory_budget(policy) do
        list_of_records << MemoryBudgetSampleRecord.new(7)
        list_of_extra_buffers << Bytes.new(128, 1_u8) if should_inject_regression
      end
      STDOUT.puts "MEMORY_BUDGET_OBSERVATION_JSON=#{verdict.to_json}"
    ensure
      # These assertions run after the measurement window for both outcomes.
      list_of_records.size.should eq(1)
      list_of_records.first.record_number.should eq(7)
      list_of_extra_buffers.size.should eq(should_inject_regression ? 1 : 0)
    end
  end
end
