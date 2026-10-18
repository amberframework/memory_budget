require "../src/memory_budget"
require "../src/memory_budget/sqlite_connection_memory"

lib LibMemoryBudgetSQLite
  fun sqlite3_open(filename : UInt8*, database : Void**) : Int32
  fun sqlite3_exec(database : Void*, sql : UInt8*, callback : Void*, context : Void*, error_message : UInt8**) : Int32
  fun sqlite3_close(database : Void*) : Int32
end

maximum_bytes = ARGV.first?.try(&.to_u64) || 1_048_576_u64
connection = Pointer(Void).null
raise MemoryBudget::MemoryBudgetError.new("SQLite open failed") unless LibMemoryBudgetSQLite.sqlite3_open(":memory:", pointerof(connection)) == 0
begin
  sql = "CREATE TABLE record(payload BLOB); WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<100) INSERT INTO record SELECT zeroblob(4096) FROM n;"
  status = LibMemoryBudgetSQLite.sqlite3_exec(connection, sql, Pointer(Void).null, Pointer(Void).null, Pointer(Pointer(UInt8)).null)
  raise MemoryBudget::MemoryBudgetError.new("SQLite insert failed") unless status == 0
  reader = MemoryBudget::SQLiteConnectionMemory.new(connection)
  policy = MemoryBudget::ScenarioMemoryPolicy.new("insert_records", "sqlite_connection", [MemoryBudget::MemoryMetricLimit.new("sqlite_connection_cache_bytes", maximum_bytes)])
  verdict = MemoryBudget::VerifyScenarioMemoryBudget.new(policy, reader.observations_for(policy), MemoryBudget::SQLiteConnectionMemory.available_capabilities).perform
  STDOUT.puts verdict.to_json
  exit(verdict.passed? ? 0 : 2)
ensure
  LibMemoryBudgetSQLite.sqlite3_close(connection)
end
