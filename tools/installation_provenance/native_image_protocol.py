"""Validate a source-bound worker boundary before publishing its acknowledgment."""
from dataclasses import dataclass
from pathlib import Path
import datetime
import hashlib
import json
import os
import re
import stat

SCOPE = 'kernel-file-mappings-at-stable-worker-boundary-v1'
CASES = ('original', 'payload_damaged', 'payload_restored', 'signature_damaged',
         'signature_restored', 'key_damaged', 'key_restored')


def require(value, message):
    if not value:
        raise RuntimeError(message)


def signature(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns)


@dataclass(frozen=True)
class ExpectedWorker:
    pid: int
    birth: str
    parent: int
    group: int
    uid: int
    ruby_path: str
    selected_case: str
    nonce: str

    def __post_init__(self):
        require(type(self.pid) is int and self.pid > 1
                and type(self.parent) is int and self.parent > 1
                and self.group == self.pid and type(self.group) is int
                and type(self.uid) is int and self.uid == 501,
                'Exact ordinary-owner worker PID, parent and created group required')
        require(type(self.birth) is str and 0 < len(self.birth) <= 128
                and type(self.ruby_path) is str and Path(self.ruby_path).is_absolute()
                and self.selected_case in CASES and type(self.nonce) is str
                and re.fullmatch('[0-9a-f]{64}', self.nonce) is not None,
                'Exact worker birth, Ruby path, original case and nonce required')


@dataclass(frozen=True)
class SourceAlias:
    path: str
    link_text: str
    resolved_path: str


@dataclass(frozen=True)
class PhysicalImage:
    path: str
    bytes: int
    sha256: str
    mode: int

    def __post_init__(self):
        require(type(self.path) is str and Path(self.path).is_absolute()
                and type(self.bytes) is int and 0 < self.bytes <= 128*2**20
                and type(self.mode) is int and 0 <= self.mode <= 0o7777
                and type(self.sha256) is str
                and re.fullmatch('[0-9a-f]{64}', self.sha256) is not None,
                'Bounded exact physical image source reference required')


def parse_ready(raw, expected, now):
    require(type(raw) is bytes and 0 < len(raw) <= 16_384,
            'Complete bounded ready record required')
    value = json.loads(raw.decode('utf-8', 'strict'))
    require(type(value) is dict and set(value) == {
        'format', 'scope', 'pid', 'uid', 'selected_case', 'nonce', 'Ruby_path',
        'observed_at', 'foreign_signals'}, 'Exact ready record schema required')
    require(value['format'] == 'atlas-native-image-boundary-ready-v1'
            and value['scope'] == SCOPE and type(value['pid']) is int
            and value['pid'] == expected.pid and type(value['uid']) is int
            and value['uid'] == expected.uid and value['nonce'] == expected.nonce
            and value['selected_case'] == expected.selected_case
            and value['Ruby_path'] == expected.ruby_path
            and type(value['foreign_signals']) is int and value['foreign_signals'] == 0,
            'Exact owned ready identity, case, source and signal boundary required')
    observed = datetime.datetime.fromisoformat(value['observed_at'].replace('Z', '+00:00'))
    require(observed.tzinfo is not None and now.tzinfo is not None
            and observed.utcoffset() == now.utcoffset() == datetime.timedelta(0)
            and 0 <= (now-observed).total_seconds() <= 8,
            'Fresh aware UTC worker boundary required')
    return value


def verify_actor(rows, expected):
    value = rows.get(expected.pid)
    require(type(value) is dict and value.get('birth') == expected.birth
            and value.get('parent') == expected.parent and value.get('group') == expected.group
            and value.get('real_uid') == value.get('effective_uid') == expected.uid
            and value.get('uid_semantics') == 'real-user-id',
            'Current exact worker birth, ancestry, group and qualified real/effective UID required')


def parse_kernel_mappings(raw, expected_pid):
    require(type(raw) is bytes and 0 < len(raw) <= 256*2**10,
            'Complete bounded raw kernel mapping output required')
    lines = raw.decode('utf-8', 'strict').splitlines()
    require(lines and lines[0] == 'p'+str(expected_pid)
            and all(line.startswith('n/') and 1 < len(line) <= 4097 for line in lines[1:])
            and 0 < len(lines)-1 <= 1024, 'Exact one-PID lsof-Fpn kernel file roster required')
    return sorted({line[1:] for line in lines[1:]})


def resolve_admitted_path(path, list_of_aliases):
    path = Path(path)
    require(path.is_absolute(), 'Absolute observed image path required')
    aliases = {item.path: item for item in list_of_aliases}
    require(len(aliases) == len(list_of_aliases), 'Unique admitted alias roster required')
    for component in list(reversed(path.parents)) + [path]:
        if component.is_symlink():
            expected = aliases.get(str(component))
            require(expected is not None and os.readlink(component) == expected.link_text
                    and str(component.resolve(strict=True)) == expected.resolved_path,
                    'Every observed image alias needs its exact literal and physical authority')
    return path.resolve(strict=True)


def verify_physical_image(path, expected):
    path = Path(path)
    before = path.lstat()
    require(str(path) == expected.path and path.resolve(strict=True) == path
            and stat.S_ISREG(before.st_mode) and before.st_size == expected.bytes
            and stat.S_IMODE(before.st_mode) == expected.mode,
            'Exact declared physical image kind, size and mode required')
    digest = hashlib.sha256()
    descriptor = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        opened = os.fstat(stream.fileno())
        require(signature(before) == signature(opened), 'Stable opened image descriptor required')
        for block in iter(lambda: stream.read(65536), b''):
            digest.update(block)
        require(signature(opened) == signature(os.fstat(stream.fileno())),
                'Physical image descriptor changed during streaming verification')
    require(signature(before) == signature(path.lstat()) and path.resolve(strict=True) == path
            and digest.hexdigest() == expected.sha256, 'Exact stable physical image bytes required')
    return dict(path=str(path), bytes=before.st_size, mode=expected.mode,
                sha256=expected.sha256, physical_source_bytes_verified=True)


def qualify_frame(ready_raw, kernel_raw, expected, rows_before, read_rows_after,
                  physical_images, list_of_aliases, utc_now):
    ready = parse_ready(ready_raw, expected, utc_now())
    verify_actor(rows_before, expected)
    names = parse_kernel_mappings(kernel_raw, expected.pid)
    physical, system = [], []
    physical_bytes = 0
    for name in names:
        if name.startswith(('/System/', '/usr/lib/')):
            system.append(dict(path=name, physical_source_bytes_verified=False,
                               scope='Operating-system image/shared-cache boundary; separate platform qualification required'))
            continue
        path = resolve_admitted_path(name, list_of_aliases)
        reference = physical_images.get(str(path))
        require(isinstance(reference, PhysicalImage), 'Each observed physical image needs its admitted source reference')
        physical_bytes += reference.bytes
        require(physical_bytes <= 128*2**20, 'Complete physical image verification fits128MiB')
        physical.append(dict(verify_physical_image(path, reference), observed_path=name))
    require(expected.ruby_path in {item['path'] for item in physical},
            'The observed worker must map the exact admitted Ruby executable')
    verify_actor(read_rows_after(), expected)
    parse_ready(ready_raw, expected, utc_now())
    raw_hash = hashlib.sha256(kernel_raw).hexdigest()
    return dict(passed=True, scope=SCOPE, ready=ready, raw_frame_sha256=raw_hash,
                physical_images=physical, system_images=system,
                sampled_kernel_mapping_only=True, complete_provider_profile_accepted=False,
                quantitative_acceptance=False, foreign_signals=0,
                acknowledgment=dict(format='atlas-native-image-boundary-ack-v1', scope=SCOPE,
                    passed=True, nonce=expected.nonce, pid=expected.pid,
                    selected_case=expected.selected_case, raw_frame_sha256=raw_hash))
