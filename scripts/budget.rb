#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative "toolchain_profile"

# Admit the complete installed identity before preparing the runtime overlay.
package_root = File.expand_path("..", __dir__)
begin
  identity = MemoryBudget::ToolchainProfile.resolve(package_root)
  ENV.update(identity.environment)
rescue MemoryBudget::ToolchainProfile::AdmissionError => error
  abort error.message
end
profile = identity.profile
ENV["MEMORY_BUDGET_COMPILER"] = identity.compiler_path
ENV["MEMORY_BUDGET_COMPILER_SHA256"] = profile.fetch("compiler_sha256")
ENV["MEMORY_BUDGET_STDLIB"] = identity.stdlib_root
ENV["MEMORY_BUDGET_STDLIB_SHA256"] = profile.fetch("stdlib_sha256")
ENV["CRYSTAL_CACHE_DIR"] ||= File.join(ENV.fetch("TMPDIR", "/tmp"), "memory-budget-#{Digest::SHA256.hexdigest(Dir.pwd)[0, 16]}")
exec RbConfig.ruby, File.join(__dir__, "run_specs.rb"), *ARGV
