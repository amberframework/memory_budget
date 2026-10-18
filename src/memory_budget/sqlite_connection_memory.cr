@[Link("sqlite3")]
lib LibMemoryBudgetSQLite
  fun sqlite3_db_status(database : Void*, operation : Int32, current : Int32*, highwater : Int32*, reset : Int32) : Int32
  fun sqlite3_libversion : UInt8*
end

module MemoryBudget
  # Reads SQLite's connection cache rather than assuming its global accounting is enabled.
  struct SQLiteConnectionMemory
    def initialize(@connection_pointer : Void*)
      raise MemoryBudgetError.new("SQLite connection pointer must be open") if @connection_pointer.null?
    end

    # Returns the cache bytes currently owned by this connection.
    def read_cache_bytes : UInt64
      current = 0
      highwater = 0
      status = LibMemoryBudgetSQLite.sqlite3_db_status(@connection_pointer, 1, pointerof(current), pointerof(highwater), 0)
      raise MemoryBudgetError.new("SQLite connection cache counter failed: #{status}") unless status == 0 && current >= 0
      current.to_u64
    end

    # Declares the exact linked SQLite library identity.
    def self.available_capabilities : Array(AvailableMemoryCapability)
      library_version = String.new(LibMemoryBudgetSQLite.sqlite3_libversion)
      [AvailableMemoryCapability.new("sqlite_connection_cache_bytes", "sqlite_connection", "sqlite_#{library_version}", "1")]
    end

    # Records the current cache for a named connection-level operation.
    def observations_for(policy : ScenarioMemoryPolicy) : Array(ObservedMemoryMeasurement)
      unless policy.measurement_scope == "sqlite_connection" && policy.list_of_limits.map(&.metric_name) == ["sqlite_connection_cache_bytes"]
        raise MemoryBudgetError.new("SQLite backend requires one sqlite_connection_cache_bytes limit")
      end
      [ObservedMemoryMeasurement.new(policy.scenario_name, "sqlite_connection_cache_bytes", "sqlite_connection", read_cache_bytes)]
    end
  end
end
