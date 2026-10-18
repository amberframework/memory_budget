{% if flag?(:darwin) %}
  # :nodoc:
  lib LibMemoryBudgetMach
    $mach_task_self_ : UInt32
    fun task_info(task : UInt32, flavor : Int32, information : UInt32*, count : UInt32*) : Int32
    fun proc_pid_rusage(process_id : Int32, flavor : Int32, information : UInt64*) : Int32
  end
{% end %}

module MemoryBudget
  # Reads public process counters while preserving OS-specific metric names.
  struct ProcessMemorySnapshot
    getter current_bytes : UInt64
    getter lifetime_peak_bytes : UInt64

    def initialize(@current_bytes : UInt64, @lifetime_peak_bytes : UInt64)
    end

    # Reads a self-process snapshot; the peak covers the entire process lifetime.
    def self.read_process_memory : ProcessMemorySnapshot
      {% if flag?(:darwin) %}
        # TASK_VM_INFO uses 32-bit natural_t words. Public SDK offsets are verified
        # independently by spec/fixtures/task_vm_layout.c before releasing this backend.
        information = StaticArray(UInt32, 128).new(0_u32)
        count = 128_u32
        status = LibMemoryBudgetMach.task_info(LibMemoryBudgetMach.mach_task_self_, 22, information.to_unsafe, pointerof(count))
        unless status == 0 && count >= 44
          raise MemoryBudgetError.new("Public TASK_VM_INFO rev3 unavailable: status=#{status}, words=#{count}")
        end
        footprint = information[36].to_u64 | (information[37].to_u64 << 32)
        peak = information[42].to_u64 | (information[43].to_u64 << 32)
        raise MemoryBudgetError.new("Invalid process footprint/peak counters") if footprint == 0 || peak < footprint
        new(footprint, peak)
      {% elsif flag?(:linux) %}
        list_of_lines = File.read("/proc/self/status").lines
        resident_bytes = read_linux_status_bytes(list_of_lines, "VmRSS:")
        peak_bytes = read_linux_status_bytes(list_of_lines, "VmHWM:")
        raise MemoryBudgetError.new("Invalid Linux RSS/high-water counters") if resident_bytes == 0 || peak_bytes < resident_bytes
        new(resident_bytes, peak_bytes)
      {% else %}
        raise MemoryBudgetError.new("Public process memory backend unsupported on this platform")
      {% end %}
    end

    # Reads the public counters of a live application process at a named checkpoint.
    def self.read_process_memory_for(process_id : Int64) : ProcessMemorySnapshot
      raise MemoryBudgetError.new("Process ID must be positive") unless process_id > 0 && process_id <= Int32::MAX
      {% if flag?(:darwin) %}
        # rusage_info_v4 public SDK offsets are checked by the ABI fixture.
        information = StaticArray(UInt64, 64).new(0_u64)
        status = LibMemoryBudgetMach.proc_pid_rusage(process_id.to_i32, 4, information.to_unsafe)
        raise MemoryBudgetError.new("Public process rusage unavailable: #{status}") unless status == 0
        footprint = information[9]
        peak = information[30]
        raise MemoryBudgetError.new("Invalid external process counters") if footprint == 0 || peak < footprint
        new(footprint, peak)
      {% elsif flag?(:linux) %}
        list_of_lines = File.read("/proc/#{process_id}/status").lines
        current = read_linux_status_bytes(list_of_lines, "VmRSS:")
        peak = read_linux_status_bytes(list_of_lines, "VmHWM:")
        raise MemoryBudgetError.new("Invalid external RSS counters") if current == 0 || peak < current
        new(current, peak)
      {% else %}
        raise MemoryBudgetError.new("External process memory backend unsupported")
      {% end %}
    rescue error : IO::Error | ArgumentError
      raise MemoryBudgetError.new("Cannot read process #{process_id}: #{error.message}")
    end

    # Identifies the actual OS/architecture profile for the measurement.
    def self.platform_profile : String
      {% if flag?(:darwin) && flag?(:aarch64) %}
        "darwin-arm64"
      {% elsif flag?(:darwin) %}
        "darwin-x86_64"
      {% elsif flag?(:linux) && flag?(:aarch64) %}
        "linux-arm64"
      {% elsif flag?(:linux) %}
        "linux-x86_64"
      {% else %}
        "unsupported"
      {% end %}
    end

    # Returns distinct Darwin physical-footprint and Linux RSS metric names.
    def self.metric_names : Tuple(String, String)
      {% if flag?(:darwin) %}
        {"process_phys_footprint_bytes", "process_lifetime_phys_peak_bytes"}
      {% elsif flag?(:linux) %}
        {"process_rss_bytes", "process_lifetime_rss_peak_bytes"}
      {% else %}
        {"unsupported", "unsupported"}
      {% end %}
    end

    # Declares the public backend's supported counters.
    def self.available_capabilities : Array(AvailableMemoryCapability)
      return [] of AvailableMemoryCapability if platform_profile == "unsupported"
      metric_names.to_a.map { |metric| AvailableMemoryCapability.new(metric, "process", "public_process_counter", "1", platform_profile) }
    end

    # Produces only the explicitly requested process metrics.
    def observations_for(policy : ScenarioMemoryPolicy) : Array(ObservedMemoryMeasurement)
      list_of_metrics = self.class.metric_names
      policy.list_of_limits.map do |limit|
        measured_value = case limit.metric_name
                         when list_of_metrics[0] then @current_bytes
                         when list_of_metrics[1] then @lifetime_peak_bytes
                         else
                           raise MemoryBudgetError.new("Process backend does not measure #{limit.metric_name}")
                         end
        ObservedMemoryMeasurement.new(policy.scenario_name, limit.metric_name, "process", measured_value,
          platform_profile: self.class.platform_profile)
      end
    end

    private def self.read_linux_status_bytes(list_of_lines : Array(String), field_name : String) : UInt64
      line = list_of_lines.find(&.starts_with?(field_name)) || raise MemoryBudgetError.new("Missing #{field_name} process counter")
      list_of_fields = line.split
      unless list_of_fields.size == 3 && list_of_fields[2] == "kB"
        raise MemoryBudgetError.new("Unexpected units for #{field_name}")
      end
      list_of_fields[1].to_u64 * 1024_u64
    end
  end
end
