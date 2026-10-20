"""Exercise source, identity, time and aggregate-read fences with controlled files."""
from dataclasses import replace
from pathlib import Path
import copy
import datetime
import hashlib
import json
import tempfile
import unittest
from unittest.mock import patch
import native_image_protocol as protocol

NOW = datetime.datetime(2026, 10, 20, 1, 38, tzinfo=datetime.timezone.utc)


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(65536), b''):
            value.update(block)
    return value.hexdigest()


class NativeImageProtocol(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.ruby = self.root/'ruby'
        self.crypto = self.root/'crypto.so'
        self.ruby.write_bytes(b'pinned Ruby fixture')
        self.ruby.chmod(0o755)
        self.crypto.write_bytes(b'pinned crypto fixture')
        self.crypto.chmod(0o644)
        self.expected = protocol.ExpectedWorker(101, 'exact-fixture-birth', 99, 101, 501,
                                                str(self.ruby), 'original', 'a'*64)
        self.rows = {101: dict(birth=self.expected.birth, parent=99, group=101,
                              real_uid=501, effective_uid=501, uid_semantics='real-user-id')}
        self.ready = dict(format='atlas-native-image-boundary-ready-v1', scope=protocol.SCOPE,
                          pid=101, uid=501, selected_case='original', nonce='a'*64,
                          Ruby_path=str(self.ruby), observed_at=NOW.isoformat(), foreign_signals=0)
        self.images = {str(path): self.reference(path) for path in (self.ruby, self.crypto)}
        self.kernel = ('p101\nn'+str(self.ruby)+'\nn'+str(self.crypto)+
                       '\nn/usr/lib/libSystem.B.dylib\n').encode()

    def reference(self, path):
        return protocol.PhysicalImage(str(path), path.stat().st_size, sha(path),
                                      path.stat().st_mode & 0o7777)

    def qualify(self, ready=None, kernel=None, expected=None, before=None,
                after=None, images=None, aliases=(), clock=lambda: NOW):
        return protocol.qualify_frame(json.dumps(self.ready if ready is None else ready).encode(),
            self.kernel if kernel is None else kernel, self.expected if expected is None else expected,
            self.rows if before is None else before,
            (lambda: self.rows) if after is None else after,
            self.images if images is None else images, aliases, clock)

    def test_complete_physical_frame_binds_exact_acknowledgment(self):
        result = self.qualify()
        self.assertTrue(result['passed'])
        self.assertEqual(hashlib.sha256(self.kernel).hexdigest(), result['acknowledgment']['raw_frame_sha256'])
        self.assertEqual(101, result['acknowledgment']['pid'])
        self.assertEqual(2, len(result['physical_images']))

    def test_all_seven_original_signature_case_boundaries_are_distinct(self):
        for selected in protocol.CASES:
            expected = replace(self.expected, selected_case=selected)
            ready = dict(self.ready, selected_case=selected)
            self.assertEqual(selected, self.qualify(ready=ready, expected=expected)['acknowledgment']['selected_case'])

    def test_missing_and_extra_ready_schema_fields_refuse(self):
        for changed in (dict(self.ready, extra=True), {k: v for k, v in self.ready.items() if k != 'nonce'}):
            with self.assertRaisesRegex(RuntimeError, 'schema'):
                self.qualify(ready=changed)

    def test_wrong_format_scope_and_boolean_numeric_fields_refuse(self):
        for field, value in [('format', 'other'), ('scope', 'other'), ('pid', True),
                             ('uid', False), ('foreign_signals', False)]:
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                self.qualify(ready=dict(self.ready, **{field: value}))

    def test_wrong_nonce_actor_case_and_Ruby_path_refuse(self):
        for field, value in [('nonce', 'b'*64), ('pid', 102), ('uid', 503),
                             ('selected_case', 'key_damaged'), ('Ruby_path', '/other/ruby')]:
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                self.qualify(ready=dict(self.ready, **{field: value}))

    def test_future_stale_and_naive_ready_clocks_refuse(self):
        for value in (NOW+datetime.timedelta(seconds=1), NOW-datetime.timedelta(seconds=9),
                      NOW.replace(tzinfo=None)):
            with self.assertRaises(RuntimeError):
                self.qualify(ready=dict(self.ready, observed_at=value.isoformat()))

    def test_replaced_before_actor_birth_group_parent_and_UID_refuse(self):
        for field, value in [('birth', 'later-birth'), ('group', 102), ('parent', 98),
                             ('real_uid', 503), ('effective_uid', 503), ('uid_semantics', 'effective-only')]:
            rows = copy.deepcopy(self.rows)
            rows[101][field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                self.qualify(before=rows)

    def test_replaced_after_actor_refuses_then_restores(self):
        rows = copy.deepcopy(self.rows)
        rows[101]['birth'] = 'later-birth'
        with self.assertRaises(RuntimeError):
            self.qualify(after=lambda: rows)
        self.assertTrue(self.qualify()['passed'])

    def test_another_kernel_PID_refuses(self):
        with self.assertRaisesRegex(RuntimeError, 'one-PID'):
            self.qualify(kernel=self.kernel.replace(b'p101\n', b'p102\n'))

    def test_wrong_kernel_field_shape_refuses(self):
        for raw in (b'p101\nftxt\nn/one\n', b'p101\nnrelative\n', b'p101\np102\nn/one\n'):
            with self.assertRaises(RuntimeError):
                self.qualify(kernel=raw)

    def test_empty_and_oversized_kernel_output_refuse(self):
        for raw in (b'', b'x'*(256*2**10+1)):
            with self.assertRaises(RuntimeError):
                self.qualify(kernel=raw)

    def test_missing_actual_Ruby_image_refuses(self):
        with self.assertRaisesRegex(RuntimeError, 'Ruby executable'):
            self.qualify(kernel=('p101\nn'+str(self.crypto)+'\n').encode())

    def test_unadmitted_physical_image_refuses(self):
        extra = self.root/'unadmitted.so'
        extra.write_bytes(b'other input')
        with self.assertRaisesRegex(RuntimeError, 'admitted source reference'):
            self.qualify(kernel=self.kernel+('n'+str(extra)+'\n').encode())

    def test_changed_physical_bytes_and_mode_refuse_then_restore(self):
        original = self.crypto.read_bytes()
        self.crypto.write_bytes(b'changed crypto fixture')
        with self.assertRaises(RuntimeError):
            self.qualify()
        self.crypto.write_bytes(original)
        self.crypto.chmod(0o600)
        with self.assertRaises(RuntimeError):
            self.qualify()
        self.crypto.chmod(0o644)
        self.assertTrue(self.qualify()['passed'])

    def test_exact_alias_accepts_and_same_byte_alias_diversion_refuses(self):
        link = self.root/'selected.so'
        alternate = self.root/'same-bytes.so'
        alternate.write_bytes(self.crypto.read_bytes())
        link.symlink_to(self.crypto)
        admitted = protocol.SourceAlias(str(link), str(self.crypto), str(self.crypto))
        raw = self.kernel.replace(('n'+str(self.crypto)).encode(), ('n'+str(link)).encode())
        self.assertTrue(self.qualify(kernel=raw, aliases=(admitted,))['passed'])
        link.unlink()
        link.symlink_to(alternate)
        with self.assertRaisesRegex(RuntimeError, 'alias'):
            self.qualify(kernel=raw, aliases=(admitted,))
        link.unlink()
        link.symlink_to(self.crypto)
        self.assertTrue(self.qualify(kernel=raw, aliases=(admitted,))['passed'])

    def test_final_actor_and_time_checks_follow_real_physical_hashing(self):
        verified = []
        original = protocol.verify_physical_image
        def image(path, expected):
            value = original(path, expected)
            verified.append(str(path))
            return value
        def rows_after():
            self.assertEqual(2, len(verified))
            return self.rows
        with patch.object(protocol, 'verify_physical_image', image):
            self.assertTrue(self.qualify(after=rows_after)['passed'])
        clock = iter((NOW, NOW+datetime.timedelta(seconds=9)))
        with self.assertRaisesRegex(RuntimeError, 'Fresh'):
            self.qualify(clock=lambda: next(clock))

    def test_system_cache_boundary_retains_separate_qualification(self):
        result = self.qualify()
        self.assertFalse(result['system_images'][0]['physical_source_bytes_verified'])
        self.assertFalse(result['complete_provider_profile_accepted'])
        self.assertFalse(result['quantitative_acceptance'])
        self.assertEqual(0, result['foreign_signals'])

    def test_aggregate128MiB_fence_and_guard_removal_sensitivity(self):
        extra = [self.root/('extra'+str(index).zfill(2)+'.so') for index in range(16)]
        # Every file fits the existing16MiB per-file source-control fence.
        # The aggregate still exceeds the actual128MiB verification budget.
        for path in [self.crypto]+extra:
            with path.open('wb') as stream:
                stream.truncate(8*2**20)
            path.chmod(0o644)
        images = {str(path): self.reference(path) for path in [self.ruby, self.crypto]+extra}
        raw = self.kernel+''.join('n'+str(path)+'\n' for path in extra).encode()
        with self.assertRaisesRegex(RuntimeError, 'fits128MiB'):
            self.qualify(images=images, kernel=raw)
        original = protocol.require
        def removed_budget_guard(value, message):
            if message != 'Complete physical image verification fits128MiB':
                original(value, message)
        with patch.object(protocol, 'require', removed_budget_guard):
            self.assertTrue(self.qualify(images=images, kernel=raw)['passed'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
