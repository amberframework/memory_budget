"""Read a finite, read-only cgroup-v2 budget through a bounded interface."""
from dataclasses import asdict, dataclass
from pathlib import Path
import os
import re
import stat
import sys


class BudgetRefused(RuntimeError):
    pass


def require(value, message):
    if not value:
        raise BudgetRefused(message)


def number(raw):
    require(type(raw) is str and re.fullmatch(r'(0|[1-9][0-9]*)\n?', raw) is not None,
            'A complete finite nonnegative decimal value is required')
    return int(raw.strip())


@dataclass(frozen=True)
class Limits:
    strict_memory_bytes: int
    page_size: int
    cpu_quota: int = 100000
    cpu_period: int = 100000
    maximum_processes: int = 64

    def __post_init__(self):
        require(all(type(value) is int for value in asdict(self).values()),
                'Typed integer limits are required')
        require(4096 <= self.page_size <= 65536 and self.page_size & (self.page_size-1) == 0,
                'A supported power-of-two kernel page size is required')
        require(self.page_size < self.strict_memory_bytes <= 2_000_000_000,
                'A positive strict memory budget up to the Grant target is required')
        require(self.cpu_quota == self.cpu_period == 100000
                and self.maximum_processes == 64,
                'The qualified profile uses one CPU and 64 process slots')

    @property
    def hard_memory_bytes(self):
        # The kernel can round a memory limit upward to a page boundary.
        return ((self.strict_memory_bytes-1)//self.page_size)*self.page_size


def read_small(path, maximum=4096):
    path = Path(path)
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and path.resolve(strict=True) == path,
            'A physical regular kernel control file is required')
    descriptor = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        opened = os.fstat(stream.fileno())
        require((opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
                'The opened kernel control file must retain its identity')
        raw = stream.read(maximum+1)
    require(0 < len(raw) <= maximum, 'A complete bounded kernel control value is required')
    after = path.lstat()
    require((after.st_dev, after.st_ino) == (before.st_dev, before.st_ino),
            'The kernel control path must retain its identity')
    return raw.decode('ascii', 'strict')


def verify_mount(mountinfo, membership):
    require(membership == '0::/\n', 'A private unified cgroup namespace is required')
    matches = []
    for line in mountinfo.splitlines():
        fields = line.split()
        if len(fields) >= 10 and fields[4] == '/sys/fs/cgroup':
            separator = fields.index('-') if '-' in fields else -1
            require(separator >= 6 and len(fields) >= separator+4,
                    'A complete cgroup mountinfo entry is required')
            matches.append(fields[separator+1] == 'cgroup2'
                           and 'ro' in fields[5].split(',')
                           and 'rw' not in fields[5].split(','))
    require(matches == [True], 'Exactly one read-only cgroup-v2 mount is required')


def events(raw):
    result = {}
    for line in raw.splitlines():
        fields = line.split(' ')
        require(len(fields) == 2 and re.fullmatch('[a-z_]+', fields[0]) is not None
                and fields[0] not in result, 'Unique complete memory event rows are required')
        result[fields[0]] = number(fields[1])
    require({'low', 'high', 'max', 'oom', 'oom_kill'} <= set(result),
            'The kernel memory pressure and OOM event counters are required')
    return result


@dataclass(frozen=True)
class Snapshot:
    memory_max: int
    memory_current: int
    memory_peak: int
    swap_max: int
    swap_current: int
    cpu_max: str
    cpu_burst: int
    pids_max: int
    pids_current: int
    memory_events: dict


def read_snapshot(read):
    return Snapshot(
        memory_max=number(read('memory.max')),
        memory_current=number(read('memory.current')),
        memory_peak=number(read('memory.peak')),
        swap_max=number(read('memory.swap.max')),
        swap_current=number(read('memory.swap.current')),
        cpu_max=read('cpu.max'), cpu_burst=number(read('cpu.max.burst')),
        pids_max=number(read('pids.max')), pids_current=number(read('pids.current')),
        memory_events=events(read('memory.events')))


def verify_snapshot(snapshot, limits):
    require(isinstance(snapshot, Snapshot) and isinstance(limits, Limits),
            'Typed kernel snapshot and declared limits are required')
    counters = (snapshot.memory_max, snapshot.memory_current, snapshot.memory_peak,
                snapshot.swap_max, snapshot.swap_current, snapshot.cpu_burst,
                snapshot.pids_max, snapshot.pids_current)
    require(all(type(value) is int and value >= 0 for value in counters)
            and type(snapshot.cpu_max) is str,
            'Complete nonnegative integer kernel counters are required')
    require(type(snapshot.memory_events) is dict
            and {'low', 'high', 'max', 'oom', 'oom_kill'} <= set(snapshot.memory_events)
            and all(type(key) is str and re.fullmatch('[a-z_]+', key) is not None
                    and type(value) is int and value >= 0
                    for key, value in snapshot.memory_events.items()),
            'Complete typed pressure and OOM event counters are required')
    require(snapshot.memory_max == limits.hard_memory_bytes,
            'The exact page-aligned strict memory ceiling must be active')
    require(0 < snapshot.memory_current <= snapshot.memory_peak < limits.strict_memory_bytes,
            'Positive current and peak memory must fit the strict byte budget')
    require(snapshot.swap_max == snapshot.swap_current == 0,
            'The kernel must enforce zero swap for this profile')
    require(snapshot.cpu_max == f'{limits.cpu_quota} {limits.cpu_period}\n'
            and snapshot.cpu_burst == 0, 'The exact one-CPU quota with zero burst is required')
    require(snapshot.pids_max == limits.maximum_processes
            and 0 < snapshot.pids_current <= snapshot.pids_max,
            'The exact finite process ceiling must be active')
    require(all(value == 0 for value in snapshot.memory_events.values()),
            'A successful control run must retain zero memory pressure and OOM events')
    return snapshot


def compare_snapshots(before, after, limits):
    verify_snapshot(before, limits)
    verify_snapshot(after, limits)
    require(after.memory_peak >= before.memory_peak,
            'The cgroup lifetime peak must retain its earlier high-water mark')
    require(set(before.memory_events) == set(after.memory_events),
            'The kernel event schema must remain stable across the workload')
    return dict(scope='current-cgroup-and-descendants-through-final-snapshot-v1',
                limits=asdict(limits), hard_memory_bytes=limits.hard_memory_bytes,
                before=asdict(before), after=asdict(after),
                compiler_process_rss_accepted=False, complete_Grant_build_accepted=False,
                lifetime_container_enforcement_requires_external_terminal_inspection=True)


class CurrentCgroup:
    """The production perimeter uses fixed kernel paths; fixtures use pure functions."""
    def __init__(self, limits):
        require(sys.platform == 'linux', 'This provider requires the Linux kernel')
        require(os.sysconf('SC_PAGE_SIZE') == limits.page_size,
                'The declared page size must match the running kernel')
        self.limits = limits

    def snapshot(self):
        process = Path('/proc') / str(os.getpid())
        verify_mount(read_small(process/'mountinfo', 1024*1024),
                     read_small(process/'cgroup'))
        return verify_snapshot(read_snapshot(
            lambda name: read_small(Path('/sys/fs/cgroup')/name)), self.limits)
