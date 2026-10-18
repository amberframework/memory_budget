#!/usr/bin/env python3
"""Build, project, and verify the SDK-owned versioned documentation corpus."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

class CorpusValidationError(ValueError):
    """A failed canonical source or projected-evidence requirement."""

def require(condition, message):
    if not condition:
        raise CorpusValidationError(message)

def encode(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()

def sha(content):
    return hashlib.sha256(content).hexdigest()

def read_config(root):
    config = json.loads((root / "docs/corpus.json").read_text())
    require(config['schema_version'] == 1, 'Unsupported corpus schema version')
    require(re.fullmatch('\\d+\\.\\d+\\.\\d+', config['package_version']), 'The corpus requires an exact semantic package version')
    pages = config["list_of_pages"]
    require(pages, 'At least one canonical page is required')
    require(len({row['file'] for row in pages}) == len(pages), 'Canonical page paths must be unique')
    require(len({row['slug'] for row in pages}) == len(pages), 'Canonical page slugs must be unique')
    require(config['list_of_examples'], 'An executable example is required')
    require(config['list_of_api_sources'], 'Source-verified API paths are required')
    require(len(config['list_of_api_sources']) == len(set(config['list_of_api_sources'])), 'API source paths must be unique')
    for row in pages:
        require(re.fullmatch('[a-z0-9-]+', row['slug']), 'Page slugs use lowercase letters, numbers and hyphens')
    return config

def safe(root, relative):
    path = Path(relative)
    require(not path.is_absolute() and '..' not in path.parts, 'Corpus paths stay relative')
    resolved = (root / path).resolve()
    require(root.resolve() in resolved.parents, 'The resolved corpus path must stay inside its root')
    return resolved

def payload_paths(root, config):
    paths = ["docs/corpus.json"] + [row["file"] for row in config["list_of_pages"]] + config["list_of_examples"]
    skill = safe(root, config["skill_directory"])
    require((skill / 'SKILL.md').is_file(), 'The repository skill entrypoint is required')
    paths += [str(path.relative_to(root)) for path in sorted(skill.rglob("*")) if path.is_file()]
    require(len(paths) == len(set(paths)), 'Canonical payload paths must be unique')
    require(sorted((str(path.relative_to(root)) for path in safe(root, 'docs/' + config['package_version']).rglob('*.md'))) == sorted((row['file'] for row in config['list_of_pages'])), 'Every versioned page belongs to the canonical roster')
    return sorted(paths)

def build_manifest(root):
    config = read_config(root)
    return {"schema_version": 1, "package_name": config["package_name"], "package_version": config["package_version"],
            "distribution_state": config["distribution_state"], "counter_protocol": config["counter_protocol"],
            "source_binding": "Resolve the actual checkout commit/clean state when building a release or projection; this tracked manifest hashes canonical source bytes.",
            "source_repository": config["source_repository"], "proposed_repository": config["proposed_repository"], "repository_state": config["repository_state"],
            "api_basis": config["api_basis"],
            "list_of_files": [{"file": path, "sha256": sha(safe(root, path).read_bytes())} for path in payload_paths(root, config)],
            "list_of_api_sources": [{"file": path, "sha256": sha(safe(root, path).read_bytes())} for path in config["list_of_api_sources"]]}

def verify_manifest(root):
    manifest = build_manifest(root)
    require((root / 'docs/corpus-manifest.json').read_bytes() == encode(manifest), 'Canonical manifest is missing or stale')
    return manifest

def checkout_identity(root):
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip()
    return {"source_commit": commit, "source_tree_state": "dirty_candidate" if dirty else "clean"}

def page_projection(content, page, config, manifest_hash, identity):
    original_sha256 = sha(content)
    content = content.decode()
    for target in config["list_of_pages"]:
        slug = "" if target["slug"] == "index" else "/" + target["slug"]
        content = content.replace("(" + target["slug"] + ".md)", "(/" + config["website_prefix"] + slug + ")")
    fields = {"title": page["title"], "section": "guides/memory-budgets" if page["slug"] != "index" else "guides",
              "description": page["description"], "order": page["order"], "is_section": page["slug"] == "index",
              "source_package": config["package_name"], "source_package_version": config["package_version"],
              "source_path": page["file"], "source_sha256": original_sha256,
              "source_manifest_sha256": manifest_hash, "source_commit": identity["source_commit"], "source_tree_state": identity["source_tree_state"]}
    fields.update({key: config[key] for key in ["source_repository", "proposed_repository", "repository_state"]})
    frontmatter = "---\n" + "\n".join(key + ": " + json.dumps(value, ensure_ascii=False) for key, value in fields.items()) + "\n---\n\n"
    provenance = "> MemoryBudget " + config["package_version"] + " · " + config["distribution_state"] + ". Source `" + identity["source_commit"] + "` (" + identity["source_tree_state"] + "), canonical page SHA-256 `" + fields["source_sha256"] + "`.\n\n"
    return (frontmatter + provenance + content).encode()

def projected_files(root, manifest, identity):
    config = read_config(root)
    manifest_bytes = encode(manifest)
    manifest_hash = sha(manifest_bytes)
    result = {}
    for row in manifest["list_of_files"]:
        content = safe(root, row["file"]).read_bytes()
        require(sha(content) == row['sha256'], 'Canonical payload hash mismatch: ' + row['file'])
        result[config["public_prefix"] + "/source/" + row["file"]] = content
    for page in config["list_of_pages"]:
        content = safe(root, page["file"]).read_bytes()
        result[config["website_prefix"] + "/" + page["slug"] + ".md"] = page_projection(content, page, config, manifest_hash, identity)
    for path in sorted(safe(root, config["skill_directory"]).rglob("*")):
        if path.is_file():
            result["public/agent-skills/crystal-memory-budgets/" + str(path.relative_to(safe(root, config["skill_directory"])))] = path.read_bytes()
    result[config["public_prefix"] + "/corpus-manifest.json"] = manifest_bytes
    # The same verifier is projected as source; its hash is an independently reviewed pin.
    verifier = Path(__file__).read_bytes()
    result["scripts/memory_budget_docs.py"] = verifier
    pin = {"schema_version": 1, "package_version": config["package_version"], "distribution_state": config["distribution_state"], **identity,
           "source_repository": config["source_repository"], "proposed_repository": config["proposed_repository"], "repository_state": config["repository_state"], "public_prefix": config["public_prefix"], "website_prefix": config["website_prefix"],
           "canonical_manifest_sha256": manifest_hash, "verifier_sha256": sha(verifier),
           "list_of_projected_files": [{"file": path, "sha256": sha(content)} for path, content in sorted(result.items())]}
    result["config/memory_budget_docs_source.json"] = encode(pin)
    return result

def assert_exact_projection(website, expected):
    for relative, content in expected.items():
        require(safe(website, relative).read_bytes() == content, 'Modified or stale projection: ' + relative)
    pin = json.loads(expected["config/memory_budget_docs_source.json"])
    for prefix in [pin["website_prefix"], pin["public_prefix"], "public/agent-skills/crystal-memory-budgets"]:
        actual = {str(path.relative_to(website)) for path in safe(website, prefix).rglob("*") if path.is_file()}
        wanted = {path for path in expected if path.startswith(prefix + "/")}
        require(actual == wanted, 'Missing or unexpected projection file under ' + prefix)
    return {"package_version": pin["package_version"], "source_commit": pin["source_commit"], "source_tree_state": pin["source_tree_state"], "projected_files": len(expected)}

def verify_website(website):
    pin = json.loads((website / "config/memory_budget_docs_source.json").read_text())
    require(pin['schema_version'] == 1, 'Unsupported website source-pin schema')
    require(sha(Path(__file__).read_bytes()) == pin['verifier_sha256'], 'Projected verifier does not match its reviewed source pin')
    public = safe(website, pin["public_prefix"])
    manifest_bytes = (public / "corpus-manifest.json").read_bytes()
    require(sha(manifest_bytes) == pin['canonical_manifest_sha256'], 'Canonical manifest hash differs from the reviewed website pin')
    manifest = json.loads(manifest_bytes)
    require(manifest['package_version'] == pin['package_version'], 'Stale projected version')
    root = public / "source"
    config = read_config(root)
    require(config['package_version'] == pin['package_version'], 'Canonical configuration version differs from the website pin')
    require(sorted(row['file'] for row in manifest['list_of_files']) == payload_paths(root, config), 'The canonical manifest must cover the complete declared source roster')
    for row in manifest["list_of_files"]:
        require(sha(safe(root, row['file']).read_bytes()) == row['sha256'], 'Canonical public source projection changed')
    expected = projected_files(root, manifest, {key: pin[key] for key in ["source_commit", "source_tree_state"]})
    return assert_exact_projection(website, expected)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["build-manifest", "verify", "project", "verify-website"])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--website", type=Path)
    parser.add_argument("--require-clean", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.operation == "verify-website":
        result = verify_website((args.website or Path.cwd()).resolve())
    elif args.operation == "build-manifest":
        manifest = build_manifest(root)
        (root / "docs/corpus-manifest.json").write_bytes(encode(manifest))
        result = {"canonical_files": len(manifest["list_of_files"]), "manifest_sha256": sha(encode(manifest))}
    else:
        manifest = verify_manifest(root)
        result = {"canonical_files": len(manifest["list_of_files"]), "manifest_sha256": sha(encode(manifest))}
        if args.website:
            identity = checkout_identity(root)
            require(not args.require_clean or identity['source_tree_state'] == 'clean', 'Projection requires a clean identified source checkout')
            expected = projected_files(root, manifest, identity)
            if args.operation == "project":
                for relative, content in expected.items():
                    destination = safe(args.website.resolve(), relative)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(content)
            result.update(assert_exact_projection(args.website.resolve(), expected))
    print(json.dumps({"passed": True, **result}))

if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, KeyError, ValueError) as error:
        print("Memory docs failed: " + str(error), file=sys.stderr)
        raise SystemExit(2)
