#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative "toolchain_profile"

begin
  identity = MemoryBudget::ToolchainProfile.resolve(File.expand_path("..", __dir__))
  puts identity.source_commit(require_git_provider: true)
rescue MemoryBudget::ToolchainProfile::AdmissionError, Errno::ENOENT, Errno::EACCES => error
  abort error.message
end
