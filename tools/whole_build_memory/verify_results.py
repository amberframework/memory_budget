"""Independently verify actual descendant, sibling, command and terminal evidence."""
from pathlib import Path
import copy
import json
import re

import probe

CASES = ('direct', 'fork-exec', 'detached', 'observer', 'load')
IMAGE = 'python:3.12.10-slim@sha256:fd95fa221297a88e1cf49c55ec1828edd7c5a428187e67b5d1805692d11588db'
RUNTIME = '4dbf3143240288fb2170257ffaa7bd030cdda5d2703d1f5f30b627042267e2e3'


def need(value, message):
    if not value:
        raise RuntimeError(message)


def read(path):
    need(path.is_file() and not path.is_symlink() and path.stat().st_size <= 2**20,
         'A bounded physical actual result is required')
    return json.loads(path.read_bytes())


def identity(value):
    need(isinstance(value, dict) and set(value) == {'pid', 'ppid', 'pgid', 'sid', 'start_ticks'}
         and all(type(item) is int and item >= 0 for item in value.values())
         and value['pid'] > 0 and value['start_ticks'] > 0, 'Complete typed kernel process identity required')
    return value


def context(value, budget):
    identity(value['identity'])
    key = value['cgroup_key']
    need(set(key) == {'device', 'inode'} and all(type(item) is int and item > 0 for item in key.values()),
         'Complete typed physical cgroup identity required')
    members = value['members']
    need(type(members) is list and 0 < len(members) <= 64
         and all(type(item) is int and item > 0 for item in members)
         and sorted(set(members)) == members and value['identity']['pid'] in members,
         'A complete unique live process roster is required')
    need(value['membership'] == '0::/\n' and type(value['monotonic_ns']) is int and value['monotonic_ns'] > 0,
         'The private cgroup membership and monotonic observation are required')
    snapshot = budget.Snapshot(**value['snapshot'])
    budget.verify_snapshot(snapshot, budget.Limits(probe.STRICT_BYTES, 4096))
    need(snapshot.pids_current >= len(members), 'Process slots must cover the live member roster')
    return value


def validate_single(value, case, mode, pins, token, budget):
    need(value['format'] == 'atlas-build-descendant-probe-v1' and value['case'] == case
         and value['passed'] is True and value['token'] == token
         and value['optimized_python'] is (mode == 'optimized')
         and value['source_pins_sha256'] == pins and value['provider_pins_sha256'] == probe.PROVIDER_PINS
         and value['runtime_sha256'] == RUNTIME and value['actual_Grant_cells'] == 0
         and value['compiler_rss_accepted'] is False and value['complete_Grant_build_accepted'] is False,
         'Exact source, runtime, case and qualification scope required')
    before, after = context(value['before'], budget), context(value['after'], budget)
    need(before['identity'] == after['identity'] and before['identity']['pid'] == 1
         and before['members'] == after['members'] == [1]
         and before['snapshot']['pids_current'] == after['snapshot']['pids_current'] == 1
         and before['cgroup_key'] == after['cgroup_key'], 'One stable supervisor and complete worker retirement required')
    budget.compare_snapshots(budget.Snapshot(**before['snapshot']), budget.Snapshot(**after['snapshot']),
                             budget.Limits(probe.STRICT_BYTES, 4096))
    need(after['monotonic_ns'] > before['monotonic_ns'], 'The final window must follow workload entry')
    if case in ('observer', 'load'):
        selected = 'during' if case == 'observer' else 'hot'
        hot = context(value[selected], budget)
        need(hot['cgroup_key'] == before['cgroup_key'] and hot['identity'] == before['identity']
             and hot['members'] == [1] and before['monotonic_ns'] <= hot['monotonic_ns'] <= after['monotonic_ns'],
             'The sibling sample must retain its exact owner and window')
        need(after['snapshot']['memory_peak'] >= hot['snapshot']['memory_peak'], 'The sibling lifetime peak must persist')
        if case == 'load':
            need(value['allocation_bytes'] == probe.SIBLING_BYTES
                 and hot['snapshot']['memory_current'] >= probe.SIBLING_BYTES,
                 'The real private sibling allocation must be observed')
        else:
            need(hot['snapshot']['memory_peak'] < probe.SIBLING_BYTES // 2,
                 'Sibling private allocation must remain outside the observer budget')
        return
    need(value['worker_exit_code'] == 0 and type(value['launcher_pid']) is int and value['launcher_pid'] > 1,
         'An actual completed worker identity required')
    rows = value['worker_records']
    if case == 'detached':
        need(len(rows) == 1 and rows[0]['stage'] == 'detached', 'Exact detached launcher roster required')
        detached = value['detached']
        hot = context(detached['hot'], budget)
        launcher, adopted = identity(rows[0]['launcher']), identity(detached['adopted_identity'])
        need(launcher['pid'] == value['launcher_pid'] and launcher['ppid'] == 1
             and rows[0]['child_pid'] == hot['identity']['pid'] == adopted['pid']
             and hot['identity']['ppid'] == launcher['pid'] and adopted['ppid'] == 1
             and adopted['pgid'] == adopted['sid'] == adopted['pid']
             and adopted['start_ticks'] == hot['identity']['start_ticks']
             and detached['exit_code'] == 0 and detached['optimized_python'] is (mode == 'optimized'),
             'Detached process/session identity, adoption, mode and normal join required')
        observed = context(detached['observed_after_launcher_exit'], budget)
        need(observed['members'] == sorted([1, adopted['pid']])
             and observed['cgroup_key'] == before['cgroup_key'] and value['parent_live_child_polls'] == 1,
             'The detached worker must be observed after its launcher retires')
        allocation = detached
    else:
        need(type(rows) is list and len(rows) == (1 if case == 'direct' else 3), 'Complete worker/exec record roster required')
        stages = {row['stage']: row for row in rows}
        need(len(stages) == len(rows) and set(stages) == ({'allocation'} if case == 'direct'
             else {'before-exec', 'allocation', 'joined'}), 'Unique required worker stages must be present')
        allocation = stages['allocation']
        hot = context(allocation['hot'], budget)
        context(allocation['before'], budget)
        need(allocation['optimized_python'] is (mode == 'optimized') and value['parent_live_child_polls'] == 0,
             'The transient worker must preserve mode while the parent samples entry and final state')
        if case == 'direct':
            need(hot['identity']['pid'] == value['launcher_pid'] and hot['identity']['ppid'] == 1,
                 'The direct allocation must bind the actual child')
        else:
            previous, joined = identity(stages['before-exec']['identity']), stages['joined']
            launcher = identity(joined['launcher'])
            need(previous == hot['identity'] and launcher['pid'] == value['launcher_pid']
                 and launcher['ppid'] == 1 and previous['ppid'] == launcher['pid']
                 and joined['child_pid'] == previous['pid'] and joined['exit_code'] == 0,
                 'The same forked process must exec and be reaped by the actual launcher')
    need(hot['cgroup_key'] == before['cgroup_key'] and hot['membership'] == before['membership']
         and allocation['allocation_bytes'] == probe.CHILD_BYTES and allocation['touched_pages'] == probe.CHILD_BYTES // 4096
         and hot['snapshot']['memory_current'] >= probe.CHILD_BYTES,
         'Every declared private page must be consumed inside the same measured cgroup')
    need(after['snapshot']['memory_peak'] >= hot['snapshot']['memory_peak']
         and after['snapshot']['memory_peak'] >= before['snapshot']['memory_peak'] + probe.CHILD_BYTES // 2
         and after['snapshot']['memory_peak'] - after['snapshot']['memory_current'] >= probe.CHILD_BYTES // 2,
         'The final kernel peak must retain the retired private allocation')


def validate(evidence, pins, token, read_result=read):
    budget = probe.verify_sources(pins)
    image = read_result(evidence / 'image-inspect.json')[0]
    need('python@sha256:' + IMAGE.split('@sha256:')[1] in image['RepoDigests'], 'Actual pinned image digest required')
    identities = set()
    results = {}
    for mode in ('ordinary', 'optimized'):
        for case in CASES:
            selected = mode + '-' + case
            value = read_result(evidence / (selected + '.json'))
            validate_single(value, case, mode, pins, token, budget)
            results[selected] = value
            container = read_result(evidence / (selected + '.inspect.json'))[0]
            flags = ['python3', '-I', '-S', '-B'] + (['-O'] if mode == 'optimized' else [])
            expected = flags + ['/workspace/tools/whole_build_memory/probe.py', '--case', case,
                '--output', '/evidence/' + selected + '.json', '--token', token, '--pins-sha256', pins]
            state, host = container['State'], container['HostConfig']
            need(re.fullmatch('[0-9a-f]{64}', container['Id']) is not None
                 and container['Id'] not in identities and container['Image'] == image['Id']
                 and container['Config']['Image'] == IMAGE and container['Config']['Cmd'] == expected
                 and container['Config']['Entrypoint'] is None and container['Config']['Env'] == image['Config']['Env']
                 and container['Config']['User'] == '501:501', 'Exact distinct image, command, mode and environment required')
            need(container['Config']['Labels'].get('org.amberframework.atlas.run') == token
                 and container['Config']['Labels'].get('org.amberframework.atlas.probe') == selected
                 and sorted((item['Destination'], item['RW']) for item in container['Mounts'])
                 == [('/evidence', True), ('/workspace', False)], 'Exact source/evidence mounts and owned labels required')
            identities.add(container['Id'])
            need(state['Status'] == 'exited' and state['Running'] is False and state['ExitCode'] == 0
                 and state['OOMKilled'] is False and state['Error'] == ''
                 and host['Memory'] == host['MemorySwap'] == 536866816 and host['NanoCpus'] == 1_000_000_000
                 and host['PidsLimit'] == 64 and host['NetworkMode'] == 'none' and host['ReadonlyRootfs'] is True
                 and host['CgroupnsMode'] == 'private' and host['Privileged'] is False and host['CapDrop'] == ['ALL']
                 and host['SecurityOpt'] in (['no-new-privileges'], ['no-new-privileges=true']),
                 'The complete capped nonprivileged case must retire normally')
        observer, load = results[mode + '-observer'], results[mode + '-load']
        need(observer['sibling_hot'] == {'hot': load['hot'], 'allocation_bytes': probe.SIBLING_BYTES},
             'The observer must sample the actual concurrent private load')
        host_rows = read_result(evidence / (mode + '-sibling-host.json'))
        need(len(host_rows) == 2 and Path(host_rows[0]['cgroup_path']).parent == Path(host_rows[1]['cgroup_path']).parent
             and host_rows[0]['cgroup_path'] != host_rows[1]['cgroup_path'], 'Actual host sibling hierarchy required')
        for row, case, result in zip(host_rows, ('observer', 'load'), (observer, load)):
            container = read_result(evidence / (mode + '-' + case + '.inspect.json'))[0]
            need(row['container_id'] == container['Id']
                 and Path(row['cgroup_path']).name == 'docker-' + container['Id'] + '.scope'
                 and row['identity']['start_ticks'] == result['before']['identity']['start_ticks']
                 and row['cgroup_key']['inode'] == result['before']['cgroup_key']['inode'],
                 'Outer Docker/PID/cgroup identity must bind the inner owner')
    return {'passed': True, 'format': 'atlas-build-descendant-verdict-v1',
            'cases': sorted(results), 'distinct_container_ids': sorted(identities),
            'compiler_rss_accepted': False, 'complete_Grant_build_accepted': False, 'actual_Grant_cells': 0}


def sensitivity_controls(evidence, pins, token):
    """Challenge the full validator with changed copies of actual observations."""
    validate(evidence, pins, token)
    controls = []
    for mode in ('ordinary', 'optimized'):
        direct = mode + '-direct.json'
        fork = mode + '-fork-exec.json'
        detached = mode + '-detached.json'
        observer = mode + '-observer.json'
        host = mode + '-sibling-host.json'
        command = mode + '-direct.inspect.json'
        changes = (
            ('lost_retired_peak', direct, lambda value: value['after']['snapshot'].update(
                memory_peak=value['before']['snapshot']['memory_peak'])),
            ('changed_exec_birth', fork, lambda value: value['worker_records'][0]['identity'].update(
                start_ticks=value['worker_records'][0]['identity']['start_ticks'] + 1)),
            ('lost_adoption', detached, lambda value: value['detached']['adopted_identity'].update(
                ppid=value['launcher_pid'])),
            ('omitted_live_orphan', detached, lambda value: value['detached']['observed_after_launcher_exit'].update(
                members=[1])),
            ('mixed_sibling_charge', observer, lambda value: value['during']['snapshot'].update(
                memory_peak=probe.SIBLING_BYTES)),
            ('same_host_cgroup', host, lambda value: value[1].update(cgroup_path=value[0]['cgroup_path'])),
            ('missing_kernel_events', direct, lambda value: value['before']['snapshot'].update(memory_events={})),
            ('changed_command', command, lambda value: value[0]['Config']['Cmd'].append('--changed-command')),
        )
        for label, filename, change in changes:
            changed = copy.deepcopy(read(evidence / filename))
            change(changed)

            def altered(path):
                return copy.deepcopy(changed) if path.name == filename else read(path)

            try:
                validate(evidence, pins, token, read_result=altered)
            except (RuntimeError, KeyError, TypeError, ValueError) as error:
                controls.append({'mode': mode, 'case': label, 'changed_actual_file': filename,
                                 'rejected': True, 'reason': str(error)})
            else:
                raise RuntimeError('Changed actual evidence must be rejected: ' + mode + '/' + label)
    restored = validate(evidence, pins, token)
    return {'passed': True, 'controls': controls, 'restored_actual_accepted': restored['passed']}
