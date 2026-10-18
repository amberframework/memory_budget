# The collection keeps allocations observable under release optimization.
class MemoryBudgetSampleRecord
  getter record_number : Int32

  def initialize(@record_number : Int32)
  end
end
