module MemoryBudget
  # Defines a versioned, exact roster of required memory scenarios.
  struct ScenarioMemoryContract
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter schema_version : Int32 = 2
    getter list_of_policies : Array(ScenarioMemoryPolicy) = [] of ScenarioMemoryPolicy
    getter list_of_required_scenarios : Array(String) = [] of String

    def initialize(@list_of_policies : Array(ScenarioMemoryPolicy) = [] of ScenarioMemoryPolicy,
                   @list_of_required_scenarios : Array(String) = [] of String, @schema_version : Int32 = 2)
    end

    # Rejects absent, duplicated, and unsupported policies before execution.
    def validate_contract : Array(String)
      list_of_errors = [] of String
      list_of_errors << "Unsupported memory contract schema_version #{@schema_version}" unless @schema_version == 2
      list_of_names = @list_of_policies.map(&.scenario_name)
      list_of_errors << "Every required scenario must appear exactly once" if @list_of_required_scenarios.empty? || @list_of_required_scenarios.uniq.size != @list_of_required_scenarios.size || list_of_names.uniq.size != list_of_names.size || list_of_names.sort != @list_of_required_scenarios.sort
      @list_of_policies.each do |policy|
        list_of_errors.concat(policy.validate_policy.map { |message| "#{policy.scenario_name}: #{message}" })
      end
      list_of_errors
    end

    # Returns a named policy after the complete contract has been validated.
    def policy_for(scenario_name : String) : ScenarioMemoryPolicy
      list_of_errors = validate_contract
      raise MemoryBudgetError.new(list_of_errors.join("; ")) unless list_of_errors.empty?
      @list_of_policies.find { |policy| policy.scenario_name == scenario_name } || raise MemoryBudgetError.new("Missing policy #{scenario_name}")
    end
  end
end
