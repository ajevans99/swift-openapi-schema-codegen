import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import bounded
import provenance


class BoundedRunTests(unittest.TestCase):
    def run_command(self, command, seconds=10, rss_kib=524288):
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory) / "run"
            with contextlib.redirect_stdout(io.StringIO()):
                result = bounded.run(command, seconds, rss_kib, prefix)
            return result, json.loads(prefix.with_suffix(".metrics.json").read_text())

    def test_success(self):
        result, metrics = self.run_command([sys.executable, "-c", "print('ok')"])
        self.assertEqual(result, 0)
        self.assertIsNone(metrics["stopped"])

    def test_failure_is_not_success(self):
        result, metrics = self.run_command([sys.executable, "-c", "raise SystemExit(7)"])
        self.assertEqual(result, 7)
        self.assertEqual(metrics["exit"], 7)

    def test_elapsed_limit(self):
        result, metrics = self.run_command(
            [sys.executable, "-c", "import time; time.sleep(10)"], seconds=0.1
        )
        self.assertEqual(result, 124)
        self.assertEqual(metrics["stopped"], "0.1 second limit")

    def test_rss_limit(self):
        result, metrics = self.run_command(
            [sys.executable, "-c", "import time; time.sleep(10)"], rss_kib=1
        )
        self.assertEqual(result, 124)
        self.assertEqual(metrics["stopped"], "1 KiB aggregate RSS limit")


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        for relative in [
            "Package.swift", "Sources/Client.swift", ".build/openapi-corpus/openapi.json",
            ".build/openapi-corpus/LICENSE",
        ]:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        self.nodes = []
        pins = []
        for identity in ["swift-json-schema", "swift-json-schema-codegen", "swift-openapi-schema"]:
            path = self.root / ".build/checkouts" / identity
            path.mkdir(parents=True)
            (path / "Package.swift").write_text("manifest")
            url = f"https://example.test/{identity}.git"
            self.nodes.append({
                "identity": identity, "path": str(path), "version": "1.0.0",
                "url": url, "dependencies": [],
            })
            pins.append({
                "identity": identity, "kind": "remoteSourceControl", "location": url,
                "state": {"version": "1.0.0", "revision": "release"},
            })
        (self.root / "Package.resolved").write_text(json.dumps({"pins": pins}))
        self.graph = self.root / "graph.json"
        self.save_graph()
        self.git = patch.object(
            provenance, "git",
            side_effect=lambda path, *args: "" if args[0] == "status" else "release",
        )
        self.git.start()
        self.addCleanup(self.git.stop)

    def save_graph(self):
        self.graph.write_text(json.dumps({
            "identity": "generator", "path": str(self.root), "dependencies": self.nodes,
        }))

    def snapshot(self, artifact=None):
        return provenance.snapshot(self.root, [self.graph], artifact)

    def test_source_and_artifact_drift(self):
        artifact = self.root / "Generated.swift"
        artifact.write_text("generated")
        before = self.snapshot(artifact)
        self.assertEqual(before, self.snapshot(artifact))
        artifact.write_text("edited")
        self.assertNotEqual(before["artifact"], self.snapshot(artifact)["artifact"])
        (self.root / "Sources/Client.swift").write_text("edited")
        self.assertNotEqual(before["files"], self.snapshot(artifact)["files"])

    def test_missing_dependency_fails(self):
        self.nodes.pop()
        self.save_graph()
        with self.assertRaisesRegex(ValueError, "Missing required"):
            self.snapshot()

    def test_override_fails(self):
        self.nodes[0]["version"] = "unspecified"
        self.nodes[0]["url"] = "/local/override"
        self.save_graph()
        with self.assertRaisesRegex(ValueError, "does not match released"):
            self.snapshot()

    def test_wrong_revision_fails(self):
        with patch.object(provenance, "git", return_value="different-revision"):
            with self.assertRaisesRegex(ValueError, "does not match released"):
                self.snapshot()

    def test_modified_checkout_fails(self):
        with patch.object(
            provenance, "git",
            side_effect=lambda path, *args: " M Sources/File.swift" if args[0] == "status" else "release",
        ):
            with self.assertRaisesRegex(ValueError, "checkout is modified"):
                self.snapshot()


if __name__ == "__main__":
    unittest.main()
