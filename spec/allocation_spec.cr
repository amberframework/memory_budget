require "./spec_helper"
require "../src/memory_budget/spec_expectations"

# The holder escapes each allocation so release optimization preserves the measured work.
class MemoryBudgetExampleHolder
  getter item_index : Int32

  def initialize(@item_index : Int32)
  end
end

describe MemoryBudget::AllocationMemorySnapshot do
  if ENV["MEMORY_BUDGET_REQUIRE_ALLOCATION"]? == "1"
    it "requires the declared counter capability in an instrumented acceptance run" do
      MemoryBudget::AllocationMemorySnapshot.available_capabilities.size.should eq(4)
    end
  end
  {% if Fiber.has_constant?("AllocationTally") %}
    describe ".measure_fiber_allocations" do
      it "counts one escaping holder exactly" do
        holder = nil
        snapshot = MemoryBudget::AllocationMemorySnapshot.measure_fiber_allocations { holder = MemoryBudgetExampleHolder.new(42) }
        holder.should_not be_nil
        snapshot.allocation_calls.should eq(1_u64)
        snapshot.requested_bytes.should eq(instance_sizeof(MemoryBudgetExampleHolder).to_u64)
      end

      it "excludes a neighboring fiber and counts its own allocations across a yield" do
        done = Channel(Nil).new
        list_of_holders = [] of MemoryBudgetExampleHolder
        neighbor = spawn do
          30.times { |index| list_of_holders << MemoryBudgetExampleHolder.new(index) }
          done.send(nil)
        end
        holder = nil
        snapshot = MemoryBudget::AllocationMemorySnapshot.measure_fiber_allocations do
          done.receive
          holder = MemoryBudgetExampleHolder.new(99)
        end
        holder.should_not be_nil
        neighbor.allocation_tally.calls.should be >= 30_u64
        snapshot.allocation_calls.should eq(1_u64)
      end

      it "propagates the block's original exception" do
        expect_raises(ArgumentError, "example failure") do
          MemoryBudget::AllocationMemorySnapshot.measure_fiber_allocations { raise ArgumentError.new("example failure") }
        end
      end
    end

    describe ".measure_process_allocations" do
      it "includes a joined worker's escaping allocations" do
        list_of_holders = Array(MemoryBudgetExampleHolder).new(20)
        snapshot = MemoryBudget::AllocationMemorySnapshot.measure_process_allocations do
          done = Channel(Nil).new
          spawn do
            20.times { |index| list_of_holders << MemoryBudgetExampleHolder.new(index) }
            done.send(nil)
          end
          done.receive
        end
        list_of_holders.size.should eq(20)
        snapshot.allocation_calls.should be >= 20_u64
        snapshot.requested_bytes.should be >= 20_u64 * instance_sizeof(MemoryBudgetExampleHolder).to_u64
      end
    end

    describe "spec enforcement" do
      it "passes a real workload and rejects one extra allocation through the spec helper" do
        list_of_holders = Array(MemoryBudgetExampleHolder).new(2)
        within_allocation_budget("one_holder", calls: 1, bytes: instance_sizeof(MemoryBudgetExampleHolder)) do
          list_of_holders << MemoryBudgetExampleHolder.new(1)
        end
        expect_raises(Spec::AssertionFailed, "exceeded") do
          within_allocation_budget("one_holder", calls: 1, bytes: instance_sizeof(MemoryBudgetExampleHolder)) do
            list_of_holders << MemoryBudgetExampleHolder.new(2)
            list_of_holders << MemoryBudgetExampleHolder.new(3)
          end
        end
      end

      it "checks allocation growth at several declared input sizes" do
        list_of_holders = Array(MemoryBudgetExampleHolder).new(100)
        within_allocation_budget_per_item("holders", item_counts: [1, 10, 50], fixed_calls: 0, calls_per_item: 1,
          fixed_bytes: 0, bytes_per_item: instance_sizeof(MemoryBudgetExampleHolder)) do |count|
          list_of_holders.clear
          count.times { |index| list_of_holders << MemoryBudgetExampleHolder.new(index) }
        end
      end
    end
  {% else %}
    describe ".available_capabilities" do
      it "declares allocation metrics unavailable on a runtime without counters" do
        MemoryBudget::AllocationMemorySnapshot.available_capabilities.should be_empty
        expect_raises(MemoryBudget::MemoryBudgetError, "capability unavailable") do
          MemoryBudget::AllocationMemorySnapshot.measure_fiber_allocations { 1 + 1 }
        end
      end
    end
  {% end %}
end
