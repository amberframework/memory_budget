module MemoryBudget
  # Associates a named operation and measurement scope with explicit limits.
  struct ScenarioMemoryPolicy
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter scenario_name : String = ""
    getter measurement_scope : String = ""
    getter item_count : UInt64 = 1_u64
    getter platform_profile : String = "any"
    getter cache_state : String = "warm"
    getter measurement_window : String = "joined_block"
    getter list_of_limits : Array(MemoryMetricLimit) = [] of MemoryMetricLimit

    def initialize(@scenario_name : String = "", @measurement_scope : String = "",
                   @list_of_limits : Array(MemoryMetricLimit) = [] of MemoryMetricLimit,
                   @item_count : UInt64 = 1_u64, @platform_profile : String = "any",
                   @cache_state : String = "warm", @measurement_window : String = "joined_block")
    end

    # Returns configuration errors before a measurement is accepted.
    def validate_policy : Array(String)
      list_of_errors = [] of String
      list_of_errors << "scenario_name must be nonempty" if @scenario_name.strip.empty?
      list_of_errors << "measurement_scope must be nonempty" if @measurement_scope.strip.empty?
      list_of_errors << "platform_profile must be nonempty" if @platform_profile.strip.empty?
      list_of_errors << "cache_state must be cold or warm" unless {"cold", "warm"}.includes?(@cache_state)
      list_of_errors << "measurement_window must be nonempty" if @measurement_window.strip.empty?
      list_of_errors << "list_of_limits must be nonempty" if @list_of_limits.empty?
      list_of_metric_names = @list_of_limits.map(&.metric_name)
      list_of_errors << "metric names must be nonempty and unique" if list_of_metric_names.any?(&.strip.empty?) || list_of_metric_names.uniq.size != list_of_metric_names.size
      @list_of_limits.each do |limit|
        if limit_overflows?(limit)
          list_of_errors << "#{limit.metric_name}: fixed-plus-per-item limit overflows UInt64"
        end
      end
      list_of_errors
    end

    private def limit_overflows?(limit : MemoryMetricLimit) : Bool
      limit.allowed_value(@item_count)
      false
    rescue OverflowError
      true
    end
  end
end
