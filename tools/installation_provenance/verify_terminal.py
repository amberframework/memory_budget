"""Require both inner behavior results and external container terminal evidence."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys


IMAGE = 'python:3.12.10-slim@sha256:fd95fa221297a88e1cf49c55ec1828edd7c5a428187e67b5d1805692d11588db'


def require(value, message):
    if not value:
        raise RuntimeError(message)


def read_json(path, maximum=1024*1024):
    raw = path.read_bytes()
    require(0 < len(raw) <= maximum, 'A complete bounded evidence file is required')
    return json.loads(raw)


def validate(root, pins_hash):
    import cgroup_budget as budget
    image = read_json(root/'image-inspect.json')
    require(type(image) is list and len(image) == 1
            and re.fullmatch('sha256:[0-9a-f]{64}', image[0]['Id']) is not None
            and any(value in image[0]['RepoDigests'] for value in (
                'python@sha256:fd95fa221297a88e1cf49c55ec1828edd7c5a428187e67b5d1805692d11588db',
                'docker.io/library/python@sha256:fd95fa221297a88e1cf49c55ec1828edd7c5a428187e67b5d1805692d11588db')),
            'The actual local image must retain the reviewed registry digest')
    accepted = []
    identities = set()
    for selected in ('ordinary', 'optimized', 'oom', 'uncapped'):
        value = read_json(root/(selected+'.inspect.json'))
        require(type(value) is list and len(value) == 1, 'Exactly one owned container is required')
        container = value[0]
        require(re.fullmatch('[0-9a-f]{64}', container['Id']) is not None,
                'An exact Docker container identity is required')
        require(container['Id'] not in identities and container['Image'] == image[0]['Id'],
                'Each control needs a distinct container of the actual pinned image')
        identities.add(container['Id'])
        state, host = container['State'], container['HostConfig']
        expected_command = ['python3', '-I', '-S', '-B']
        if selected == 'optimized':
            expected_command.append('-O')
        expected_mode = 'oom-probe' if selected == 'oom' else 'uncapped-probe' if selected == 'uncapped' else 'controls'
        expected_budget = str(64*2**20 if selected == 'oom' else 512*2**20)
        expected_command.extend(['/source/run_controls.py', '--pins-sha256', pins_hash,
            '--mode', expected_mode, '--strict-memory-bytes', expected_budget,
            '--output', '/evidence/'+selected+'.json'])
        require(container['Config']['Cmd'] == expected_command
                and container['Config']['Entrypoint'] is None
                and container['Config']['Env'] == image[0]['Config']['Env'],
                'The exact case command and pinned image environment are required')
        require(state['Status'] == 'exited' and state['Running'] is False
                and state['Paused'] is False and state['Restarting'] is False
                and state['Dead'] is False and state['Error'] == '',
                'The owned container must reach an unambiguous terminal state')
        require(container['Config']['Image'] == IMAGE and host['NetworkMode'] == 'none'
                and host['ReadonlyRootfs'] is True and host['NanoCpus'] == 1_000_000_000
                and host['PidsLimit'] == 64 and host['Privileged'] is False
                and host['CgroupnsMode'] == 'private' and host['AutoRemove'] is False,
                'The reviewed finite isolated container profile must remain active')
        require(host['CapDrop'] == ['ALL'] and host['SecurityOpt'] in (
                ['no-new-privileges'], ['no-new-privileges=true']),
                'The reduced-privilege container profile must remain active')
        require(container['Config']['User'] == '501:501', 'The ordinary non-root test identity is required')
        require(sorted((item['Destination'], item['RW']) for item in container['Mounts']
                       if item['Type'] == 'bind')
                == [('/evidence', True), ('/source', False)],
                'Only read-only source and the owned evidence mount are admitted')
        others = [item for item in container['Mounts'] if item['Type'] != 'bind']
        require(others == [] or (len(others) == 1 and others[0]['Type'] == 'tmpfs'
                and others[0]['Destination'] == '/tmp' and others[0]['RW'] is True),
                'Any separately reported temporary mount must be the exact private tmpfs')
        require(set(host['Tmpfs']) == {'/tmp'}
                and sorted(host['Tmpfs']['/tmp'].split(','))
                == sorted(['rw', 'nosuid', 'nodev', 'noexec', 'size=384m', 'mode=1777']),
                'The exact private temporary filesystem ceiling is required')
        result = read_json(root/(selected+'.json'))
        require(result['format'] == 'atlas-linux-installation-control-result-v1'
                and result['source_manifest_sha256'] == pins_hash
                and result['actual_Homebrew_commands'] == result['actual_Crystal_compilations']
                == result['actual_Grant_cells'] == 0,
                'The exact source and installation-protocol-only scope must be retained')
        if selected in ('ordinary', 'optimized'):
            limits = budget.Limits(**result['limits'])
            require(limits.strict_memory_bytes == 512*2**20,
                    'The declared ordinary strict budget must remain exactly512MiB')
            budget.compare_snapshots(budget.Snapshot(**result['before']),
                                     budget.Snapshot(**result['after']), limits)
            hard = limits.hard_memory_bytes
            require(host['Memory'] == host['MemorySwap'] == hard
                    and state['ExitCode'] == 0 and state['OOMKilled'] is False
                    and result['passed'] is True and result['tests_run'] == 54
                    and result['failures'] == result['errors'] == result['skipped']
                    == result['expected_failures'] == result['unexpected_successes'] == 0
                    and result['optimized_python'] is (selected == 'optimized'),
                    'Both exact 54-case cohorts must pass inside their finite kernel ceiling')
        elif selected == 'oom':
            require(host['Memory'] == host['MemorySwap'] == 64*2**20-4096
                    and state['ExitCode'] == 137 and state['OOMKilled'] is True
                    and result['admitted'] is True
                    and result['expected_termination'] == 'kernel-cgroup-OOM',
                    'The small deliberate allocation must reach real kernel OOM termination')
        else:
            require(host['Memory'] == host['MemorySwap'] == 0
                    and state['ExitCode'] == 2 and state['OOMKilled'] is False
                    and result['refused_before_workload'] is True and result['tests_run'] == 0
                    and 'finite' in result['reason'],
                    'An unfenced container must refuse before the workload starts')
        accepted.append(dict(case=selected, container_id=container['Id'],
                             exit_code=state['ExitCode'], OOMKilled=state['OOMKilled']))
    return dict(passed=True, format='atlas-linux-installation-terminal-controls-v1',
                cases=accepted, actual_Grant_cells=0, actual_Homebrew_commands=0,
                installed_SDK_accepted=False, clean_device_installation_accepted=False,
                Grant_under_2GB_accepted=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', required=True)
    parser.add_argument('--pins-sha256', required=True)
    arguments = parser.parse_args()
    source = Path(__file__).resolve().parent
    packet_path = source/'SOURCE_PINS.json'
    require(packet_path.stat().st_size <= 16384
            and hashlib.sha256(packet_path.read_bytes()).hexdigest() == arguments.pins_sha256,
            'The exact reviewed source manifest is required before local imports')
    packet = read_json(packet_path, 16384)
    reference = next(item for item in packet['files'] if item['path'] == 'run_controls.py')
    helper = source/'run_controls.py'
    require(helper.resolve(strict=True) == helper and helper.stat().st_size == reference['bytes']
            and hashlib.sha256(helper.read_bytes()).hexdigest() == reference['sha256'],
            'The source-verification helper must retain its exact physical bytes')
    sys.path.insert(0, str(source))
    from run_controls import verify_sources
    verify_sources(source, packet_path, arguments.pins_sha256)
    result = validate(Path(arguments.evidence), arguments.pins_sha256)
    (Path(arguments.evidence)/'TERMINAL_ACCEPTANCE.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    sys.exit(main())
