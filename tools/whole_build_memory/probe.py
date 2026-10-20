"""Exercise descendant peak retention and separate sibling memory charges."""
from pathlib import Path
from functools import lru_cache
import argparse
import errno
import hashlib
import json
import mmap
import os
import re
import resource
import signal
import stat
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PROVIDER = ROOT / 'tools/installation_provenance'
PROVIDER_PINS = '15e27eea749e5d08f7d41256515b078f256c89fed5c49647c09dc99b99406eae'
STRICT_BYTES = 512 * 2**20
CHILD_BYTES = 64 * 2**20
SIBLING_BYTES = 192 * 2**20
SHARED_BYTES = 96 * 2**20


def need(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_sources(expected):
    manifest = HERE / 'SOURCE_PINS.json'
    need(digest(manifest) == expected, 'Exact descendant source manifest required')
    value = json.loads(manifest.read_bytes())
    need(value['format'] == 'atlas-whole-build-probe-sources-v1'
         and {item['path'] for item in value['files']} == {'probe.py', 'run_host.py', 'verify_results.py'}
         and len(value['files']) == 3, 'Complete unique probe source roster required')
    for row in value['files']:
        path = HERE / row['path']
        need(path.resolve() == path and stat.S_ISREG(path.lstat().st_mode)
             and stat.S_IMODE(path.stat().st_mode) == row['mode']
             and path.stat().st_size == row['bytes'] <= 2**20 and digest(path) == row['sha256'],
             'Every reviewed probe source must retain its identity')
    need(digest(PROVIDER / 'SOURCE_PINS.json') == PROVIDER_PINS, 'Exact qualified cgroup provider required')
    packet = json.loads((PROVIDER / 'SOURCE_PINS.json').read_bytes())
    need(len(packet['files']) == 7, 'Complete provider source roster required')
    for row in packet['files']:
        path = PROVIDER / row['path']
        need(path.resolve() == path and stat.S_ISREG(path.lstat().st_mode)
             and stat.S_IMODE(path.stat().st_mode) == row['mode']
             and path.stat().st_size == row['bytes'] and digest(path) == row['sha256'],
             'Every provider source must retain its reviewed bytes')
    sys.path.insert(0, str(PROVIDER))
    import cgroup_budget
    return cgroup_budget


def save(path, value):
    raw = (json.dumps(value, indent=2) + '\n').encode()
    need(len(raw) <= 128 * 1024 and path.parent.resolve() == path.parent and not path.exists(),
         'Fresh bounded physical evidence output required')
    temporary = path.with_name(path.name + '.tmp-' + str(os.getpid()))
    with temporary.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def marker(output, suffix):
    return output.with_name(output.stem + suffix)


def wait_file(path, seconds=20):
    deadline = time.monotonic() + seconds
    while not path.exists():
        need(time.monotonic() < deadline, 'Bounded rendezvous deadline reached: ' + path.name)
        time.sleep(.02)
    need(path.resolve() == path and stat.S_ISREG(path.lstat().st_mode)
         and path.stat().st_size <= 128 * 1024, 'Physical bounded rendezvous file required')
    return path


def process_identity(budget, pid=None):
    pid = os.getpid() if pid is None else pid
    need(type(pid) is int and pid > 0, 'Positive process identity required')
    raw = budget.read_small(Path('/proc') / str(pid) / 'stat', 16384)
    fields = raw.rsplit(')', 1)[1].split()
    need(len(fields) >= 20, 'Complete kernel process identity required')
    return {'pid': pid, 'ppid': int(fields[1]), 'pgid': int(fields[2]),
            'sid': int(fields[3]), 'start_ticks': int(fields[19])}


def context(budget, provider):
    identity = process_identity(budget)
    group = Path('/sys/fs/cgroup').stat()
    membership = budget.read_small(Path('/proc') / str(os.getpid()) / 'cgroup')
    members = [int(value) for value in budget.read_small('/sys/fs/cgroup/cgroup.procs', 16384).splitlines()]
    need(0 < len(members) <= 64 and len(set(members)) == len(members)
         and all(value > 0 for value in members), 'Stable finite live cgroup membership required')
    return {'identity': identity, 'cgroup_key': {'device': group.st_dev, 'inode': group.st_ino},
            'membership': membership, 'members': sorted(members),
            'self_peak_rss_kib': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            'waited_children_peak_rss_kib': resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
            'snapshot': budget.asdict(provider.snapshot()), 'monotonic_ns': time.monotonic_ns()}


def alone(budget, provider):
    deadline = time.monotonic() + 3
    while True:
        value = context(budget, provider)
        if value['members'] == [os.getpid()] and value['snapshot']['pids_current'] == 1:
            return value
        need(time.monotonic() < deadline, 'Every owned worker must retire before the final window')
        time.sleep(.02)


def allocation(size, page_size):
    value = bytearray(size)
    for offset in range(0, size, page_size):
        value[offset] = 1
    need(sum(value[offset] for offset in range(0, size, page_size)) == size // page_size,
         'Every declared allocation page must be touched and consumed')
    return value


def command(args, worker):
    flags = ['-I', '-S', '-B'] + (['-O'] if not __debug__ else [])
    return [sys.executable] + flags + [str(Path(__file__).resolve()), '--case', args.case,
        '--worker', worker, '--output', args.output, '--pins-sha256', args.pins_sha256,
        '--token', args.token]


def worker(args, budget, provider):
    output = Path(args.output)
    if args.worker in ('allocate', 'hold'):
        before = context(budget, provider)
        value = allocation(CHILD_BYTES, provider.limits.page_size)
        hot = context(budget, provider)
        if args.worker == 'hold':
            save(marker(output, '.rss-' + str(os.getpid()) + '.ready.json'), {'hot': hot})
            need(json.loads(wait_file(marker(output, '.overlap.release')).read_bytes()) == {'token': args.token},
                 'Exact overlapping-worker release token required')
        print(json.dumps({'stage': 'allocation', 'before': before, 'hot': hot, 'optimized_python': not __debug__,
                          'allocation_bytes': len(value), 'touched_pages': len(value) // provider.limits.page_size}), flush=True)
        return
    if args.worker == 'fork-exec':
        identity = process_identity(budget)
        child = os.fork()
        if child == 0:
            print(json.dumps({'stage': 'before-exec', 'identity': process_identity(budget)}), flush=True)
            os.execv(sys.executable, command(args, 'allocate'))
        waited, status = os.waitpid(child, 0)
        need(waited == child and os.waitstatus_to_exitcode(status) == 0, 'The forked/exec worker must complete')
        print(json.dumps({'stage': 'joined', 'launcher': identity, 'child_pid': child, 'exit_code': 0}), flush=True)
        return
    need(args.worker == 'detach', 'A supported worker mode is required')
    launcher = process_identity(budget)
    child = os.fork()
    if child == 0:
        os.setsid()
        with open('/dev/null', 'wb') as sink:
            os.dup2(sink.fileno(), 1)
            os.dup2(sink.fileno(), 2)
        value = allocation(CHILD_BYTES, provider.limits.page_size)
        save(marker(output, '.child.json'), {'launcher': launcher, 'hot': context(budget, provider), 'optimized_python': not __debug__,
             'allocation_bytes': len(value), 'touched_pages': len(value) // provider.limits.page_size})
        release = wait_file(marker(output, '.release'))
        need(json.loads(release.read_bytes()) == {'token': args.token}, 'Exact detached-worker release token required')
        os._exit(0)
    wait_file(marker(output, '.child.json'))
    print(json.dumps({'stage': 'detached', 'launcher': launcher, 'child_pid': child}), flush=True)


def run_child(args, budget, provider):
    before = alone(budget, provider)
    selected = 'allocate' if args.case == 'direct' else 'fork-exec' if args.case == 'fork-exec' else 'detach'
    child = subprocess.Popen(command(args, selected), stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        stdout, stderr = child.communicate(timeout=20)
    except BaseException:
        child.kill()
        child.wait(timeout=3)
        raise
    need(child.returncode == 0 and not stderr and len(stdout) <= 128 * 1024, 'The exact worker must finish normally')
    rows = [json.loads(line) for line in stdout.splitlines()]
    detached = None
    if args.case == 'detached':
        need(len(rows) == 1 and rows[0]['stage'] == 'detached', 'One exact detached launcher result required')
        pid = rows[0]['child_pid']
        detached = json.loads(wait_file(marker(Path(args.output), '.child.json')).read_bytes())
        observed = context(budget, provider)
        identity = process_identity(budget, pid)
        need(pid in observed['members'] and identity['ppid'] == os.getpid()
             and identity['pgid'] == identity['sid'] == pid
             and identity['start_ticks'] == detached['hot']['identity']['start_ticks'],
             'The adopted detached worker must remain in the complete cgroup window')
        save(marker(Path(args.output), '.release'), {'token': args.token})
        deadline = time.monotonic() + 3
        while True:
            waited, status = os.waitpid(pid, os.WNOHANG)
            if waited:
                need(waited == pid and os.waitstatus_to_exitcode(status) == 0, 'The adopted worker must be reaped normally')
                break
            need(time.monotonic() < deadline, 'Bounded adopted-worker join required')
            time.sleep(.02)
        detached['observed_after_launcher_exit'] = observed
        detached['adopted_identity'] = identity
        detached['exit_code'] = 0
    after = alone(budget, provider)
    budget.compare_snapshots(budget.Snapshot(**before['snapshot']), budget.Snapshot(**after['snapshot']), provider.limits)
    need(after['snapshot']['memory_peak'] >= before['snapshot']['memory_peak'] + CHILD_BYTES // 2
         and after['snapshot']['memory_peak'] - after['snapshot']['memory_current'] >= CHILD_BYTES // 2,
         'The kernel must retain the retired private allocation peak')
    return {'before': before, 'after': after, 'launcher_pid': child.pid, 'worker_exit_code': child.returncode,
            'worker_records': rows, 'detached': detached, 'parent_live_child_polls': 0 if args.case != 'detached' else 1}


def overlapping_rss(args, budget, provider):
    before = alone(budget, provider)
    children = []
    try:
        for unused in range(2):
            children.append(subprocess.Popen(command(args, 'hold'), stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE))
        ready = []
        for child in children:
            path = marker(Path(args.output), '.rss-' + str(child.pid) + '.ready.json')
            ready.append(json.loads(wait_file(path).read_bytes()))
        during = context(budget, provider)
        need(during['members'] == sorted([os.getpid()] + [child.pid for child in children])
             and during['snapshot']['memory_current'] >= 2 * CHILD_BYTES,
             'Both private workers must overlap in the same complete charged window')
        save(marker(Path(args.output), '.overlap.release'), {'token': args.token})
        rows = []
        for child in children:
            stdout, stderr = child.communicate(timeout=10)
            need(child.returncode == 0 and not stderr and len(stdout) <= 128 * 1024,
                 'Both overlapping workers must complete normally')
            records = [json.loads(line) for line in stdout.splitlines()]
            need(len(records) == 1 and records[0]['hot'] == ready[len(rows)]['hot'],
                 'The overlapping output must bind the held live observation')
            rows.append({'pid': child.pid, 'exit_code': child.returncode, 'allocation': records[0]})
        return {'before': before, 'during': during, 'after': alone(budget, provider), 'workers': rows}
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=3)


def sibling(args, budget, provider):
    output = Path(args.output)
    prefix = output.stem.rsplit('-', 1)[0]
    before = alone(budget, provider)
    if args.case == 'load':
        value = allocation(SIBLING_BYTES, provider.limits.page_size)
        hot = context(budget, provider)
        save(marker(output, '.ready.json'), {'hot': hot, 'allocation_bytes': len(value)})
        need(json.loads(wait_file(marker(output, '.release')).read_bytes()) == {'token': args.token}, 'Exact sibling-load release token required')
        size = len(value)
        del value
        after = alone(budget, provider)
        return {'before': before, 'hot': hot, 'after': after, 'allocation_bytes': size}
    need(args.case == 'observer', 'A supported sibling case is required')
    save(marker(output, '.ready.json'), {'before': before})
    load = json.loads(wait_file(output.with_name(prefix + '-load.ready.json')).read_bytes())
    during = context(budget, provider)
    need(during['cgroup_key'] != load['hot']['cgroup_key'], 'Separate sibling cgroup identities required')
    need(during['snapshot']['memory_peak'] < SIBLING_BYTES // 2
         and load['hot']['snapshot']['memory_current'] >= SIBLING_BYTES,
         'The unrelated private load must remain outside the observer budget')
    save(marker(output, '.sampled.json'), {'during': during})
    need(json.loads(wait_file(marker(output, '.release')).read_bytes()) == {'token': args.token}, 'Exact observer release token required')
    return {'before': before, 'during': during, 'after': alone(budget, provider), 'sibling_hot': load}


@lru_cache(maxsize=1)
def shared_signature():
    value = hashlib.sha256()
    page = b'\x01' + b'\x00' * 4095
    for unused in range(SHARED_BYTES // 4096):
        value.update(page)
    return value.hexdigest()


def shared_file_identity(path):
    before = path.lstat()
    need(path.resolve() == path and stat.S_ISREG(before.st_mode) and before.st_size == SHARED_BYTES
         and before.st_uid == 501 and stat.S_IMODE(before.st_mode) == 0o644 and before.st_nlink == 1,
         'One exact physical shared file with its expected owner, size and mode is required')
    signature = hashlib.sha256()
    descriptor = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        opened = os.fstat(stream.fileno())
        need((opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino), 'The opened shared inode must remain exact')
        while True:
            block = stream.read(65536)
            if not block:
                break
            signature.update(block)
    after = path.lstat()
    need((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) ==
         (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns), 'The complete shared file must remain stable')
    return {'device': before.st_dev, 'inode': before.st_ino, 'bytes': before.st_size,
            'uid': before.st_uid, 'mode': stat.S_IMODE(before.st_mode), 'sha256': signature.hexdigest()}


def shared_pages(args, budget, provider):
    output = Path(args.output)
    prefix = output.stem.rsplit('-shared-', 1)[0]
    path = output.with_name(prefix + '-shared-pages.bin')
    before = alone(budget, provider)
    if args.case == 'shared-load':
        descriptor = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o644)
        with os.fdopen(descriptor, 'r+b') as stream:
            stream.truncate(SHARED_BYTES)
            with mmap.mmap(stream.fileno(), SHARED_BYTES, access=mmap.ACCESS_WRITE) as pages:
                for offset in range(0, SHARED_BYTES, 4096):
                    pages[offset] = 1
                pages.flush()
                checksum = sum(pages[offset] for offset in range(0, SHARED_BYTES, 4096))
                need(checksum == SHARED_BYTES // 4096, 'Every shared writer page must be consumed')
                file = shared_file_identity(path)
                need(file['sha256'] == shared_signature(), 'The complete writer content signature must match')
                hot = context(budget, provider)
                save(marker(output, '.ready.json'), {'hot': hot, 'file': file, 'page_checksum': checksum})
                wait_file(output.with_name(prefix + '-shared-observer.sampled.json'))
                retained = context(budget, provider)
                save(marker(output, '.retained.json'), {'retained': retained, 'file': shared_file_identity(path)})
                need(json.loads(wait_file(marker(output, '.release')).read_bytes()) == {'token': args.token},
                     'Exact shared writer release token required')
        return {'before': before, 'hot': hot, 'retained': retained, 'after': alone(budget, provider),
                'file': file, 'page_checksum': checksum}
    need(args.case == 'shared-observer', 'A supported shared-page role is required')
    save(marker(output, '.ready.json'), {'before': before})
    writer = json.loads(wait_file(output.with_name(prefix + '-shared-load.ready.json')).read_bytes())
    file = shared_file_identity(path)
    need(file == writer['file'] and file['sha256'] == shared_signature(), 'Both processes must open the same complete shared file')
    with path.open('rb') as stream:
        with mmap.mmap(stream.fileno(), SHARED_BYTES, access=mmap.ACCESS_READ) as pages:
            checksum = sum(pages[offset] for offset in range(0, SHARED_BYTES, 4096))
            need(checksum == SHARED_BYTES // 4096, 'Every shared reader page must be consumed')
            during = context(budget, provider)
            save(marker(output, '.sampled.json'), {'during': during, 'file': file, 'page_checksum': checksum})
            need(json.loads(wait_file(marker(output, '.release')).read_bytes()) == {'token': args.token},
                 'Exact shared reader release token required')
    return {'before': before, 'during': during, 'after': alone(budget, provider),
            'file': file, 'page_checksum': checksum, 'writer_hot': writer}


def cgroup_write_refusal():
    try:
        descriptor = os.open('/sys/fs/cgroup/cgroup.procs', os.O_WRONLY | os.O_NOFOLLOW)
    except OSError as error:
        need(error.errno in (errno.EROFS, errno.EACCES, errno.EPERM), 'The cgroup write must refuse at its permission boundary')
        return error.errno
    os.close(descriptor)
    raise RuntimeError('The read-only cgroup must refuse a mutation handle')


def host_identity(args, budget):
    pid = args.host_pid
    identity = process_identity(budget, pid)
    membership = budget.read_small(Path('/proc') / str(pid) / 'cgroup')
    need(membership.startswith('0::/') and membership.endswith('\n') and membership.count('\n') == 1,
         'One complete host cgroup membership required')
    path = Path(membership[3:].strip())
    need(path.name == 'docker-' + args.container_id + '.scope', 'The host path must bind the exact Docker identity')
    key = (Path('/sys/fs/cgroup') / str(path).lstrip('/')).stat()
    need(process_identity(budget, pid) == identity, 'The live host process identity must remain stable')
    print(json.dumps({'container_id': args.container_id, 'identity': identity, 'membership': membership,
                     'cgroup_path': str(path), 'cgroup_key': {'device': key.st_dev, 'inode': key.st_ino}}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', choices=('direct', 'fork-exec', 'detached', 'rss-overlap', 'observer', 'load',
                                         'shared-observer', 'shared-load'))
    parser.add_argument('--worker', choices=('allocate', 'hold', 'fork-exec', 'detach'))
    parser.add_argument('--output')
    parser.add_argument('--token')
    parser.add_argument('--pins-sha256', required=True)
    parser.add_argument('--host-pid', type=int)
    parser.add_argument('--container-id')
    args = parser.parse_args()
    budget = verify_sources(args.pins_sha256)
    if args.host_pid:
        need(os.geteuid() == 0 and re.fullmatch('[0-9a-f]{64}', args.container_id or '') is not None,
             'Read-only host identity needs its exact owned container and metadata access')
        host_identity(args, budget)
        return
    need(args.case and args.output and re.fullmatch('[0-9]+-[0-9]+', args.token or '') is not None,
         'A complete source-bound probe identity is required')
    need(Path(args.output).parent == Path('/evidence') and os.getuid() == 501,
         'The fixed non-root owned evidence perimeter is required')
    provider = budget.CurrentCgroup(budget.Limits(STRICT_BYTES, os.sysconf('SC_PAGE_SIZE')))
    if args.worker:
        worker(args, budget, provider)
        return
    need(os.getpid() == 1, 'The dedicated supervisor must own its PID namespace')
    report = {'format': 'atlas-build-descendant-probe-v1', 'case': args.case, 'passed': False,
              'token': args.token, 'optimized_python': not __debug__, 'source_pins_sha256': args.pins_sha256,
              'provider_pins_sha256': PROVIDER_PINS, 'runtime_sha256': digest(Path(sys.executable).resolve()),
              'cgroup_write_refusal_errno': cgroup_write_refusal(),
              'compiler_rss_accepted': False, 'complete_Grant_build_accepted': False, 'actual_Grant_cells': 0}
    try:
        if args.case == 'rss-overlap':
            result = overlapping_rss(args, budget, provider)
        elif args.case in ('shared-observer', 'shared-load'):
            result = shared_pages(args, budget, provider)
        elif args.case in ('direct', 'fork-exec', 'detached'):
            result = run_child(args, budget, provider)
        else:
            result = sibling(args, budget, provider)
        report.update(result)
        verify_sources(args.pins_sha256)
        report['passed'] = True
    except BaseException as error:
        report['error'] = {'type': type(error).__name__, 'message': str(error)}
        raise
    finally:
        save(Path(args.output), report)


if __name__ == '__main__':
    main()
