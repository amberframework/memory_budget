module MemoryBudget
  # Records enforcement separately from process completion and compilation.
  struct MemoryBudgetVerdict
    include JSON::Serializable

    getter scenario_name : String
    getter verdict_status : String
    getter list_of_measurements : Array(ObservedMemoryMeasurement)
    getter list_of_violations : Array(String)

    def initialize(@scenario_name : String, @verdict_status : String,
                   @list_of_measurements : Array(ObservedMemoryMeasurement) = [] of ObservedMemoryMeasurement,
                   @list_of_violations : Array(String) = [] of String)
    end

    # Returns true only for a valid, supported, enforced pass.
    def passed? : Bool
      @verdict_status == "passed"
    end
  end
end
