module MemoryBudget
  # Carries one observation with its scope, backend identity, and coverage status.
  struct ObservedMemoryMeasurement
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter scenario_name : String = ""
    getter metric_name : String = ""
    getter measurement_scope : String = ""
    getter measured_value : UInt64
    getter? has_complete_coverage : Bool = false
    getter backend_revision : String = "1"
    getter platform_profile : String = "any"

    def initialize(@scenario_name : String = "", @metric_name : String = "", @measurement_scope : String = "",
                   @measured_value : UInt64 = 0_u64, @has_complete_coverage : Bool = true,
                   @backend_revision : String = "1", @platform_profile : String = "any")
    end
  end
end
