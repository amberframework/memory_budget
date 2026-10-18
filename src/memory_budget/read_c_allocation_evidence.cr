require "csv"
require "./c_allocation_coverage"

module MemoryBudget
  # Validates instrument coverage and exports only explicitly supported C metrics.
  class ReadCAllocationEvidence
    @list_of_headers : Array(String)
    @list_of_rows : Array(Array(String))

    def initialize(@tabular_content : String, @coverage : CAllocationCoverage)
      @coverage.validate_coverage
      list_of_rows = CSV.parse(@tabular_content.lines.reject(&.starts_with?('#')).join("\n"), separator: '\t')
      @list_of_headers = list_of_rows.shift? || raise MemoryBudgetError.new("Missing C allocation header")
      raise MemoryBudgetError.new("Duplicated C allocation header") unless @list_of_headers.uniq.size == @list_of_headers.size
      @list_of_rows = list_of_rows
      raise MemoryBudgetError.new("Missing C allocation rows") if @list_of_rows.empty?
      unless @list_of_rows.all? { |row| row.size == @list_of_headers.size }
        raise MemoryBudgetError.new("Incomplete C allocation row")
      end
    end

    # Returns maxima across the exact required thread-window roster.
    def read_window_observations(policy : ScenarioMemoryPolicy, expected_window_count : Int32 = 21) : Array(ObservedMemoryMeasurement)
      raise MemoryBudgetError.new("Expected window count must be positive") unless expected_window_count > 0
      list_of_windows = @list_of_rows.select { |row| field_value(row, "scope") == "thread" }
      list_of_window_numbers = list_of_windows.map { |row| field_value(row, "window").to_i }
      unless list_of_window_numbers.sort == (0...expected_window_count).to_a
        raise MemoryBudgetError.new("Missing or duplicated C allocation windows")
      end
      maximum_calls = list_of_windows.max_of { |row| allocation_calls(row) }
      maximum_bytes = list_of_windows.max_of { |row| unsigned_field(row, "requested_bytes") }
      build_observations(policy, "c_window", maximum_calls, maximum_bytes, 0_u64)
    end

    # Attributes releases to their allocation owner even when optimized free frames disappear.
    def read_owned_site_observations(policy : ScenarioMemoryPolicy, source_marker : String, expected_allocation_calls : UInt64) : Array(ObservedMemoryMeasurement)
      raise MemoryBudgetError.new("Allocation source marker must be nonempty") if source_marker.empty?
      list_of_matches = @list_of_rows.select { |row| field_value(row, "frames").includes?(source_marker) }
      raise MemoryBudgetError.new("Missing allocation-owner source") if list_of_matches.empty?
      actual_calls = list_of_matches.sum { |row| allocation_calls(row) }
      unless actual_calls == expected_allocation_calls
        raise MemoryBudgetError.new("Allocation-owner coverage mismatch: #{actual_calls} != #{expected_allocation_calls}")
      end
      requested_bytes = list_of_matches.sum { |row| unsigned_field(row, "requested_bytes") }
      allocated_bytes = list_of_matches.sum { |row| unsigned_field(row, "allocated_bytes") }
      released_bytes = list_of_matches.sum { |row| unsigned_field(row, "owned_freed_bytes") }
      raise MemoryBudgetError.new("Allocation-owner frees exceed owned allocations") if released_bytes > allocated_bytes
      build_observations(policy, "c_allocation_owner", actual_calls, requested_bytes, allocated_bytes - released_bytes)
    end

    # Declares supported attribution semantics rather than exact optimized free call sites.
    def self.available_capabilities : Array(AvailableMemoryCapability)
      list_of_capabilities = [] of AvailableMemoryCapability
      {"c_window", "c_allocation_owner"}.each do |scope|
        {"c_allocation_calls", "c_requested_bytes", "c_owned_live_bytes"}.each do |metric|
          next if scope == "c_window" && metric == "c_owned_live_bytes"
          list_of_capabilities << AvailableMemoryCapability.new(metric, scope, "atlas_c_instrument_v1", "1")
        end
      end
      list_of_capabilities
    end

    private def field_value(row : Array(String), field_name : String) : String
      index = @list_of_headers.index(field_name) || raise MemoryBudgetError.new("Missing C allocation field #{field_name}")
      row[index]
    end

    private def unsigned_field(row : Array(String), field_name : String) : UInt64
      field_value(row, field_name).to_u64
    rescue ArgumentError
      raise MemoryBudgetError.new("Invalid unsigned C allocation field #{field_name}")
    end

    private def allocation_calls(row : Array(String)) : UInt64
      {"malloc_calls", "calloc_calls", "realloc_calls", "aligned_calls"}.sum { |field| unsigned_field(row, field) }
    end

    private def build_observations(policy : ScenarioMemoryPolicy, scope : String, calls : UInt64, bytes : UInt64, live_bytes : UInt64) : Array(ObservedMemoryMeasurement)
      raise MemoryBudgetError.new("C allocation scope mismatch") unless policy.measurement_scope == scope
      policy.list_of_limits.map do |limit|
        measured_value = case limit.metric_name
                         when "c_allocation_calls" then calls
                         when "c_requested_bytes"  then bytes
                         when "c_owned_live_bytes"
                           raise MemoryBudgetError.new("Live bytes require allocation-owner coverage") unless scope == "c_allocation_owner"
                           live_bytes
                         else
                           raise MemoryBudgetError.new("C backend does not measure #{limit.metric_name}")
                         end
        ObservedMemoryMeasurement.new(policy.scenario_name, limit.metric_name, scope, measured_value)
      end
    end
  end
end
