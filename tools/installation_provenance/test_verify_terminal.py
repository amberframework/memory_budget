"""Alter complete four-container evidence packets and exercise the actual reader."""
from pathlib import Path
import copy
import json
import tempfile
import unittest
import cgroup_budget as budget
import verify_terminal as reader


class TerminalControls(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.pins = 'a'*64
        self.image_id = 'sha256:'+'b'*64
        self.files = {'image-inspect.json': [dict(Id=self.image_id,
            RepoDigests=['python@'+reader.IMAGE.split('@')[1]], Config=dict(Env=['PATH=/usr/local/bin:/usr/bin:/bin']))]}
        limits = budget.Limits(512*2**20, 4096)
        sample = budget.Snapshot(limits.hard_memory_bytes, 16*2**20, 32*2**20,
            0, 0, '100000 100000\n', 0, 64, 1,
            dict(low=0, high=0, max=0, oom=0, oom_kill=0))
        for index, selected in enumerate(('ordinary', 'optimized', 'oom', 'uncapped'), 1):
            cap = limits.hard_memory_bytes if index <= 2 else (64*2**20-4096 if index == 3 else 0)
            command = ['python3', '-I', '-S', '-B']+(['-O'] if selected == 'optimized' else [])
            command.extend(['/source/run_controls.py', '--pins-sha256', self.pins,
                '--mode', 'oom-probe' if selected == 'oom' else 'uncapped-probe' if selected == 'uncapped' else 'controls',
                '--strict-memory-bytes', str(64*2**20 if selected == 'oom' else 512*2**20),
                '--output', '/evidence/'+selected+'.json'])
            self.files[selected+'.inspect.json'] = [dict(Id=str(index)*64, Image=self.image_id,
                Config=dict(Image=reader.IMAGE, User='501:501', Cmd=command, Entrypoint=None,
                            Env=['PATH=/usr/local/bin:/usr/bin:/bin']),
                State=dict(Status='exited', Running=False, Paused=False, Restarting=False,
                    Dead=False, Error='', ExitCode=(137 if index == 3 else 2 if index == 4 else 0),
                    OOMKilled=index == 3),
                HostConfig=dict(NetworkMode='none', ReadonlyRootfs=True, NanoCpus=1_000_000_000,
                    PidsLimit=64, Privileged=False, CgroupnsMode='private', AutoRemove=False,
                    CapDrop=['ALL'], SecurityOpt=['no-new-privileges'], Memory=cap, MemorySwap=cap,
                    Tmpfs={'/tmp': 'rw,nosuid,nodev,noexec,size=384m,mode=1777'}),
                Mounts=[dict(Type='bind', Destination='/source', RW=False),
                        dict(Type='bind', Destination='/evidence', RW=True)])]
            result = dict(format='atlas-linux-installation-control-result-v1',
                source_manifest_sha256=self.pins, actual_Homebrew_commands=0,
                actual_Crystal_compilations=0, actual_Grant_cells=0)
            if index <= 2:
                result.update(limits=budget.asdict(limits), before=budget.asdict(sample),
                    after=budget.asdict(sample), passed=True, tests_run=58, failures=0, errors=0,
                    skipped=0, expected_failures=0, unexpected_successes=0,
                    optimized_python=selected == 'optimized')
            elif index == 3:
                result.update(admitted=True, expected_termination='kernel-cgroup-OOM')
            else:
                result.update(refused_before_workload=True, tests_run=0,
                              reason='A complete finite nonnegative decimal value is required')
            self.files[selected+'.json'] = result

    def validate(self):
        for name, value in self.files.items():
            (self.root/name).write_text(json.dumps(value))
        return reader.validate(self.root, self.pins)

    def inspect(self, selected='ordinary'):
        return self.files[selected+'.inspect.json'][0]

    def test_complete_packet_accepts_all_four_distinct_controls(self):
        result = self.validate()
        self.assertTrue(result['passed'])
        self.assertEqual(4, len(result['cases']))
        self.assertFalse(result['Grant_under_2GB_accepted'])

    def test_exit137_without_kernel_OOM_flag_refuses(self):
        self.inspect('oom')['State']['OOMKilled'] = False
        with self.assertRaisesRegex(RuntimeError, 'kernel OOM'):
            self.validate()

    def test_kernel_OOM_flag_with_other_exit_refuses(self):
        self.inspect('oom')['State']['ExitCode'] = 1
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_uncapped_probe_running_tests_refuses(self):
        self.files['uncapped.json']['tests_run'] = 1
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_uncapped_ordinary_container_refuses(self):
        self.inspect()['HostConfig']['Memory'] = 0
        with self.assertRaises(RuntimeError):
            self.validate()
        self.inspect()['HostConfig']['Memory'] = 512*2**20-4096
        self.files['ordinary.json']['limits']['strict_memory_bytes'] = 2_000_000_000
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_writable_source_mount_refuses(self):
        self.inspect()['Mounts'][0]['RW'] = True
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_extra_host_mount_refuses(self):
        self.inspect()['Mounts'].append(dict(Type='bind', Destination='/extra', RW=False))
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_changed_registry_digest_or_container_image_refuses(self):
        original = copy.deepcopy(self.files)
        self.files['image-inspect.json'][0]['RepoDigests'] = ['python@sha256:'+'c'*64]
        with self.assertRaises(RuntimeError):
            self.validate()
        self.files = original
        self.inspect()['Image'] = 'sha256:'+'c'*64
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_reused_container_identity_refuses(self):
        self.inspect('optimized')['Id'] = self.inspect()['Id']
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_skipped_expected_failure_and_missing_case_refuse(self):
        original = copy.deepcopy(self.files)
        for field, value in (('skipped', 1), ('expected_failures', 1), ('tests_run', 53)):
            self.files = copy.deepcopy(original)
            self.files['ordinary.json'][field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                self.validate()

    def test_optimized_cohort_mislabeled_refuses(self):
        self.files['optimized.json']['optimized_python'] = False
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_changed_source_manifest_refuses(self):
        original = copy.deepcopy(self.files)
        self.files['ordinary.json']['source_manifest_sha256'] = 'c'*64
        with self.assertRaises(RuntimeError):
            self.validate()
        self.files = original
        self.inspect()['Config']['Cmd'][-1] = '/evidence/replaced.json'
        with self.assertRaises(RuntimeError):
            self.validate()
        self.inspect()['Config']['Cmd'][-1] = '/evidence/ordinary.json'
        self.inspect()['Config']['Env'].append('PYTHONPATH=/other')
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_host_namespace_or_raised_CPU_quota_refuses(self):
        original = copy.deepcopy(self.files)
        for field, value in (('CgroupnsMode', 'host'), ('NanoCpus', 2_000_000_000)):
            self.files = copy.deepcopy(original)
            self.inspect()['HostConfig'][field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                self.validate()

    def test_additional_swap_capacity_refuses(self):
        self.inspect()['HostConfig']['MemorySwap'] *= 2
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_nonterminal_container_refuses(self):
        self.inspect()['State'].update(Status='running', Running=True)
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_wrong_tmpfs_size_or_kind_refuses(self):
        original = copy.deepcopy(self.files)
        self.inspect()['HostConfig']['Tmpfs']['/tmp'] += ',size=3g'
        with self.assertRaises(RuntimeError):
            self.validate()
        self.files = original
        self.inspect()['Mounts'].append(dict(Type='volume', Destination='/tmp', RW=True))
        with self.assertRaises(RuntimeError):
            self.validate()

    def test_reported_pass_with_overbudget_peak_refuses(self):
        self.files['ordinary.json']['after']['memory_peak'] = 512*2**20
        with self.assertRaises(budget.BudgetRefused):
            self.validate()

    def test_documented_separate_tmpfs_mount_and_security_spelling_accept(self):
        self.inspect()['Mounts'].append(dict(Type='tmpfs', Destination='/tmp', RW=True))
        self.inspect()['HostConfig']['SecurityOpt'] = ['no-new-privileges=true']
        self.assertTrue(self.validate()['passed'])


if __name__ == '__main__':
    unittest.main()
