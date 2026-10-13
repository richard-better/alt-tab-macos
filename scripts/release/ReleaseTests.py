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

    def test_feed_and_cask_use_final_archive_bytes_and_fork_urls(self):
        metadata.generate(self.version, self.archive, self.signature, self.feed)
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

    def test_published_feed_preserves_older_compatible_releases(self):
        metadata.generate(self.version, self.archive, self.signature, self.feed)
        self.feed.write_bytes((self.root / "appcast.xml").read_bytes())
        newer = f"{metadata.version_tuple(self.version)[0] + 1}.0.0"
        archive = self.root / f"Switcheroo-{newer}.zip"
        archive.write_bytes(b"next release")
        metadata.generate(newer, archive, self.signature, self.feed)
        versions = [node.attrib[f"{{{metadata.SPARKLE}}}version"] for node in ET.parse(self.root / "appcast.xml").findall("channel/item/enclosure")]
        self.assertEqual(versions, [newer, self.version])

    def test_reused_or_older_version_cannot_replace_published_feed(self):
        metadata.generate(self.version, self.archive, self.signature, self.feed)
        self.feed.write_bytes((self.root / "appcast.xml").read_bytes())
        with self.assertRaisesRegex(ValueError, "published appcast"):
            metadata.generate(self.version, self.archive, self.signature, self.feed)

    def test_rejects_development_version_and_untrusted_version_strings(self):
        with self.assertRaisesRegex(ValueError, "development build"):
            metadata.validate_version(metadata.setting("CURRENT_PROJECT_VERSION"))
        for version in ["", "v12.0.0", "12.0", "12.0.0-beta", "012.0.0", "12.100.0", "12.0.0\n", "12.0.0; touch /tmp/injected"]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                metadata.validate_version(version)

    def test_rejects_wrong_archive_name_and_invalid_signatures_without_outputs(self):
        for signature in ["not-base64", base64.b64encode(bytes(32)).decode()]:
            with self.subTest(signature=signature), self.assertRaises(ValueError):
                metadata.generate(self.version, self.archive, signature, self.feed)
        with self.assertRaisesRegex(ValueError, "Archive name"):
            metadata.generate(self.version, self.root / "wrong.zip", self.signature, self.feed)
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
if name == "codesign" and "-dv" in args:
    print("TeamIdentifier=S64PDPJKMJ\\nAuthority=Developer ID Application: Richard Borcsik (S64PDPJKMJ)", file=sys.stderr)
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

    def test_timeout_and_gatekeeper_rejection_never_produce_final_archive(self):
        for status, environment in [("In Progress", {"NOTARY_EXIT": "1"}), ("Accepted", {"GATEKEEPER_EXIT": "1"})]:
            with self.subTest(status=status):
                (self.root / "commands").unlink(missing_ok=True)
                result, commands = self.run_notarization(status, **environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(sum(command[0] == "ditto" for command in commands), 1)


if __name__ == "__main__":
    unittest.main()
