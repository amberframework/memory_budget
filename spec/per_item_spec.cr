require "./spec_helper"
require "../src/memory_budget/spec_expectations"

describe "Per-item memory budget enforcement" do
  it "rejects an empty set of declared input sizes" do
    expect_raises(MemoryBudget::MemoryBudgetError, "At least one input size is required") do
      within_allocation_budget_per_item("records", list_of_item_counts: [] of Int32,
        fixed_calls: 0, calls_per_item: 1, fixed_bytes: 0, bytes_per_item: 8) { |_count| nil }
    end
  end
end
