# Per-fiber allocation counting for Crystal's garbage-collected heap (core).
#
# This file is shared verbatim by two hook layers:
#
# - the crystal-alpha fork's standard library, as `src/fiber/allocation_tally.cr`,
#   compiled in with `-Dfiber_allocation_tally`;
# - the `fiber_allocation_tally` shard, as `src/fiber_allocation_tally/core.cr`,
#   which reopens the stock standard library in spec builds.
#
# Two designs are built from it, selected at compile time:
#
# - *fiber fields* (the default): every `GC.malloc`, `GC.malloc_atomic` and
#   `GC.realloc` adds to counters stored on the running `Fiber`, found through
#   the thread-local `Thread.current?`.
# - *switch flush* (`-Dfiber_allocation_tally_switch_flush`): every allocation
#   adds to plain thread-local counters, and each context switch moves those
#   counters into the fiber that is switched out.
#
# In both designs a byte is charged to exactly one place: the fiber that was
# running when it was allocated, or the "unattributed" tally of its thread when
# no fiber was running yet (the main thread before `Thread` and its main
# `Fiber` exist, a new thread before its main fiber exists). When a fiber
# finishes, it leaves `Fiber.each` and waits in its thread's "dying" slot until
# its last context switch, when its tally joins the process-wide "retired"
# tally. Those moves happen under a small sequence lock that
# `AllocationTally.process_total` reads against, so the process total is always
# the sum of the live fibers, the dying fibers, the retired fibers and the
# unattributed tallies, with no fiber counted twice or dropped.
#
# Nothing on the counting path allocates, takes a lock, or calls into the
# scheduler: it runs inside the allocator.
class Fiber
  # Allocator traffic on the Crystal heap: the calls into `GC.malloc`,
  # `GC.malloc_atomic` and `GC.realloc`, and the bytes they asked for.
  #
  # A fiber's tally counts exactly the allocations made while it was the
  # running fiber of its thread, whichever thread that was.
  #
  # ```
  # before = Fiber.current.allocation_tally
  # list_of_names = ["a", "b"]
  # spent = Fiber.current.allocation_tally - before
  # spent.calls # => 2 (the Array object and its buffer)
  # ```
  struct AllocationTally
    # Identifies the allocation measurement protocol consumed by spec/CI libraries.
    API_VERSION = 1

    # :nodoc:
    DESIGN = {% if flag?(:fiber_allocation_tally_switch_flush) %}"switch_flush"{% else %}"fiber_fields"{% end %}

    # `GC.malloc` plus `GC.malloc_atomic` calls.
    getter malloc_calls : UInt64
    # The subset of `malloc_calls` for pointer-free memory (`GC.malloc_atomic`).
    getter atomic_calls : UInt64
    # Bytes requested by `malloc_calls`.
    getter malloc_bytes : UInt64
    # `GC.realloc` calls.
    getter realloc_calls : UInt64
    # New sizes requested by `realloc_calls`.
    getter realloc_bytes : UInt64
    # Bytes the collector set aside after rounding each request up to its size
    # class (`GC_size`); a reallocation that stayed in place adds nothing.
    getter reserved_bytes : UInt64

    def initialize(@malloc_calls : UInt64 = 0_u64, @atomic_calls : UInt64 = 0_u64, @malloc_bytes : UInt64 = 0_u64,
                   @realloc_calls : UInt64 = 0_u64, @realloc_bytes : UInt64 = 0_u64, @reserved_bytes : UInt64 = 0_u64)
    end

    # Every call into the allocator, reallocations included.
    def calls : UInt64
      @malloc_calls + @realloc_calls
    end

    # Bytes asked for: the size of every malloc plus the new size of every realloc.
    def requested_bytes : UInt64
      @malloc_bytes + @realloc_bytes
    end

    def zero? : Bool
      calls == 0 && @reserved_bytes == 0
    end

    def +(other : AllocationTally) : AllocationTally
      AllocationTally.new(
        @malloc_calls + other.malloc_calls, @atomic_calls + other.atomic_calls, @malloc_bytes + other.malloc_bytes,
        @realloc_calls + other.realloc_calls, @realloc_bytes + other.realloc_bytes, @reserved_bytes + other.reserved_bytes)
    end

    # The traffic between an earlier reading and this one.
    #
    # The subtraction is checked: tallies only grow, so a negative difference
    # means the two readings came from different fibers, and that raises
    # `OverflowError` instead of returning a wrapped number.
    def -(other : AllocationTally) : AllocationTally
      AllocationTally.new(
        @malloc_calls - other.malloc_calls, @atomic_calls - other.atomic_calls, @malloc_bytes - other.malloc_bytes,
        @realloc_calls - other.realloc_calls, @realloc_bytes - other.realloc_bytes, @reserved_bytes - other.reserved_bytes)
    end

    def to_s(io : IO) : Nil
      io << calls << " calls (" << @malloc_calls << " malloc, " << @atomic_calls << " of them atomic, "
      io << @realloc_calls << " realloc), " << requested_bytes << " bytes requested, " << @reserved_bytes << " reserved"
    end

    def inspect(io : IO) : Nil
      io << "#<Fiber::AllocationTally "
      to_s(io)
      io << '>'
    end

    # :nodoc:
    @[AlwaysInline]
    def count_malloc(size : UInt64, reserved : UInt64, atomic : Bool) : Nil
      @malloc_calls &+= 1
      @atomic_calls &+= 1 if atomic
      @malloc_bytes &+= size
      @reserved_bytes &+= reserved
    end

    # :nodoc:
    @[AlwaysInline]
    def count_realloc(size : UInt64, reserved : UInt64) : Nil
      @realloc_calls &+= 1
      @realloc_bytes &+= size
      @reserved_bytes &+= reserved
    end

    # :nodoc:
    #
    # Adds *other* into this tally in place (no allocation, no checks: it runs
    # inside the allocator and at context switches).
    @[AlwaysInline]
    def add(other : AllocationTally) : Nil
      @malloc_calls &+= other.malloc_calls
      @atomic_calls &+= other.atomic_calls
      @malloc_bytes &+= other.malloc_bytes
      @realloc_calls &+= other.realloc_calls
      @realloc_bytes &+= other.realloc_bytes
      @reserved_bytes &+= other.reserved_bytes
    end

    # Declares one class variable per counter, `@@<group>_<counter> = 0_u64`.
    # Literal initializers keep them statically initialized: no lazy-init
    # check runs inside the allocator, and thread-local ones start at zero on
    # every thread.
    private macro declare_counter_group(group, thread_local)
      {% for counter in %w(malloc_calls atomic_calls malloc_bytes realloc_calls realloc_bytes reserved_bytes) %}
        {% if thread_local %}@[ThreadLocal]{% end %}
        @@{{group.id}}_{{counter.id}} = 0_u64
      {% end %}
    end

    private macro read_counter_group(group)
      AllocationTally.new(
        {% for counter in %w(malloc_calls atomic_calls malloc_bytes realloc_calls realloc_bytes reserved_bytes) %}
          Atomic::Ops.load(pointerof(@@{{group.id}}_{{counter.id}}), :sequentially_consistent, false),
        {% end %}
      )
    end

    private macro add_to_counter_group(group, tally)
      {% for counter in %w(malloc_calls atomic_calls malloc_bytes realloc_calls realloc_bytes reserved_bytes) %}
        @@{{group.id}}_{{counter.id}} &+= {{tally}}.{{counter.id}}
      {% end %}
    end

    private macro add_to_counter_group_atomically(group, tally)
      {% for counter in %w(malloc_calls atomic_calls malloc_bytes realloc_calls realloc_bytes reserved_bytes) %}
        Atomic::Ops.atomicrmw(:add, pointerof(@@{{group.id}}_{{counter.id}}), {{tally}}.{{counter.id}}, :sequentially_consistent, false)
      {% end %}
    end

    # Process-wide: fibers that died, moved here at their last context switch.
    declare_counter_group retired, false
    # Process-wide: allocations made while no fiber was running on the thread.
    declare_counter_group unattributed, false
    # The same, for the current thread only.
    declare_counter_group unattributed_here, true

    {% if flag?(:fiber_allocation_tally_switch_flush) %}
      # Design B: the running fiber's allocations since its thread's last switch.
      declare_counter_group pending, true

      # :nodoc:
      #
      # Where one thread keeps its `pending` counters, so that another thread
      # can read them for the process total.
      struct PendingCounters
        def initialize(@malloc_calls : UInt64* = Pointer(UInt64).null, @atomic_calls : UInt64* = Pointer(UInt64).null,
                       @malloc_bytes : UInt64* = Pointer(UInt64).null, @realloc_calls : UInt64* = Pointer(UInt64).null,
                       @realloc_bytes : UInt64* = Pointer(UInt64).null, @reserved_bytes : UInt64* = Pointer(UInt64).null)
        end

        def registered? : Bool
          !@malloc_calls.null?
        end

        def read : AllocationTally
          return AllocationTally.new unless registered?

          AllocationTally.new(
            Atomic::Ops.load(@malloc_calls, :monotonic, false), Atomic::Ops.load(@atomic_calls, :monotonic, false),
            Atomic::Ops.load(@malloc_bytes, :monotonic, false), Atomic::Ops.load(@realloc_calls, :monotonic, false),
            Atomic::Ops.load(@realloc_bytes, :monotonic, false), Atomic::Ops.load(@reserved_bytes, :monotonic, false))
        end
      end

      # :nodoc:
      def self.pending_on_this_thread : AllocationTally
        AllocationTally.new(@@pending_malloc_calls, @@pending_atomic_calls, @@pending_malloc_bytes,
          @@pending_realloc_calls, @@pending_realloc_bytes, @@pending_reserved_bytes)
      end

      private def self.clear_pending_on_this_thread : Nil
        @@pending_malloc_calls = 0_u64
        @@pending_atomic_calls = 0_u64
        @@pending_malloc_bytes = 0_u64
        @@pending_realloc_calls = 0_u64
        @@pending_realloc_bytes = 0_u64
        @@pending_reserved_bytes = 0_u64
      end
    {% end %}

    # Even while no fiber is moving between the live list, a dying slot and
    # the retired tally; odd during a move. Writers hold the move lock.
    @@move_generation = 0_u64
    @@move_lock = 0_u32

    # Every allocation of the process so far: the live fibers, the fibers
    # finishing their last steps, the fibers that died, and the unattributed
    # allocations.
    #
    # Each fiber is read once, and the moves between those places are atomic
    # for this reader, so a fiber that is dying while it reads is neither
    # dropped nor counted twice. Fibers running on other threads are read as
    # they are at that instant: an allocation they make during the reading
    # falls before or after it, never half in. With the switch-flush design, a
    # context switch happening on another thread during the reading can be
    # seen before or after its flush; read when the other threads are parked
    # for an exact number.
    def self.process_total : AllocationTally
      loop do
        generation = Atomic::Ops.load(pointerof(@@move_generation), :sequentially_consistent, false)
        if generation.odd?
          Intrinsics.pause
          next
        end
        total = retired + unattributed
        Fiber.each { |fiber| total = total + fiber.allocation_counts }
        Thread.each do |thread|
          if dying_fiber = thread.allocation_dying_fiber
            total = total + dying_fiber.allocation_counts
          end
          {% if flag?(:fiber_allocation_tally_switch_flush) %}
            total = total + thread.allocation_pending_counters.read
          {% end %}
        end
        return total if Atomic::Ops.load(pointerof(@@move_generation), :sequentially_consistent, false) == generation
      end
    end

    # Allocations of fibers that have died (process-wide).
    def self.retired : AllocationTally
      read_counter_group retired
    end

    # Allocations made while no fiber was running on their thread
    # (process-wide).
    def self.unattributed : AllocationTally
      read_counter_group unattributed
    end

    # Allocations made on the current thread while no fiber was running on it.
    def self.unattributed_on_this_thread : AllocationTally
      read_counter_group unattributed_here
    end

    # :nodoc:
    #
    # Called by `GC.malloc` (*atomic* false) and `GC.malloc_atomic` (*atomic*
    # true) after the collector returned *pointer*.
    @[AlwaysInline]
    def self.record_malloc(size : LibC::SizeT, pointer : Void*, atomic : Bool) : Nil
      reserved = reserved_size(pointer)
      {% if flag?(:fiber_allocation_tally_switch_flush) %}
        @@pending_malloc_calls &+= 1
        @@pending_atomic_calls &+= 1 if atomic
        @@pending_malloc_bytes &+= size.to_u64!
        @@pending_reserved_bytes &+= reserved
      {% else %}
        if (thread = Thread.current?) && (fiber = thread.current_fiber?)
          fiber.count_malloc_in_allocation_tally(size.to_u64!, reserved, atomic)
        else
          record_unattributed(AllocationTally.new(1_u64, atomic ? 1_u64 : 0_u64, size.to_u64!, 0_u64, 0_u64, reserved))
        end
      {% end %}
    end

    # :nodoc:
    #
    # Called by `GC.realloc` after the collector moved or resized *pointer*
    # to *reallocated*.
    @[AlwaysInline]
    def self.record_realloc(pointer : Void*, reallocated : Void*, size : LibC::SizeT) : Nil
      # A block that grew or shrank in place reserves nothing new; a moved one does.
      reserved = reallocated == pointer ? 0_u64 : reserved_size(reallocated)
      {% if flag?(:fiber_allocation_tally_switch_flush) %}
        @@pending_realloc_calls &+= 1
        @@pending_realloc_bytes &+= size.to_u64!
        @@pending_reserved_bytes &+= reserved
      {% else %}
        if (thread = Thread.current?) && (fiber = thread.current_fiber?)
          fiber.count_realloc_in_allocation_tally(size.to_u64!, reserved)
        else
          record_unattributed(AllocationTally.new(0_u64, 0_u64, 0_u64, 1_u64, size.to_u64!, reserved))
        end
      {% end %}
    end

    # :nodoc:
    #
    # Called by `Thread#current_fiber=` on the running thread, just before it
    # switches from *outgoing* to another fiber.
    @[AlwaysInline]
    def self.switch_out(outgoing : Fiber) : Nil
      {% if flag?(:fiber_allocation_tally_switch_flush) %}
        outgoing.add_to_allocation_tally(pending_on_this_thread)
        clear_pending_on_this_thread
      {% end %}
      # A finished fiber's last switch: nothing runs on it after this, so its
      # tally (death path included) moves from the dying slot to the retired one.
      retire_dying_fiber(outgoing) if outgoing.dead?
    end

    # :nodoc:
    #
    # Wraps `Fiber.inactive`, which removes *fiber* from `Fiber.each`: the
    # block runs inside a move, and *fiber* goes to its thread's dying slot
    # (a fiber finishing `Fiber#run`, which still runs until its last switch)
    # or straight to the retired tally (a thread's main fiber, when the thread
    # exits).
    def self.leave_live_list(fiber : Fiber, &) : Nil
      begin_move
      begin
        yield
        thread = Thread.current?
        if thread && (current = thread.current_fiber?) && current.same?(fiber) && !fiber.same?(thread.main_fiber?)
          {% if flag?(:fiber_allocation_tally_switch_flush) %}
            fiber.add_to_allocation_tally(pending_on_this_thread)
            clear_pending_on_this_thread
          {% end %}
          thread.allocation_dying_fiber = fiber
        else
          {% if flag?(:fiber_allocation_tally_switch_flush) %}
            if thread && fiber.same?(thread.main_fiber?)
              # The thread is exiting: it left `Thread.each` already, so its
              # unflushed allocations go to its main fiber now.
              thread.allocation_pending_counters = PendingCounters.new
              fiber.add_to_allocation_tally(pending_on_this_thread)
              clear_pending_on_this_thread
            end
          {% end %}
          counts = fiber.allocation_counts
          add_to_counter_group_atomically retired, counts
        end
      ensure
        end_move
      end
    end

    # :nodoc:
    #
    # Called on a thread once its main fiber exists, before that fiber is
    # set as the thread's current fiber.
    def self.thread_started(thread : Thread) : Nil
      {% if flag?(:fiber_allocation_tally_switch_flush) %}
        # Everything this thread allocated before it had a fiber.
        record_unattributed(pending_on_this_thread)
        clear_pending_on_this_thread
        thread.allocation_pending_counters = PendingCounters.new(
          pointerof(@@pending_malloc_calls), pointerof(@@pending_atomic_calls), pointerof(@@pending_malloc_bytes),
          pointerof(@@pending_realloc_calls), pointerof(@@pending_realloc_bytes), pointerof(@@pending_reserved_bytes))
      {% end %}
    end

    private def self.retire_dying_fiber(fiber : Fiber) : Nil
      begin_move
      begin
        counts = fiber.allocation_counts
        add_to_counter_group_atomically retired, counts
        if thread = Thread.current?
          thread.allocation_dying_fiber = nil if fiber.same?(thread.allocation_dying_fiber)
        end
      ensure
        end_move
      end
    end

    private def self.begin_move : Nil
      until Atomic::Ops.cmpxchg(pointerof(@@move_lock), 0_u32, 1_u32, :sequentially_consistent, :sequentially_consistent)[1]
        Intrinsics.pause
      end
      Atomic::Ops.atomicrmw(:add, pointerof(@@move_generation), 1_u64, :sequentially_consistent, false)
    end

    private def self.end_move : Nil
      Atomic::Ops.atomicrmw(:add, pointerof(@@move_generation), 1_u64, :sequentially_consistent, false)
      Atomic::Ops.store(pointerof(@@move_lock), 0_u32, :sequentially_consistent, false)
    end

    private def self.record_unattributed(tally : AllocationTally) : Nil
      add_to_counter_group unattributed_here, tally
      add_to_counter_group_atomically unattributed, tally
    end

    private def self.reserved_size(pointer : Void*) : UInt64
      return 0_u64 if pointer.null?

      {% if flag?(:gc_none) %}
        0_u64
      {% else %}
        LibGC.size(pointer).to_u64!
      {% end %}
    end
  end

  @allocation_counts = AllocationTally.new

  # Returns everything this fiber has allocated on the Crystal heap so far.
  #
  # Subtract two readings to measure a block; see `AllocationBudget.measure`.
  # For a fiber that is running on another thread at this moment, the
  # reading is a snapshot (and, with the switch-flush design, it stops at that
  # fiber's last context switch).
  def allocation_tally : AllocationTally
    {% if flag?(:fiber_allocation_tally_switch_flush) %}
      if (current = Fiber.current?) && current.same?(self)
        return @allocation_counts + AllocationTally.pending_on_this_thread
      end
    {% end %}
    @allocation_counts
  end

  # :nodoc:
  #
  # The counts stored on the fiber itself (with the switch-flush design,
  # without the current thread's unflushed allocations).
  def allocation_counts : AllocationTally
    @allocation_counts
  end

  # :nodoc:
  @[AlwaysInline]
  def count_malloc_in_allocation_tally(size : UInt64, reserved : UInt64, atomic : Bool) : Nil
    @allocation_counts.count_malloc(size, reserved, atomic)
  end

  # :nodoc:
  @[AlwaysInline]
  def count_realloc_in_allocation_tally(size : UInt64, reserved : UInt64) : Nil
    @allocation_counts.count_realloc(size, reserved)
  end

  # :nodoc:
  @[AlwaysInline]
  def add_to_allocation_tally(tally : AllocationTally) : Nil
    @allocation_counts.add(tally)
  end
end

class Thread
  # :nodoc:
  #
  # The fiber finishing on this thread: it left `Fiber.each` and has not made
  # its last context switch yet (see `Fiber::AllocationTally.leave_live_list`).
  property allocation_dying_fiber : Fiber? = nil

  {% if flag?(:fiber_allocation_tally_switch_flush) %}
    @allocation_pending_counters = Fiber::AllocationTally::PendingCounters.new

    # :nodoc:
    property allocation_pending_counters : Fiber::AllocationTally::PendingCounters
  {% end %}
end
