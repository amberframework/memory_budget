module MemoryBudget
  # Reads the required coverage subset of the versioned Atlas instrument envelope.
  # Remaining instrument fields describe diagnostics and stay outside this value.
  struct CAllocationCoverage
    include JSON::Serializable

    getter? thread_sum_matches_totals : Bool
    getter? live_map_enabled : Bool
    getter thread_overflow_events : UInt64
    getter site_overflow_events : UInt64
    getter fiber_overflow_events : UInt64
    getter live_insert_overflows : UInt64
    getter live_missing_on_release : UInt64
    getter walk_limit_events : UInt64

    # Refuses a counter with dropped events before any numerical budget comparison.
    def validate_coverage : Nil
      list_of_losses = [@thread_overflow_events, @site_overflow_events, @fiber_overflow_events,
                        @live_insert_overflows, @live_missing_on_release, @walk_limit_events]
      unless @thread_sum_matches_totals && @live_map_enabled && list_of_losses.all?(&.zero?)
        raise MemoryBudgetError.new("C allocation instrument has incomplete coverage or inconsistent thread totals")
      end
    end
  end
end
