module MemoryBudget
  # Declares a backend's supported metric, scope, version, and platform.
  struct AvailableMemoryCapability
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter metric_name : String = ""
    getter measurement_scope : String = ""
    getter backend_name : String = ""
    getter backend_revision : String = ""
    getter platform_profile : String = "any"

    def initialize(@metric_name : String = "", @measurement_scope : String = "", @backend_name : String = "",
                   @backend_revision : String = "", @platform_profile : String = "any")
    end
  end
end
