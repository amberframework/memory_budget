require "../src/memory_budget"
require "../src/memory_budget/read_c_allocation_evidence"

fixture_root = File.expand_path("../spec/fixtures/c", __DIR__)
coverage = MemoryBudget::CAllocationCoverage.from_json(File.read(File.join(fixture_root, "corefoundation_string_released_1_run1.checkpoint.json")))
reader = MemoryBudget::ReadCAllocationEvidence.new(File.read(File.join(fixture_root, "corefoundation_string_released_1_run1.symbolized.tsv")), coverage)
maximum = ARGV.first?.try(&.to_u64) || 1680_u64
policy = MemoryBudget::ScenarioMemoryPolicy.new("cf_owned_release", "c_allocation_owner", [MemoryBudget::MemoryMetricLimit.new("c_requested_bytes", maximum), MemoryBudget::MemoryMetricLimit.new("c_owned_live_bytes", 0_u64)])
verdict = MemoryBudget::VerifyScenarioMemoryBudget.new(policy, reader.read_owned_site_observations(policy, "cases.cr:98", 21_u64), MemoryBudget::ReadCAllocationEvidence.available_capabilities).perform
STDOUT.puts verdict.to_json
exit(verdict.passed? ? 0 : 2)
