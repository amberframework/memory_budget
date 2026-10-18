require "../src/memory_budget/spec_expectations"

# The collection keeps allocations observable under release optimization.
class MemoryBudgetSampleRecord
  getter record_number : Int32

  def initialize(@record_number : Int32)
  end
end

list_of_records = Array(MemoryBudgetSampleRecord).new(100)
policy = MemoryBudget::ScenarioMemoryPolicy.new("build_record", "fiber", [MemoryBudget::MemoryMetricLimit.new("crystal_allocation_calls", 1_u64), MemoryBudget::MemoryMetricLimit.new("crystal_requested_bytes", instance_sizeof(MemoryBudgetSampleRecord).to_u64)])
within_memory_budget(policy) { list_of_records << MemoryBudgetSampleRecord.new(1) }
within_allocation_budget_per_item("build_records", item_counts: [1, 10, 50], fixed_calls: 0, calls_per_item: 1,
  fixed_bytes: 0, bytes_per_item: instance_sizeof(MemoryBudgetSampleRecord)) do |count|
  list_of_records.clear
  count.times { |index| list_of_records << MemoryBudgetSampleRecord.new(index) }
end
raise "Record construction changed" unless list_of_records.size == 50
STDOUT.puts "PASS: one allocation per record at 1, 10, and 50 records"
