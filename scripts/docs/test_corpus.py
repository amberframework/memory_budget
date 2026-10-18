#!/usr/bin/env python3
"""Run actual documentation verifier processes against valid and mutated packets."""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import re

sys.dont_write_bytecode = True
MODULE = Path(__file__).with_name("manage_corpus.py")
definition = importlib.util.spec_from_file_location("memory_docs", MODULE)
corpus = importlib.util.module_from_spec(definition)
definition.loader.exec_module(corpus)
ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--report", type=Path)
parser.add_argument("--source-commit", help="The Actions checkout context for an immutable test image without Git.")
parser.add_argument("--root", type=Path, default=ROOT)
arguments = parser.parse_args()
ROOT = arguments.root.resolve()
manifest = corpus.verify_manifest(ROOT)
if arguments.source_commit:
    assert re.fullmatch(r"[a-f0-9]{40}", arguments.source_commit)
    identity = {"source_commit": arguments.source_commit, "source_tree_state": "provided_ci_checkout_context"}
else:
    identity = corpus.checkout_identity(ROOT)
expected = corpus.projected_files(ROOT, manifest, identity)
rows = []

with tempfile.TemporaryDirectory(prefix="memory-docs-controls-") as temporary:
    website = (Path(temporary) / "website with spaces").resolve()
    for relative, content in expected.items():
        path = corpus.safe(website, relative)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    command = [str(website / "scripts/memory_budget_docs.py"), "verify-website", "--website", str(website)]

    def invoke(label, expected_exit):
        for optimized in [False, True]:
            actual_command = [sys.executable] + (["-O"] if optimized else []) + command
            completed = subprocess.run(actual_command, capture_output=True, text=True)
            row = {"control": label, "optimized": optimized, "expected_exit": expected_exit, "actual_exit": completed.returncode,
                   "command": actual_command, "stdout": completed.stdout, "stderr": completed.stderr, "passed": completed.returncode == expected_exit}
            rows.append(row)
            if not row["passed"]:
                raise RuntimeError(json.dumps(row))

    invoke("normal_projection", 0)
    config = corpus.read_config(ROOT)
    page = website / config["website_prefix"] / "fiber-budget.md"
    page_bytes = page.read_bytes()
    page.unlink()
    invoke("missing_page", 2)
    page.write_bytes(page_bytes + b"\nChanged example allowance.\n")
    invoke("modified_page", 2)
    page.write_bytes(page_bytes)

    source_pin = website / "config/memory_budget_docs_source.json"
    original_pin = source_pin.read_bytes()
    stale_pin = json.loads(original_pin)
    stale_pin["package_version"] = "0.0.0"
    source_pin.write_bytes(corpus.encode(stale_pin))
    invoke("stale_version", 2)
    source_pin.write_bytes(original_pin)

    unexpected = page.with_name("unreviewed.md")
    unexpected.write_text("# Unexpected projected page\n")
    invoke("unexpected_page", 2)
    unexpected.unlink()

    skill = website / "public/agent-skills/crystal-memory-budgets/SKILL.md"
    skill_bytes = skill.read_bytes()
    skill.write_bytes(skill_bytes + b"\nChanged guidance.\n")
    invoke("modified_skill", 2)
    skill.write_bytes(skill_bytes)

    canonical = website / config["public_prefix"] / "source" / config["list_of_pages"][0]["file"]
    canonical_bytes = canonical.read_bytes()
    canonical.write_bytes(canonical_bytes + b"\nChanged canonical source.\n")
    invoke("modified_public_canonical_source", 2)
    canonical.write_bytes(canonical_bytes)

    example = website / config["public_prefix"] / "source" / config["list_of_examples"][0]
    example_bytes = example.read_bytes()
    example.unlink()
    invoke("missing_public_executable_example", 2)
    example.write_bytes(example_bytes)

    verifier = website / "scripts/memory_budget_docs.py"
    verifier_bytes = verifier.read_bytes()
    verifier.write_bytes(verifier_bytes + b"\n# Modified projected verifier control.\n")
    invoke("modified_projected_verifier", 2)
    verifier.write_bytes(verifier_bytes)
    invoke("restored_projection", 0)

    empty_config = json.loads((ROOT / "docs/corpus.json").read_text())
    empty_config["list_of_pages"] = []
    empty_root = Path(temporary) / "empty-roster"
    (empty_root / "docs").mkdir(parents=True)
    (empty_root / "docs/corpus.json").write_bytes(corpus.encode(empty_config))
    for optimized in [False, True]:
        completed = subprocess.run([sys.executable] + (["-O"] if optimized else []) + [str(MODULE), "build-manifest", "--root", str(empty_root)], capture_output=True, text=True)
        rows.append({"control": "empty_canonical_roster", "optimized": optimized, "expected_exit": 2, "actual_exit": completed.returncode,
                     "stdout": completed.stdout, "stderr": completed.stderr, "passed": completed.returncode == 2})
        if not rows[-1]["passed"]:
            raise RuntimeError(json.dumps(rows[-1]))

report = {"schema_version": 1, "observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), **identity,
          "scope": "Actual verifier processes; canonical corpus and public website/skill projections; executable tutorial behavior is a separate admitted run.",
          "manifest_sha256": hashlib.sha256(corpus.encode(manifest)).hexdigest(), "projected_files": len(expected),
          "verifier_sha256": hashlib.sha256(MODULE.read_bytes()).hexdigest(),
          "list_of_results": rows, "passed": all(row["passed"] for row in rows)}
if arguments.report:
    arguments.report.parent.mkdir(parents=True, exist_ok=True)
    arguments.report.write_bytes(corpus.encode(report))
print(json.dumps({"passed": report["passed"], "controls": len(rows), "projected_files": len(expected), "report": str(arguments.report) if arguments.report else None}))
raise SystemExit(0 if report["passed"] else 2)
