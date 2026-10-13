"""Run with python3 scripts/release/ReleaseTests.py."""

import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import tempfile
import subprocess
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import metadata


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        current = metadata.version_tuple(metadata.setting("CURRENT_PROJECT_VERSION"))
        self.version = f"{current[0] + 1}.0.0"
        self.archive = self.root / f"Switcheroo-{self.version}.zip"
        self.archive.write_bytes(b"final stapled archive")
        self.signature = base64.b64encode(bytes(64)).decode()
        self.feed = self.root / "previous.xml"
        self.feed.write_text((metadata.ROOT / "browser-tabs-appcast.xml").read_text())
        self.changelog = self.root / "changelog.md"
        self.notes = "### Features\n\n- Switch browser tabs.\n\n### Upstream\n\nBased on AltTab 11.9.1, commit eb63ac15.\n"
        self.changelog.write_text(f"# Switcheroo changelog\n\n## {self.version}\n\n{self.notes}\n## 1.0.0\n\nOlder notes.\n")

    def test_feed_and_cask_use_final_archive_bytes_and_fork_urls(self):
        metadata.generate(self.version, self.archive, self.signature, self.feed, self.changelog)
        enclosure = ET.parse(self.root / "appcast.xml").find("channel/item/enclosure")
        self.assertIn(f"/{metadata.REPOSITORY}/", enclosure.attrib["url"])
        self.assertIn(f"/switcheroo-v{self.version}/", enclosure.attrib["url"])
        self.assertEqual(enclosure.attrib["length"], str(self.archive.stat().st_size))
        self.assertEqual(enclosure.attrib[f"{{{metadata.SPARKLE}}}edSignature"], self.signature)
        checksum = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.assertEqual((self.root / "SHA256SUMS").read_text(), f"{checksum}  {self.archive.name}\n")
        cask = (self.root / "switcheroo.rb").read_text()
        self.assertIn(checksum, cask)
        self.assertIn(f'version "{self.version}"', cask)
        self.assertNotIn("lwouis", cask)

    def test_release_notes_copy_only_the_selected_changelog_entry_with_upstream_details(self):
        metadata.generate(self.version, self.archive, self.signature, self.feed, self.changelog)
        self.assertEqual((self.root / "release-notes.md").read_text(), self.notes)

    def test_missing_or_empty_changelog_entry_stops_metadata_generation(self):
        for contents in ["# Switcheroo changelog\n", f"## {self.version}\n\n## 1.0.0\n\nOlder notes.\n"]:
            with self.subTest(contents=contents), self.assertRaisesRegex(ValueError, "changelog entry"):
                self.changelog.write_text(contents)
                metadata.generate(self.version, self.archive, self.signature, self.feed, self.changelog)
            self.assertFalse((self.root / "appcast.xml").exists())
            self.assertFalse((self.root / "release-notes.md").exists())

    def test_published_feed_preserves_older_compatible_releases(self):
        metadata.generate(self.version, self.archive, self.signature, self.feed, self.changelog)
        self.feed.write_bytes((self.root / "appcast.xml").read_bytes())
        newer = f"{metadata.version_tuple(self.version)[0] + 1}.0.0"
        archive = self.root / f"Switcheroo-{newer}.zip"
        archive.write_bytes(b"next release")
        self.changelog.write_text(f"## {newer}\n\nNext release.\n\n" + self.changelog.read_text())
        metadata.generate(newer, archive, self.signature, self.feed, self.changelog)
        versions = [node.attrib[f"{{{metadata.SPARKLE}}}version"] for node in ET.parse(self.root / "appcast.xml").findall("channel/item/enclosure")]
        self.assertEqual(versions, [newer, self.version])

    def test_reused_or_older_version_cannot_replace_published_feed(self):
        metadata.generate(self.version, self.archive, self.signature, self.feed, self.changelog)
        self.feed.write_bytes((self.root / "appcast.xml").read_bytes())
        with self.assertRaisesRegex(ValueError, "published appcast"):
            metadata.generate(self.version, self.archive, self.signature, self.feed, self.changelog)

    def test_accepts_current_version_and_rejects_older_or_untrusted_versions(self):
        metadata.validate_version(metadata.setting("CURRENT_PROJECT_VERSION"))
        with patch.object(metadata, "setting", return_value="1.2.0"):
            with self.assertRaisesRegex(ValueError, "development build"):
                metadata.validate_version("1.1.9")
        for version in ["", "v12.0.0", "12.0", "12.0.0-beta", "012.0.0", "12.100.0", "12.0.0\n", "12.0.0; touch /tmp/injected"]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                metadata.validate_version(version)

    def test_rejects_wrong_archive_name_and_invalid_signatures_without_outputs(self):
        for signature in ["not-base64", base64.b64encode(bytes(32)).decode()]:
            with self.subTest(signature=signature), self.assertRaises(ValueError):
                metadata.generate(self.version, self.archive, signature, self.feed)
        with self.assertRaisesRegex(ValueError, "Archive name"):
            metadata.generate(self.version, self.root / "wrong.zip", self.signature, self.feed, self.changelog)
        self.assertFalse((self.root / "switcheroo.rb").exists())
        self.assertFalse((self.root / "appcast.xml").exists())

    def test_update_signature_checks_the_archive_and_embedded_public_key(self):
        fixture = subprocess.run(["swift", "-e", '''
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let other = Curve25519.Signing.PrivateKey()
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let result = ["signature": try key.signature(for: data).base64EncodedString(),
              "publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
              "otherKey": other.publicKey.rawRepresentation.base64EncodedString()]
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
''', str(self.archive)], check=True, capture_output=True, text=True)
        keys = json.loads(fixture.stdout)
        command = ["swift", str(metadata.ROOT / "scripts/release/VerifyUpdate.swift"), str(self.archive), keys["signature"]]
        verified = subprocess.run(command + [keys["publicKey"]], capture_output=True)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        wrong_key = subprocess.run(command + [keys["otherKey"]], capture_output=True)
        self.assertNotEqual(wrong_key.returncode, 0)
        self.archive.write_bytes(b"tampered archive")
        tampered = subprocess.run(command + [keys["publicKey"]], capture_output=True)
        self.assertNotEqual(tampered.returncode, 0)


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        current = metadata.version_tuple(metadata.setting("CURRENT_PROJECT_VERSION"))
        self.version = f"{current[0] + 1}.0.0"
        app = self.root / "products/Switcheroo.app/Contents"
        app.mkdir(parents=True)
        with (app / "Info.plist").open("wb") as contents:
            plistlib.dump({"CFBundleVersion": self.version, "CFBundleIdentifier": "me.richardb.window-switcher"}, contents)
        binaries = self.root / "bin"
        binaries.mkdir()
        stub = binaries / "stub"
        stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["COMMAND_LOG"], "a") as log:
    log.write(json.dumps([name] + args) + "\\n")
if name == "codesign" and any(arg.startswith("--test-requirement=") for arg in args):
    sys.exit(int(os.environ.get("REQUIREMENT_EXIT", "0")))
elif name == "ditto":
    pathlib.Path(args[-1]).write_bytes(b"packaged app")
elif name == "xcrun" and args[:2] == ["notarytool", "submit"]:
    print(json.dumps({"status": os.environ["NOTARY_STATUS"], "id": "submission-id"}))
    sys.exit(int(os.environ.get("NOTARY_EXIT", "0")))
elif name == "xcrun" and args[:2] == ["notarytool", "log"]:
    pathlib.Path(args[-1]).write_text('{"issues":["invalid signature"]}')
elif name == "spctl":
    sys.exit(int(os.environ.get("GATEKEEPER_EXIT", "0")))
''')
        stub.chmod(0o755)
        for name in ["codesign", "ditto", "xcrun", "spctl"]:
            (binaries / name).symlink_to(stub)
        self.environment = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}", RELEASE_VERSION=self.version,
                                RELEASE_DIR=str(self.root / "release"), XCODE_BUILD_PATH=str(self.root / "products"),
                                NOTARY_KEYCHAIN_PROFILE="fixture", COMMAND_LOG=str(self.root / "commands"))

    def run_notarization(self, status, **environment):
        result = subprocess.run(["bash", "scripts/package_and_notarize_release.sh"], cwd=metadata.ROOT,
                                env=dict(self.environment, NOTARY_STATUS=status, **environment), capture_output=True)
        commands = [json.loads(line) for line in (self.root / "commands").read_text().splitlines()]
        return result, commands

    def test_accepted_submission_staples_validates_and_assesses_before_repackaging(self):
        result, commands = self.run_notarization("Accepted")
        self.assertEqual(result.returncode, 0, result.stderr)
        packaging = [i for i, command in enumerate(commands) if command[0] == "ditto"]
        self.assertEqual(len(packaging), 2)
        for operation in [["xcrun", "stapler", "staple"], ["xcrun", "stapler", "validate"], ["spctl"]]:
            index = next(i for i, command in enumerate(commands) if command[:len(operation)] == operation)
            self.assertLess(packaging[0], index)
            self.assertLess(index, packaging[1])

    def test_rejected_submission_downloads_log_and_never_staples(self):
        for exit_code in ["0", "1"]:
            with self.subTest(exit_code=exit_code):
                (self.root / "commands").unlink(missing_ok=True)
                result, commands = self.run_notarization("Invalid", NOTARY_EXIT=exit_code)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((self.root / "release/notarization-log.json").exists())
                self.assertFalse(any(command[:2] == ["xcrun", "stapler"] for command in commands))
                self.assertEqual(sum(command[0] == "ditto" for command in commands), 1)

    def test_wrong_signing_identity_never_reaches_notarization(self):
        result, commands = self.run_notarization("Accepted", REQUIREMENT_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(command[0] in ["ditto", "xcrun"] for command in commands))

    def test_timeout_and_gatekeeper_rejection_never_produce_final_archive(self):
        for status, environment in [("In Progress", {"NOTARY_EXIT": "1"}), ("Accepted", {"GATEKEEPER_EXIT": "1"})]:
            with self.subTest(status=status):
                (self.root / "commands").unlink(missing_ok=True)
                result, commands = self.run_notarization(status, **environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(sum(command[0] == "ditto" for command in commands), 1)


class PublicationTests(unittest.TestCase):
    def test_published_body_uses_prepared_changelog_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notes = "### Upstream\n\nAltTab 11.9.1, commit eb63ac15.\n"
            (root / "release-notes.md").write_text(notes)
            gh = root / "gh"
            gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1:3] == ["release", "create"]:
    args = sys.argv[3:]
    notes = pathlib.Path(args[args.index("--notes-file") + 1]).read_text()
    pathlib.Path(os.environ["COMMAND_LOG"]).write_text(json.dumps({"args": args, "notes": notes}))
''')
            gh.chmod(0o755)
            git = root / "git"
            git.write_text("#!/usr/bin/env bash\nexit 1\n")
            git.chmod(0o755)
            log = root / "published.json"
            environment = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", RELEASE_VERSION="1.0.0",
                               RELEASE_DIR=str(root), GITHUB_SHA="a" * 40, COMMAND_LOG=str(log))
            result = subprocess.run(["bash", "scripts/release/publish.sh"], cwd=metadata.ROOT,
                                    env=environment, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            published = json.loads(log.read_text())
            self.assertEqual(published["notes"], notes)
            self.assertNotIn("--generate-notes", published["args"])


if __name__ == "__main__":
    unittest.main()
