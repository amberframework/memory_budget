# The holder escapes each allocation so release optimization preserves the measured work.
class MemoryBudgetExampleHolder
  getter item_index : Int32

  def initialize(@item_index : Int32)
  end
end
