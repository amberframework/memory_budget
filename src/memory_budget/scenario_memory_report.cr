module MemoryBudget
  # Reports every required scenario, including invalid or missing evidence.
  struct ScenarioMemoryReport
    include JSON::Serializable

    getter schema_version : Int32 = 1
    getter run_id : String
    getter list_of_verdicts : Array(MemoryBudgetVerdict)
    getter list_of_errors : Array(String)

    def initialize(@run_id : String, @list_of_verdicts : Array(MemoryBudgetVerdict), @list_of_errors : Array(String) = [] of String)
    end

    # Accepts only complete, enforced results for every scenario.
    def passed? : Bool
      @list_of_errors.empty? && !@list_of_verdicts.empty? && @list_of_verdicts.all?(&.passed?)
    end
  end
end
