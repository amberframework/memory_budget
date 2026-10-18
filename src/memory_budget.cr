require "json"
require "./memory_budget/memory_budget_error"
require "./memory_budget/memory_metric_limit"
require "./memory_budget/scenario_memory_policy"
require "./memory_budget/observed_memory_measurement"
require "./memory_budget/available_memory_capability"
require "./memory_budget/memory_budget_verdict"
require "./memory_budget/scenario_memory_contract"
require "./memory_budget/verify_scenario_memory_budget"

module MemoryBudget
  VERSION = "0.1.1"
end
