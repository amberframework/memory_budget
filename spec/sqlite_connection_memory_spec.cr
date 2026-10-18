require "./spec_helper"
require "../src/memory_budget/sqlite_connection_memory"

lib LibMemoryBudgetSQLite
  fun sqlite3_open(filename : UInt8*, database : Void**) : Int32
  fun sqlite3_exec(database : Void*, sql : UInt8*, callback : Void*, context : Void*, error_message : UInt8**) : Int32
  fun sqlite3_close(database : Void*) : Int32
end

describe MemoryBudget::SQLiteConnectionMemory do
  describe "#read_cache_bytes" do
    it "observes cache growth and accepts sufficient then rejects tight budgets" do
      connection = Pointer(Void).null
      LibMemoryBudgetSQLite.sqlite3_open(":memory:", pointerof(connection)).should eq(0)
      begin
        reader = MemoryBudget::SQLiteConnectionMemory.new(connection)
        before = reader.read_cache_bytes
        sql = "CREATE TABLE record(payload BLOB); WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<100) INSERT INTO record SELECT zeroblob(4096) FROM n;"
        LibMemoryBudgetSQLite.sqlite3_exec(connection, sql, Pointer(Void).null, Pointer(Void).null, Pointer(Pointer(UInt8)).null).should eq(0)
        reader.read_cache_bytes.should be > before + 300_000_u64
        {1_048_576_u64, 1_u64}.each do |maximum|
          policy = MemoryBudget::ScenarioMemoryPolicy.new("insert_records", "sqlite_connection", [MemoryBudget::MemoryMetricLimit.new("sqlite_connection_cache_bytes", maximum)])
          verdict = MemoryBudget::VerifyScenarioMemoryBudget.new(policy, reader.observations_for(policy), MemoryBudget::SQLiteConnectionMemory.available_capabilities).perform
          verdict.passed?.should eq(maximum == 1_048_576_u64)
        end
      ensure
        LibMemoryBudgetSQLite.sqlite3_close(connection).should eq(0)
      end
    end

    it "rejects a closed or missing connection" do
      expect_raises(MemoryBudget::MemoryBudgetError, "must be open") do
        MemoryBudget::SQLiteConnectionMemory.new(Pointer(Void).null)
      end
    end
  end
end
