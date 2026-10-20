"""Run fresh source-bound descendant/sibling containers and return every owner."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
IMAGE = 'python:3.12.10-slim@sha256:fd95fa221297a88e1cf49c55ec1828edd7c5a428187e67b5d1805692d11588db'


def need(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pins-sha256', required=True)
    parser.add_argument('--runner-metadata', required=True)
    args = parser.parse_args()
    manifest = HERE / 'SOURCE_PINS.json'
    need(digest(manifest) == args.pins_sha256, 'Exact reviewed whole-build probe sources required')
    rows = json.loads(manifest.read_bytes())['files']
    row = next(item for item in rows if item['path'] == 'probe.py')
    need(digest(HERE / 'probe.py') == row['sha256'], 'Exact source admission helper required')
    sys.path.insert(0, str(HERE))
    import probe
    budget = probe.verify_sources(args.pins_sha256)
    metadata = json.loads(Path(args.runner_metadata).read_bytes())
    need(metadata['admitted'] is True, 'The actual hosted runner must already be admitted')
    profile = metadata['profile']
    need(digest(Path(sys.executable).resolve()) == profile['python_sha256']
         and digest(Path('/usr/bin/docker')) == profile['docker_cli_sha256']
         and digest(Path('/usr/bin/sudo')) == profile['sudo_sha256'], 'Actual host tools must retain reviewed identities')
    runner_source = ROOT / 'tools/installation_provenance/record_linux_runner.py'
    need(digest(runner_source) == metadata['collector']['sha256'], 'Exact actual profile matcher required')
    sys.path.insert(0, str(runner_source.parent))
    import record_linux_runner
    record_linux_runner.reviewed_profile(json.loads((runner_source.parent / 'runner_profile.json').read_bytes()), profile)
    token = os.environ['GITHUB_RUN_ID'] + '-' + os.environ['GITHUB_RUN_ATTEMPT']
    need(re.fullmatch('[0-9]+-[0-9]+', token) is not None, 'Exact hosted run/attempt identity required')
    evidence = HERE / ('ci-evidence-' + token)
    evidence.mkdir(mode=0o777)
    evidence.chmod(0o777)
    config = evidence / 'docker-config'
    config.mkdir(mode=0o700)
    docker = ['/usr/bin/docker', '--host', 'unix:///var/run/docker.sock', '--config', str(config)]
    environment = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}
    owners = []
    report = {'format': 'atlas-build-descendant-host-result-v1', 'passed': False,
              'source_pins_sha256': args.pins_sha256, 'token': token, 'owners': owners,
              'actual_Grant_cells': 0}

    def call(command, seconds=30, check=True):
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=seconds, env=environment)
        need(len(result.stdout) <= 2**20 and len(result.stderr) <= 2**20, 'Bounded complete tool output required')
        if check:
            need(result.returncode == 0, 'Tool failed: ' + ' '.join(command[:4]) + ': ' + result.stderr.decode(errors='replace'))
        return result

    def inspect(owner):
        value = json.loads(call(docker + ['inspect', owner['name']]).stdout)
        need(len(value) == 1 and value[0]['Config']['Labels'].get('org.amberframework.atlas.run') == token,
             'Every mutation must bind the exact owned run label')
        if owner.get('id'):
            need(value[0]['Id'] == owner['id'], 'Actual container identity must remain stable')
        else:
            owner['id'] = value[0]['Id']
        return value

    def create(mode, case):
        selected = mode + '-' + case
        name = 'atlas-build-' + token + '-' + selected
        need(call(docker + ['ps', '--all', '--quiet', '--no-trunc', '--filter', 'name=^/' + name + '$']).stdout == b'',
             'A fresh exact owned container name is required')
        owner = {'name': name, 'case': case, 'mode': mode, 'selected': selected, 'id': None, 'removed': False}
        owners.append(owner)
        flags = ['python3', '-I', '-S', '-B'] + (['-O'] if mode == 'optimized' else [])
        command = docker + ['create', '--name', name, '--label', 'org.amberframework.atlas.run=' + token,
            '--label', 'org.amberframework.atlas.probe=' + selected, '--network', 'none', '--cpus', '1',
            '--memory', '536866816', '--memory-swap', '536866816', '--pids-limit', '64',
            '--cgroupns', 'private', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
            '--user', '501:501', '--mount', 'type=bind,src=' + str(ROOT) + ',dst=/workspace,readonly',
            '--mount', 'type=bind,src=' + str(evidence) + ',dst=/evidence', IMAGE] + flags + [
            '/workspace/tools/whole_build_memory/probe.py', '--case', case,
            '--output', '/evidence/' + selected + '.json', '--token', token, '--pins-sha256', args.pins_sha256]
        result = call(command)
        identity = result.stdout.decode().strip()
        need(re.fullmatch('[0-9a-f]{64}', identity) is not None, 'Complete actual Docker identity required')
        owner['id'] = identity
        return owner

    def finish(owner):
        result = call(docker + ['wait', owner['id']], seconds=35)
        (evidence / (owner['selected'] + '.wait.txt')).write_bytes(result.stdout)
        value = inspect(owner)
        (evidence / (owner['selected'] + '.inspect.json')).write_text(json.dumps(value, indent=2) + '\n')
        logs = call(docker + ['logs', owner['id']], check=False)
        (evidence / (owner['selected'] + '.stdout.txt')).write_bytes(logs.stdout)
        (evidence / (owner['selected'] + '.stderr.txt')).write_bytes(logs.stderr)
        need(result.stdout == b'0\n', 'Every normal probe must complete with its actual zero exit')

    def ready(path):
        deadline = time.monotonic() + 25
        while not path.is_file():
            need(time.monotonic() < deadline, 'Bounded source-owned rendezvous required: ' + path.name)
            time.sleep(.02)

    try:
        need(call(docker + ['version', '--format', '{{.Server.Version}}']).stdout.decode().strip()
             == profile['docker_server_version'], 'Actual Docker daemon version must retain its identity')
        image = json.loads(call(docker + ['image', 'inspect', IMAGE]).stdout)
        (evidence / 'image-inspect.json').write_text(json.dumps(image, indent=2) + '\n')
        for mode in ('ordinary', 'optimized'):
            for case in ('direct', 'fork-exec', 'detached'):
                owner = create(mode, case)
                call(docker + ['start', owner['id']])
                finish(owner)
            observer, load = create(mode, 'observer'), create(mode, 'load')
            call(docker + ['start', observer['id']])
            ready(evidence / (mode + '-observer.ready.json'))
            call(docker + ['start', load['id']])
            ready(evidence / (mode + '-observer.sampled.json'))
            host_rows = []
            for owner in (observer, load):
                current = inspect(owner)[0]
                need(current['State']['Running'] is True and current['State']['Pid'] > 0,
                     'Both sibling probes must be alive at the host identity checkpoint')
                command = ['/usr/bin/sudo', '--non-interactive', '/usr/bin/python3', '-I', '-S', '-B',
                    str(HERE / 'probe.py'), '--pins-sha256', args.pins_sha256, '--host-pid',
                    str(current['State']['Pid']), '--container-id', owner['id']]
                host_rows.append(json.loads(call(command).stdout))
            (evidence / (mode + '-sibling-host.json')).write_text(json.dumps(host_rows, indent=2) + '\n')
            for owner in (observer, load):
                probe.save(evidence / (owner['selected'] + '.release'), {'token': token})
            finish(observer)
            finish(load)
        probe.verify_sources(args.pins_sha256)
        import verify_results
        report['verification'] = verify_results.validate(evidence, args.pins_sha256, token)
        report['sensitivity_controls'] = verify_results.sensitivity_controls(evidence, args.pins_sha256, token)
        report['passed'] = True
    except BaseException as error:
        report['error'] = {'type': type(error).__name__, 'message': str(error)}
        raise
    finally:
        errors = []
        for owner in owners:
            try:
                value = inspect(owner)
                (evidence / (owner['selected'] + '.cleanup-before.json')).write_text(json.dumps(value, indent=2) + '\n')
                result = call(docker + ['rm', '--force', owner['id']])
                need(result.stdout.decode().strip() == owner['id'], 'Exact owned removal identity required')
                (evidence / (owner['selected'] + '.cleanup.txt')).write_bytes(result.stdout)
                absent = call(docker + ['ps', '--all', '--no-trunc', '--filter', 'id=' + owner['id'], '--format', '{{.ID}}']).stdout
                (evidence / (owner['selected'] + '.cleanup-after.txt')).write_bytes(absent)
                need(absent == b'', 'Every owned container must read back absent')
                owner['removed'] = True
            except BaseException as error:
                errors.append({'name': owner['name'], 'message': str(error)})
        report['cleanup_errors'] = errors
        report['passed'] = report['passed'] and not errors and len(owners) == 10 and all(item['removed'] for item in owners)
        (evidence / 'HOST_RESULT.json').write_text(json.dumps(report, indent=2) + '\n')
        need(report['passed'], 'Complete probe verification and exact container return required')
    print(json.dumps({'passed': True, 'owned_containers_removed': len(owners), 'actual_Grant_cells': 0}))


if __name__ == '__main__':
    main()
