require "./memory_budget"
require "./memory_budget/verify_memory_contract_evidence"

# The command boundary owns filesystem access and process exit behavior.
begin
  unless ARGV.size == 4 && ARGV[0] == "check"
    raise MemoryBudget::MemoryBudgetError.new("Usage: memory-budget check CONTRACT.json EVIDENCE.json REPORT.json")
  end
  policy_content = File.read(ARGV[1])
  evidence = MemoryBudget::ScenarioMemoryEvidence.from_json(File.read(ARGV[2]))
  report = MemoryBudget::VerifyMemoryContractEvidence.new(policy_content, evidence).perform
  File.write(ARGV[3], report.to_pretty_json + "\n")
  STDOUT.puts report.to_json
  exit(report.passed? ? 0 : 2)
rescue error : MemoryBudget::MemoryBudgetError | JSON::Error | IO::Error | ArgumentError
  report = MemoryBudget::ScenarioMemoryReport.new("invalid", [] of MemoryBudget::MemoryBudgetVerdict, [error.message || error.class.name])
  File.write(ARGV[3], report.to_pretty_json + "\n") if ARGV.size == 4
  STDERR.puts report.to_json
  exit 2
end
