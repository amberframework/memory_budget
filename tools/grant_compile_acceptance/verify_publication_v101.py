#!/usr/bin/env python3
"""Independently read, physically extract, and reproduce the publication packet."""
import argparse
import copy
import gzip
import hashlib
import json
import os
import platform
from pathlib import Path, PurePosixPath
import stat
import sys
import tarfile
import zlib

PREFIX = "grant-first-build-publication-v101"
INNER_PATH = "workspace/grant_linux_first_build_v100/prepared/grant-source-and-frozen-dependencies.tar.gz"
INNER_SHA = "d2c90cc3110109337c92f567fdf533dadf475b3f468602b8fcb5e2ed21426ff5"
ANCESTOR_SHA = "aebd690e5978aa6373e2177aa7ee2d5bcb8b7e064cc50aee18ae9c4d53fc5601"
SOURCE_PYTHON_PROFILES = {
    ("linux", "3.12.3"): "e50d468e8b0adfb05733f5b87b3cff34829c4a8c1aea50c865aa8bdfe4bb150f",
    ("darwin", "3.15.0"): "1955899cb535256cfa477d926d016819e52e747984722c44f76e39a4950fee0e",
    ("darwin", "3.9.6"): "271143990bc83af0fb2404a255038f5faafb96df1584ed7f085e5018c0f33ffb",
}


def need(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_provider_metadata():
    """Bind source execution to a reviewed interpreter and record zlib's layout."""
    executable = Path(sys.executable).resolve(strict=True)
    version = platform.python_version()
    expected = SOURCE_PYTHON_PROFILES.get((sys.platform, version))
    need(expected is not None and executable.is_file() and sha(executable) == expected,
         "Exact reviewed source Python version and executable digest required")
    spec = getattr(zlib, "__spec__", None)
    origin = getattr(spec, "origin", None)
    need(getattr(zlib, "__name__", None) == "zlib" and getattr(spec, "name", None) == "zlib",
         "Exact zlib module and import-spec names required")
    module_file = getattr(zlib, "__file__", None)
    if module_file is None:
        need(origin == "built-in" and "zlib" in sys.builtin_module_names,
             "An absent zlib module file requires an actual built-in origin and name")
        provider = {"zlib_module_kind": "built-in", "zlib_module_origin": "built-in",
            "zlib_module": None, "zlib_module_sha256": None,
            "zlib_module_hash_scope": "Built-in module code belongs to the exact interpreter digest; linked native library closure remains separate"}
    else:
        need(type(module_file) is str and type(origin) is str,
             "File-backed zlib needs explicit module-file and import-origin paths")
        path = Path(module_file).resolve(strict=True)
        need(path.is_file() and origin != "built-in" and Path(origin).resolve(strict=True) == path,
             "File-backed zlib import origin must match its regular module file")
        provider = {"zlib_module_kind": "file-backed", "zlib_module_origin": origin,
            "zlib_module": str(path), "zlib_module_bytes": path.stat().st_size,
            "zlib_module_sha256": sha(path),
            "zlib_module_hash_scope": "Observed file-backed source provider metadata; full native dependency closure remains separate"}
    compile_version = getattr(zlib, "ZLIB_VERSION", None)
    runtime_version = getattr(zlib, "ZLIB_RUNTIME_VERSION", None)
    need(type(compile_version) is str and bool(compile_version)
         and type(runtime_version) is str and bool(runtime_version),
         "Observed zlib compile and runtime versions required")
    provider.update({"python_version": sys.version, "python_profile_version": version,
        "python_executable": str(executable), "python_sha256": expected,
        "zlib_compile_version": compile_version, "zlib_runtime_version": runtime_version,
        "full_native_dependency_closure_accepted": False})
    return provider


def parse(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            need(key not in result, "Unique JSON fields required")
            result[key] = value
        return result
    def finite(value):
        raise ValueError("Finite JSON values required: " + value)
    return json.loads(raw, object_pairs_hook=unique, parse_constant=finite)


def canonical_sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def safe_path(value, root=False):
    path = PurePosixPath(value)
    need(type(value) is str and path.as_posix() == value and not path.is_absolute()
         and ".." not in path.parts and (value != "." or root), "Canonical contained member path required")
    return path


def verify_payload(root, expected_contents_sha, archive_prefix=PREFIX):
    root = Path(root).resolve()
    manifest = root / "PACKAGE_CONTENTS.json"
    need(sha(manifest) == expected_contents_sha, "The independently declared contents manifest must match")
    data = parse(manifest.read_bytes())
    need(data["format"] == "atlas-grant-first-build-publication-contents-v1" and data["archive_prefix"] == archive_prefix,
         "Exact publication format and prefix required")
    rows = data["files"]
    need(type(rows) is list and len(rows) <= 256 and len({row["path"] for row in rows}) == len(rows), "Unique bounded file roster required")
    expected_files = {"PACKAGE_CONTENTS.json"}
    for row in rows:
        relative = safe_path(row["path"])
        path = root / relative
        need(type(row["mode"]) is int and type(row["bytes"]) is int and 0 <= row["bytes"] <= 16 * 2**20,
             "Typed bounded file metadata required")
        need(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root)
             and path.stat().st_size == row["bytes"] and stat.S_IMODE(path.stat().st_mode) == row["mode"]
             and sha(path) == row["sha256"], "Physical payload bytes/mode differ: " + row["path"])
        expected_files.add(row["path"])
    actual_files = {path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file()}
    need(actual_files == expected_files and all(not path.is_symlink() for path in root.rglob("*")), "Complete ordinary outer file roster required")
    actual_directories = {"."} | {path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_dir()}
    need(actual_directories == {row["path"] for row in data["directories"]}, "Complete structural directory roster required")
    for row in data["directories"]:
        safe_path(row["path"], root=True)
        need(type(row["mode"]) is int and stat.S_IMODE((root / row["path"]).stat().st_mode) == row["mode"], "Exact outer directory mode required")
    need(stat.S_IMODE(manifest.stat().st_mode) == 0o644, "The contents manifest retains its declared mode")
    return data


def extract_outer(archive_path, target, expected_contents_sha, archive_prefix=PREFIX):
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        need(len(members) <= 512 and len({member.name for member in members}) == len(members), "Unique bounded outer archive roster required")
        need(sum(member.size for member in members) <= 64 * 2**20, "Finite expanded publication bytes required")
        for member in members:
            safe_path(member.name)
            need(member.name == archive_prefix or member.name.startswith(archive_prefix + "/"), "Exact outer archive namespace required")
            need(member.isfile() or member.isdir(), "Outer members are ordinary files and directories")
            need(member.uid == member.gid == member.mtime == 0 and member.uname == member.gname == "",
                 "Canonical deterministic outer ownership and clock metadata required")
            need(member.size <= 16 * 2**20, "Finite outer member size required")
            path = target / member.name
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("xb") as stream:
                    stream.write(archive.extractfile(member).read())
            path.chmod(member.mode)
    payload = target / archive_prefix
    data = verify_payload(payload, expected_contents_sha, archive_prefix)
    expected = {archive_prefix} | {archive_prefix + "/" + row["path"] for row in data["directories"] if row["path"] != "."}
    expected |= {archive_prefix + "/" + row["path"] for row in data["files"]} | {archive_prefix + "/PACKAGE_CONTENTS.json"}
    need(expected == {member.name for member in members}, "Every outer archive member is covered by the manifest")
    return payload, data


def extract_inner(inner, destination, ledger, origins):
    need(sha(inner) == INNER_SHA and inner.stat().st_size == 1626007, "Exact accepted inner archive required")
    by_path = {row["archive_path"]: row for row in origins}
    need(len(by_path) == len(origins) == 1549, "Complete unique source-origin roster required")
    aliases = []
    with tarfile.open(inner, "r:gz") as archive:
        members = archive.getmembers()
        need(len(members) == len(ledger) == 1749 and sum(member.size for member in members) <= 64 * 2**20,
             "Exact finite inner archive/header roster required")
        for ordinal, (member, row) in enumerate(zip(members, ledger), 1):
            safe_path(member.name)
            need(member.name.startswith("grant/") and row["ordinal"] == ordinal and row["path"] == member.name
                 and row["mode"] == member.mode and row["bytes"] == member.size, "Exact inner header identity/order/mode required")
            kind = "file" if member.isfile() else "directory" if member.isdir() else "symlink" if member.issym() else "unsupported"
            need(kind == row["kind"] and kind != "unsupported", "Exact reviewed inner member kind required")
            path = destination / member.name
            need(all(not parent.is_symlink() for parent in path.parents if parent.is_relative_to(destination)), "Ordinary extraction parents required")
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
                path.chmod(member.mode)
                need(row["descendant_payload_members"] == sum(name.startswith(member.name + "/") for name in by_path), "Derived directory origin count differs")
            else:
                original = by_path[member.name]
                need(original["origin_verified"] is True and canonical_sha(original) == row["origin_row_sha256"], "Complete member-origin row differs")
                path.parent.mkdir(parents=True, exist_ok=True)
                if member.isfile():
                    raw = archive.extractfile(member).read()
                    need(hashlib.sha256(raw).hexdigest() == row["sha256"] == original["sha256"], "Exact inner member bytes required")
                    with path.open("xb") as stream:
                        stream.write(raw)
                    path.chmod(member.mode)
                    need(sha(path) == row["sha256"] and stat.S_IMODE(path.stat().st_mode) == member.mode, "Physical inner file replay differs")
                else:
                    need(member.linkname == row["target"] == original["target"] and not Path(member.linkname).is_absolute(), "Exact relative alias target required")
                    need((path.parent / member.linkname).resolve().is_relative_to(destination / "grant/lib"), "Alias remains in the common pinned dependency closure")
                    path.symlink_to(member.linkname)
                    if hasattr(os, "lchmod"):
                        os.lchmod(path, member.mode)
                    aliases.append({"path": member.name, "target": os.readlink(path), "archive_mode": member.mode,
                                    "physical_mode": stat.S_IMODE(path.lstat().st_mode)})
                    need(os.readlink(path) == member.linkname, "Physical alias replay differs")
    return members, aliases


def rebuild_from_members(destination, members, output):
    with output.open("xb") as target:
        with gzip.GzipFile(filename="", mode="wb", fileobj=target, mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for original in members:
                    member = copy.copy(original)
                    if member.isfile():
                        with (destination / member.name).open("rb") as stream:
                            archive.addfile(member, stream)
                    else:
                        archive.addfile(member)


def rebuild_outer(payload, contents, output):
    names = ["."] + sorted([row["path"] for row in contents["directories"] if row["path"] != "."]
                          + [row["path"] for row in contents["files"]] + ["PACKAGE_CONTENTS.json"])
    with output.open("xb") as target:
        with gzip.GzipFile(filename="", mode="wb", fileobj=target, mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for name in names:
                    path = payload / name
                    member = tarfile.TarInfo(PREFIX if name == "." else PREFIX + "/" + name)
                    member.mode = stat.S_IMODE(path.stat().st_mode)
                    if path.is_dir():
                        member.type = tarfile.DIRTYPE
                        archive.addfile(member)
                    else:
                        member.size = path.stat().st_size
                        with path.open("rb") as stream:
                            archive.addfile(member, stream)


def verify(archive_path, expected_archive_sha, expected_contents_sha, output):
    need(archive_path.stat().st_size <= 20 * 2**20 and sha(archive_path) == expected_archive_sha, "Independently declared bounded outer archive digest required")
    provider = source_provider_metadata()
    output.mkdir(parents=True, exist_ok=False)
    payload, contents = extract_outer(archive_path, output, expected_contents_sha)
    need(sha(payload / "ancestry/grant-linux-first-build-publication-v100.tar.gz") == ANCESTOR_SHA, "Exact frozen v100 publication packet required")
    inner = payload / INNER_PATH
    members, aliases = extract_inner(inner, output / "inner-readback", parse((payload / "origin/INNER_TAR_MEMBER_LEDGER.json").read_bytes()),
                                     parse((payload / "origin/ARCHIVE_MEMBER_ORIGINS_COMPLETE.json").read_bytes()))
    inner_repeat, outer_repeat = output / "inner-reproduced.tar.gz", output / "outer-reproduced.tar.gz"
    rebuild_from_members(output / "inner-readback", members, inner_repeat)
    need(sha(inner_repeat) == INNER_SHA, "All physically extracted inner bytes and archived modes reproduce the exact inner digest")
    rebuild_outer(payload, contents, outer_repeat)
    need(sha(outer_repeat) == expected_archive_sha, "All physically extracted outer bytes/modes reproduce the exact outer digest")
    return {"mission": "memory-budget-experiment", "package_verification_passed": True,
        "outer_archive_sha256": sha(archive_path), "outer_archive_bytes": archive_path.stat().st_size,
        "contents_sha256": expected_contents_sha, "inner_sha256": INNER_SHA,
        "inner_reproduced_sha256": sha(inner_repeat), "outer_reproduced_sha256": sha(outer_repeat),
        "outer_files": len(contents["files"]) + 1, "outer_directories": len(contents["directories"]),
        "inner_header_rows": len(members), "inner_physical_payload_rows": 1549, "aliases": aliases,
        "physical_symlink_modes_match_archive_on_this_platform": all(row["archive_mode"] == row["physical_mode"] for row in aliases),
        "provider": provider, "ancestor_outer_sha256": ANCESTOR_SHA,
        "public_commit_upload": "pending-parent", "ordinary_installation_native_projection_actual_build": "pending",
        "active_workflow_dependency_admission": "separate future boundary", "actual_compiler_container_native_ssh_jobs": 0,
        "accepted_target_cells": 0, "required_target_cells": 144}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--archive-sha256", required=True)
    parser.add_argument("--contents-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.archive.resolve(), args.archive_sha256, args.contents_sha256, args.output.resolve())
    with (args.output / "VERIFICATION_RECEIPT.json").open("x") as stream:
        stream.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
