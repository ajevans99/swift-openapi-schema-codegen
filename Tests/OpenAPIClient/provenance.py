"""Record or verify source bytes and remote dependency resolution for acceptance."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(path, *arguments):
    return subprocess.check_output(["git", "-C", str(path), *arguments], text=True).strip()


def snapshot(root, graphs, artifact):
    pins = {
        entry["identity"]: entry
        for entry in json.loads((root / "Package.resolved").read_text())["pins"]
    }
    packages = {"generator": root}
    dependencies = {}
    for graph in graphs:
        def visit(node):
            path = Path(node["path"]).resolve(strict=True)
            identity = node["identity"]
            if path != root and path != (root / ".build/responses-consumer"):
                pin = pins[identity]
                if (
                    pin["kind"] != "remoteSourceControl"
                    or node["version"] != pin["state"].get("version")
                    or node["url"] != pin["location"]
                    or git(path, "rev-parse", "HEAD") != pin["state"]["revision"]
                ):
                    raise ValueError(f"Dependency does not match released lockfile: {identity}")
                if git(path, "status", "--porcelain", "--untracked-files=all"):
                    raise ValueError(f"Dependency checkout is modified: {path}")
                key = str(path)
                dependencies[key] = {
                    "identity": identity, "version": node["version"],
                    "revision": pin["state"]["revision"], "url": node["url"],
                }
                if identity in {"swift-json-schema", "swift-json-schema-codegen", "swift-openapi-schema"}:
                    packages[key] = path
            for child in node["dependencies"]:
                visit(child)
        visit(json.loads(graph.read_text()))
    identities = {entry["identity"] for entry in dependencies.values()}
    if not {"swift-json-schema", "swift-json-schema-codegen", "swift-openapi-schema"} <= identities:
        raise ValueError("Missing required released dependencies in graph.")
    files = {}
    for label, package in packages.items():
        for path in [package / "Package.swift", *sorted((package / "Sources").rglob("*.swift"))]:
            files[label + "/" + str(path.relative_to(package))] = digest(path)
    for path in [
        root / "Package.resolved",
        root / ".build/openapi-corpus/openapi.json",
        root / ".build/openapi-corpus/LICENSE",
        *sorted((root / "Tests/OpenAPIClient/Consumer").glob("*.swift")),
        *sorted((root / "Tests/OpenAPIClient/Fixtures").glob("*.json")),
        *sorted((root / "Tests/OpenAPIClient").glob("*.py")),
        *sorted((root / "Tests/OpenAPIClient").glob("*.sh")),
    ]:
        files[str(path.relative_to(root))] = digest(path)
    return {
        "generator_revision": git(root, "rev-parse", "HEAD"),
        "files": files,
        "dependencies": dependencies,
        "artifact": None if artifact is None else {
            "path": str(artifact.resolve(strict=True)),
            "bytes": artifact.stat().st_size, "sha256": digest(artifact),
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--graph", type=Path, action="append", required=True)
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    result = snapshot(args.root.resolve(strict=True), args.graph, args.artifact)
    if args.verify:
        if result != json.loads(args.output.read_text()):
            raise SystemExit(f"Acceptance source/dependency/artifact drift: {args.output}")
        print(f"Unchanged acceptance provenance: {len(result['files'])} files")
    else:
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(f"Recorded acceptance provenance: {len(result['files'])} files")


if __name__ == "__main__":
    main()
