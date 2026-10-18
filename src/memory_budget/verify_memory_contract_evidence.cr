require "./scenario_memory_evidence"
require "./scenario_memory_report"

module MemoryBudget
  # Verifies one exact policy document and its typed execution receipt.
  class VerifyMemoryContractEvidence
    def initialize(@policy_content : String, @evidence : ScenarioMemoryEvidence)
    end

    # Checks policy identity and every required scenario with the common verifier.
    def perform : ScenarioMemoryReport
      contract = ScenarioMemoryContract.from_json(@policy_content)
      list_of_errors = contract.validate_contract + @evidence.validate_evidence(@policy_content)
      list_of_unknown_scenarios = @evidence.list_of_measurements.map(&.scenario_name).uniq! - contract.list_of_required_scenarios
      list_of_errors << "Evidence contains undeclared scenarios: #{list_of_unknown_scenarios.join(", ")}" unless list_of_unknown_scenarios.empty?
      list_of_verdicts = contract.list_of_policies.map do |policy|
        list_of_measurements = @evidence.list_of_measurements.select { |measurement| measurement.scenario_name == policy.scenario_name }
        VerifyScenarioMemoryBudget.new(policy, list_of_measurements, @evidence.list_of_capabilities).perform
      end
      ScenarioMemoryReport.new(@evidence.run_id, list_of_verdicts, list_of_errors)
    end
  end
end
