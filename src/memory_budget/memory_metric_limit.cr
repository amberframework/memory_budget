module MemoryBudget
  # Declares an absolute or fixed-plus-per-item maximum, in the metric's units.
  struct MemoryMetricLimit
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter metric_name : String = ""
    getter fixed_limit : UInt64
    getter per_item_limit : UInt64 = 0_u64

    def initialize(@metric_name : String = "", @fixed_limit : UInt64 = 0_u64, @per_item_limit : UInt64 = 0_u64)
    end

    # Computes the maximum with checked unsigned arithmetic.
    def allowed_value(item_count : UInt64) : UInt64
      @fixed_limit + @per_item_limit * item_count
    end
  end
end
