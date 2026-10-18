module MemoryBudget
  # Measures Crystal allocator traffic using the maintained stdlib capability.
  struct AllocationMemorySnapshot
    getter allocation_calls : UInt64
    getter requested_bytes : UInt64

    def initialize(@allocation_calls : UInt64, @requested_bytes : UInt64)
    end

    # Measures the calling fiber; work delegated to other fibers has its own owner.
    def self.measure_fiber_allocations(&) : AllocationMemorySnapshot
      {% if Fiber.has_constant?("AllocationTally") && Fiber::AllocationTally.has_constant?("API_VERSION") %}
        raise MemoryBudgetError.new("Unsupported Crystal allocation protocol") unless Fiber::AllocationTally::API_VERSION == 1
        fiber = Fiber.current
        previous_tally = fiber.allocation_tally
        yield
        current_tally = fiber.allocation_tally - previous_tally
        new(current_tally.calls, current_tally.requested_bytes)
      {% else %}
        raise MemoryBudgetError.new("Crystal allocation capability unavailable; use the verified runtime with -Dfiber_allocation_tally")
      {% end %}
    end

    # Measures all Crystal work in an isolated, joined process window.
    def self.measure_process_allocations(&) : AllocationMemorySnapshot
      {% if Fiber.has_constant?("AllocationTally") && Fiber::AllocationTally.has_constant?("API_VERSION") %}
        raise MemoryBudgetError.new("Unsupported Crystal allocation protocol") unless Fiber::AllocationTally::API_VERSION == 1
        previous_tally = Fiber::AllocationTally.process_total
        yield
        current_tally = Fiber::AllocationTally.process_total - previous_tally
        new(current_tally.calls, current_tally.requested_bytes)
      {% else %}
        raise MemoryBudgetError.new("Crystal process allocation capability unavailable; use the verified runtime with -Dfiber_allocation_tally")
      {% end %}
    end

    # Converts the selected counters into policy-scoped observations.
    def observations_for(policy : ScenarioMemoryPolicy) : Array(ObservedMemoryMeasurement)
      policy.list_of_limits.map do |limit|
        measured_value = case limit.metric_name
                         when "crystal_allocation_calls" then @allocation_calls
                         when "crystal_requested_bytes"  then @requested_bytes
                         else
                           raise MemoryBudgetError.new("Allocation backend does not measure #{limit.metric_name}")
                         end
        ObservedMemoryMeasurement.new(policy.scenario_name, limit.metric_name, policy.measurement_scope, measured_value)
      end
    end

    # Declares the scopes actually implemented by the selected stdlib build.
    def self.available_capabilities : Array(AvailableMemoryCapability)
      list_of_capabilities = [] of AvailableMemoryCapability
      {% if Fiber.has_constant?("AllocationTally") && Fiber::AllocationTally.has_constant?("API_VERSION") %}
        return list_of_capabilities unless Fiber::AllocationTally::API_VERSION == 1
        {"fiber", "joined_process"}.each do |scope|
          {"crystal_allocation_calls", "crystal_requested_bytes"}.each do |metric|
            list_of_capabilities << AvailableMemoryCapability.new(metric, scope, "crystal_stdlib_allocation_tally", "1")
          end
        end
      {% end %}
      list_of_capabilities
    end
  end
end
