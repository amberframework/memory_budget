require "./spec_helper"
include MemoryBudgetSpecSupport

describe "Memory capability identity" do
  {"backend", "revision", "platform"}.each do |identity_field|
    it "requires a nonblank #{identity_field} identity before accepting a matching pair" do
      backend_name = identity_field == "backend" ? "  " : "test"
      backend_revision = identity_field == "revision" ? "" : "1"
      platform_profile = identity_field == "platform" ? "" : "any"
      measurement = MemoryBudget::ObservedMemoryMeasurement.new(
        "render_records", "crystal_requested_bytes", "fiber", 32_u64,
        backend_revision: backend_revision, platform_profile: platform_profile)
      capability = MemoryBudget::AvailableMemoryCapability.new(
        "crystal_requested_bytes", "fiber", backend_name, backend_revision, platform_profile)
      memory_verdict(list_of_measurements: [measurement], list_of_capabilities: [capability]).verdict_status.should eq("unsupported")
    end
  end
end
