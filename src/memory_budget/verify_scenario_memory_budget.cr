module MemoryBudget
  # Verifies declared scope and coverage before enforcing numerical limits.
  class VerifyScenarioMemoryBudget
    def initialize(@policy : ScenarioMemoryPolicy,
                   @list_of_measurements : Array(ObservedMemoryMeasurement),
                   @list_of_capabilities : Array(AvailableMemoryCapability))
      @list_of_violations = [] of String
      @verdict_status = "passed"
    end

    # Performs policy, coverage, and capability validation before comparison.
    def perform : MemoryBudgetVerdict
      validate_policy_definition
      validate_measurement_coverage
      validate_required_capabilities
      compare_measurements_with_policy
      MemoryBudgetVerdict.new(@policy.scenario_name, @verdict_status, @list_of_measurements, @list_of_violations)
    end

    private def validate_policy_definition : Nil
      @list_of_violations.concat(@policy.validate_policy)
      @verdict_status = "invalid" unless @list_of_violations.empty?
    end

    private def validate_measurement_coverage : Nil
      return unless @verdict_status == "passed"
      list_of_metric_names = @list_of_measurements.map(&.metric_name)
      list_of_required_metrics = @policy.list_of_limits.map(&.metric_name)
      if list_of_metric_names.sort != list_of_required_metrics.sort
        @list_of_violations << "Measurements must contain every declared metric exactly once"
      end
      @list_of_measurements.each do |measurement|
        @list_of_violations << "#{measurement.metric_name}: scenario or scope mismatch" unless measurement.scenario_name == @policy.scenario_name && measurement.measurement_scope == @policy.measurement_scope
        @list_of_violations << "#{measurement.metric_name}: incomplete instrumentation coverage" unless measurement.has_complete_coverage?
        @list_of_violations << "#{measurement.metric_name}: platform mismatch" unless @policy.platform_profile == "any" || measurement.platform_profile == @policy.platform_profile
      end
      @verdict_status = "invalid" unless @list_of_violations.empty?
    end

    private def validate_required_capabilities : Nil
      return unless @verdict_status == "passed"
      @list_of_measurements.each do |measurement|
        list_of_matches = @list_of_capabilities.select do |capability|
          capability.metric_name == measurement.metric_name &&
            capability.measurement_scope == measurement.measurement_scope &&
            capability.backend_revision == measurement.backend_revision &&
            capability.platform_profile == measurement.platform_profile &&
            !capability.backend_name.empty?
        end
        @list_of_violations << "#{measurement.metric_name}: required capability unavailable or ambiguous" unless list_of_matches.size == 1
      end
      @verdict_status = "unsupported" unless @list_of_violations.empty?
    end

    private def compare_measurements_with_policy : Nil
      return unless @verdict_status == "passed"
      @policy.list_of_limits.each do |limit|
        measurement = @list_of_measurements.find { |observed| observed.metric_name == limit.metric_name }
        next unless measurement
        maximum = limit.allowed_value(@policy.item_count)
        if measurement.measured_value > maximum
          @list_of_violations << "#{limit.metric_name}: #{measurement.measured_value} > #{maximum}"
        end
      end
      @verdict_status = "exceeded" unless @list_of_violations.empty?
    end
  end
end
