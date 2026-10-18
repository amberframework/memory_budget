require "digest/sha256"

module MemoryBudget
  # Carries typed measurements and the identity of the workload that produced them.
  struct ScenarioMemoryEvidence
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter schema_version : Int32 = 1
    getter run_id : String = ""
    getter source_commit : String = ""
    getter executable_sha256 : String = ""
    getter policy_sha256 : String = ""
    getter compiler_version : String = ""
    getter instrumentation_mode : String = ""
    getter list_of_measurements : Array(ObservedMemoryMeasurement) = [] of ObservedMemoryMeasurement
    getter list_of_capabilities : Array(AvailableMemoryCapability) = [] of AvailableMemoryCapability

    def initialize(@run_id : String, @source_commit : String, @executable_sha256 : String,
                   @policy_sha256 : String, @compiler_version : String, @instrumentation_mode : String,
                   @list_of_measurements : Array(ObservedMemoryMeasurement),
                   @list_of_capabilities : Array(AvailableMemoryCapability))
    end

    # Checks source, executable, and policy identities before enforcing measurements.
    def validate_evidence(policy_content : String) : Array(String)
      list_of_errors = [] of String
      list_of_errors << "Unsupported evidence schema" unless @schema_version == 1
      list_of_errors << "Missing run identity" if @run_id.empty?
      list_of_errors << "Missing source commit" unless @source_commit.matches?(/\A[0-9a-f]{40}\z/)
      list_of_errors << "Missing executable SHA-256" unless @executable_sha256.matches?(/\A[0-9a-f]{64}\z/)
      list_of_errors << "Policy SHA-256 mismatch" unless @policy_sha256 == Digest::SHA256.hexdigest(policy_content)
      list_of_errors << "Missing compiler identity" if @compiler_version.empty?
      list_of_errors << "Missing instrumentation mode" if @instrumentation_mode.empty?
      list_of_errors
    end
  end
end
