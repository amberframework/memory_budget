"""Run the installation protocol controls inside an externally fenced container."""
from pathlib import Path
import argparse
import datetime
import hashlib
import io
import json
import os
import re
import stat
import sys
import unittest


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(65536), b''):
            result.update(block)
    return result.hexdigest()


def verify_sources(root, manifest, expected):
    require(re.fullmatch('[0-9a-f]{64}', expected) is not None and digest(manifest) == expected,
            'The caller must supply the exact approved source-manifest digest')
    require(manifest.stat().st_size <= 16384, 'The source manifest must fit 16 KiB')
    packet = json.loads(manifest.read_text())
    require(packet['format'] == 'atlas-linux-control-sources-v1'
            and 1 <= len(packet['files']) <= 16, 'A finite versioned source roster is required')
    names = set()
    for row in packet['files']:
        name = row['path']
        require(type(name) is str and '/' not in name and name not in ('.', '..')
                and name not in names, 'Unique source basenames are required')
        names.add(name)
        path = root/name
        status = path.lstat()
        require(path.resolve(strict=True) == path and stat.S_ISREG(status.st_mode)
                and status.st_size == row['bytes'] <= 1024*1024
                and stat.S_IMODE(status.st_mode) == row['mode']
                and digest(path) == row['sha256'], 'An approved physical source changed: '+name)
    require(names == {'cgroup_budget.py', 'test_cgroup_budget.py', 'native_image_protocol.py',
                      'test_native_image_protocol.py', 'run_controls.py',
                      'verify_terminal.py', 'test_verify_terminal.py'},
            'The exact complete executable source roster is required')
    return packet


class BoundedText(io.StringIO):
    def write(self, value):
        require(self.tell()+len(value) <= 128*1024, 'The complete test log must fit 128 KiB')
        return super().write(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pins-sha256', required=True)
    parser.add_argument('--mode', choices=('controls', 'oom-probe', 'uncapped-probe'), required=True)
    parser.add_argument('--strict-memory-bytes', required=True, type=int)
    parser.add_argument('--output', required=True)
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parent
    output = Path(arguments.output)
    require(output.is_absolute() and output.parent.resolve(strict=True) == output.parent,
            'A physical absolute output directory is required')
    sources = verify_sources(root, root/'SOURCE_PINS.json', arguments.pins_sha256)
    sys.path.insert(0, str(root))
    import cgroup_budget as budget
    report = dict(format='atlas-linux-installation-control-result-v1', passed=False,
                  mode=arguments.mode, started_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  source_manifest_sha256=arguments.pins_sha256, python_version=sys.version,
                  python_executable=str(Path(sys.executable).resolve()),
                  python_sha256=digest(Path(sys.executable).resolve()),
                  kernel=os.uname().release, platform=os.uname().machine,
                  actual_Homebrew_commands=0, actual_Crystal_compilations=0,
                  actual_Grant_cells=0, source_files=len(sources['files']))
    try:
        limits = budget.Limits(arguments.strict_memory_bytes, os.sysconf('SC_PAGE_SIZE'))
        provider = budget.CurrentCgroup(limits)
        before = provider.snapshot()
    except budget.BudgetRefused as error:
        report.update(refused_before_workload=True, reason=str(error), tests_run=0)
        output.write_text(json.dumps(report, indent=2)+'\n')
        return 2
    require(arguments.mode != 'uncapped-probe', 'The uncapped negative probe unexpectedly passed admission')
    if arguments.mode == 'oom-probe':
        require(arguments.strict_memory_bytes == 64*2**20, 'The OOM control uses its exact 64 MiB budget')
        report.update(admitted=True, before=budget.asdict(before), expected_termination='kernel-cgroup-OOM')
        output.write_text(json.dumps(report, indent=2)+'\n')
        print('ATLAS_OOM_PROBE_ADMITTED', flush=True)
        allocation = bytearray(128*2**20)
        for offset in range(0, len(allocation), limits.page_size):
            allocation[offset] = 1
        require(len(allocation) == 0, 'The kernel OOM control unexpectedly completed its128MiB allocation')
    require(arguments.strict_memory_bytes == 512*2**20, 'The ordinary controls use their exact 512 MiB budget')
    import test_cgroup_budget
    import test_native_image_protocol
    import test_verify_terminal
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromModule(module)
                               for module in (test_cgroup_budget, test_native_image_protocol,
                                              test_verify_terminal))
    require(suite.countTestCases() == 54, 'The exact 54 authored controls are required')
    stream = BoundedText()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    verify_sources(root, root/'SOURCE_PINS.json', arguments.pins_sha256)
    after = provider.snapshot()
    report.update(budget.compare_snapshots(before, after, limits),
                  tests_run=result.testsRun, failures=len(result.failures), errors=len(result.errors),
                  skipped=len(result.skipped), expected_failures=len(result.expectedFailures),
                  unexpected_successes=len(result.unexpectedSuccesses),
                  optimized_python=not __debug__, log=stream.getvalue(),
                  finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
    report['passed'] = (result.wasSuccessful() and result.testsRun == 54
                        and not result.skipped and not result.expectedFailures
                        and not result.unexpectedSuccesses)
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({key: report[key] for key in ('passed', 'tests_run', 'failures', 'errors',
                                                 'optimized_python', 'hard_memory_bytes')}))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
