"""Exercise the kernel budget parser with exact positive and changed fixtures."""
from dataclasses import replace
from pathlib import Path
import tempfile
import unittest
import cgroup_budget as budget


MOUNT = '29 23 0:26 / /sys/fs/cgroup ro,nosuid,nodev,noexec,relatime - cgroup2 cgroup rw\n'


class CgroupBudget(unittest.TestCase):
    def setUp(self):
        self.limits = budget.Limits(512*2**20, 4096)
        self.values = {'memory.max': str(self.limits.hard_memory_bytes)+'\n',
            'memory.current': '16777216\n', 'memory.peak': '33554432\n',
            'memory.swap.max': '0\n', 'memory.swap.current': '0\n',
            'cpu.max': '100000 100000\n', 'cpu.max.burst': '0\n',
            'pids.max': '64\n', 'pids.current': '1\n',
            'memory.events': 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n'}

    def snapshot(self, values=None):
        return budget.read_snapshot((self.values if values is None else values).__getitem__)

    def test_finite_profile_accepts_and_preserves_measurement_scope(self):
        value = budget.compare_snapshots(self.snapshot(), self.snapshot(), self.limits)
        self.assertEqual('current-cgroup-and-descendants-through-final-snapshot-v1', value['scope'])
        self.assertFalse(value['complete_Grant_build_accepted'])

    def test_decimal_Grant_target_rounds_down_below_strict_budget(self):
        for page in (4096, 16384, 65536):
            limits = budget.Limits(2_000_000_000, page)
            self.assertLess(limits.hard_memory_bytes, 2_000_000_000)
            self.assertEqual(0, limits.hard_memory_bytes % page)
            self.assertLessEqual(2_000_000_000-limits.hard_memory_bytes, page)

    def test_page_aligned_budget_still_enforces_strict_less_than(self):
        self.assertEqual(512*2**20-4096, self.limits.hard_memory_bytes)

    def test_invalid_typed_limits_refuse(self):
        for values in ((True, 4096), (2_000_000_001, 4096), (4096, 4096),
                       (512*2**20, 10000)):
            with self.subTest(values=values), self.assertRaises(budget.BudgetRefused):
                budget.Limits(*values)

    def test_unqualified_CPU_and_process_profiles_refuse(self):
        for fields in ({'cpu_quota': 200000}, {'maximum_processes': 128},
                       {'cpu_period': 200000}):
            with self.assertRaises(budget.BudgetRefused):
                replace(self.limits, **fields)

    def test_unlimited_negative_boolean_and_incomplete_numbers_refuse(self):
        for raw in ('max\n', '-1\n', '01\n', '1 2\n', '1\n2\n', '', True, '1\n\n'):
            with self.subTest(raw=raw), self.assertRaises(budget.BudgetRefused):
                budget.number(raw)

    def test_exact_readonly_private_cgroup2_mount_accepts(self):
        budget.verify_mount(MOUNT, '0::/\n')

    def test_other_namespace_membership_refuses(self):
        for member in ('0::/host/service\n', '1:memory:/\n', '0::/\n1:cpu:/\n'):
            with self.assertRaises(budget.BudgetRefused):
                budget.verify_mount(MOUNT, member)

    def test_writable_legacy_duplicate_and_missing_mount_refuse(self):
        for mount in (MOUNT.replace('ro,nosuid', 'rw,nosuid'),
                      MOUNT.replace('cgroup2', 'cgroup'), MOUNT+MOUNT, '',
                      '1 2 3 / /sys/fs/cgroup ro - cgroup2\n'):
            with self.subTest(mount=mount), self.assertRaises(budget.BudgetRefused):
                budget.verify_mount(mount, '0::/\n')

    def test_changed_memory_limit_refuses(self):
        for value in (self.limits.hard_memory_bytes+4096, self.limits.hard_memory_bytes-4096):
            with self.assertRaises(budget.BudgetRefused):
                budget.verify_snapshot(replace(self.snapshot(), memory_max=value), self.limits)

    def test_peak_at_budget_or_below_current_refuses(self):
        for peak in (self.limits.strict_memory_bytes, self.limits.strict_memory_bytes+4096, 1):
            with self.assertRaises(budget.BudgetRefused):
                budget.verify_snapshot(replace(self.snapshot(), memory_peak=peak), self.limits)

    def test_swap_quota_burst_and_process_changes_refuse(self):
        for fields in ({'swap_max': 4096}, {'swap_current': 4096},
                       {'cpu_max': 'max 100000\n'}, {'cpu_max': '200000 100000\n'},
                       {'cpu_burst': 10000}, {'pids_max': 128}, {'pids_current': 0},
                       {'pids_current': 65}):
            with self.subTest(fields=fields), self.assertRaises(budget.BudgetRefused):
                budget.verify_snapshot(replace(self.snapshot(), **fields), self.limits)

    def test_each_pressure_and_OOM_event_refuses_then_restores(self):
        for key in self.snapshot().memory_events:
            changed = dict(self.snapshot().memory_events, **{key: 1})
            with self.subTest(key=key), self.assertRaises(budget.BudgetRefused):
                budget.verify_snapshot(replace(self.snapshot(), memory_events=changed), self.limits)
        budget.verify_snapshot(self.snapshot(), self.limits)

    def test_missing_duplicate_negative_and_malformed_events_refuse(self):
        for raw in ('max 0\n', self.values['memory.events']+'oom 0\n',
                    self.values['memory.events'].replace('oom 0', 'oom -1'),
                    self.values['memory.events'].replace('max 0', 'max  0')):
            with self.assertRaises(budget.BudgetRefused):
                budget.events(raw)

    def test_peak_reset_between_snapshots_refuses(self):
        before = replace(self.snapshot(), memory_peak=40*2**20)
        with self.assertRaisesRegex(budget.BudgetRefused, 'high-water'):
            budget.compare_snapshots(before, self.snapshot(), self.limits)

    def test_event_schema_change_between_snapshots_refuses(self):
        after = replace(self.snapshot(), memory_events=dict(self.snapshot().memory_events, new_counter=0))
        with self.assertRaisesRegex(budget.BudgetRefused, 'schema'):
            budget.compare_snapshots(self.snapshot(), after, self.limits)

    def test_physical_small_file_accepts_oversize_and_alias_refuse(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve()
            file = root/'control'
            file.write_bytes(b'123\n')
            self.assertEqual('123\n', budget.read_small(file))
            with self.assertRaises(budget.BudgetRefused):
                budget.read_small(file, 3)
            alias = root/'alias'
            alias.symlink_to(file.name)
            with self.assertRaises(budget.BudgetRefused):
                budget.read_small(alias)

    def test_missing_kernel_control_refuses(self):
        values = dict(self.values)
        del values['memory.peak']
        with self.assertRaises(KeyError):
            self.snapshot(values)


if __name__ == '__main__':
    unittest.main()
