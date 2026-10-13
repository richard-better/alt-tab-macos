"""Create release metadata from the final stapled ZIP."""

import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "richard-better/switcheroo"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def version_tuple(version):
    if not re.fullmatch(r"[1-9][0-9]{0,3}\.(?:0|[1-9][0-9]?)\.(?:0|[1-9][0-9]?)", version):
        raise ValueError("Use a numeric major.minor.patch version without leading zeroes")
    return tuple(map(int, version.split(".")))


def setting(name):
    match = re.search(rf"^{name} = ([^\s/]+)", (ROOT / "config/base.xcconfig").read_text(), re.MULTILINE)
    if not match:
        raise ValueError(f"Missing {name} in config/base.xcconfig")
    return match[1]


def validate_version(version):
    if version_tuple(version) <= version_tuple(setting("CURRENT_PROJECT_VERSION")):
        raise ValueError("Release version must exceed the development build's CURRENT_PROJECT_VERSION")


def minimum_macos_symbol():
    symbols = {12: "monterey", 13: "ventura", 14: "sonoma", 15: "sequoia", 26: "tahoe"}
    major = int(setting("MACOSX_DEPLOYMENT_TARGET").split(".")[0])
    if major not in symbols:
        raise ValueError("Add the deployment target's Homebrew macOS symbol to minimum_macos_symbol")
    return symbols[major]


def generate(version, archive, signature, previous_feed):
    validate_version(version)
    macos_symbol = minimum_macos_symbol()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Expected a 64-byte Ed25519 signature")
    archive = Path(archive)
    if archive.name != f"Switcheroo-{version}.zip":
        raise ValueError("Archive name must match the release version")
    feed = ET.parse(previous_feed)
    channel = feed.getroot().find("channel")
    if channel is None:
        raise ValueError("The previous appcast has no channel")
    for enclosure in channel.findall("item/enclosure"):
        if version_tuple(enclosure.attrib[f"{{{SPARKLE}}}version"]) >= version_tuple(version):
            raise ValueError("Release version must exceed every version in the published appcast")
    digest = hashlib.sha256()
    with archive.open("rb") as contents:
        for chunk in iter(lambda: contents.read(1024 * 1024), b""):
            digest.update(chunk)
    checksum = digest.hexdigest()
    tag = f"switcheroo-v{version}"
    url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{archive.name}"
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Switcheroo {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = setting("MACOSX_DEPLOYMENT_TARGET")
    ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink").text = f"https://github.com/{REPOSITORY}/releases/tag/{tag}"
    ET.SubElement(item, "enclosure", {
        "url": url,
        f"{{{SPARKLE}}}version": version,
        f"{{{SPARKLE}}}shortVersionString": version,
        f"{{{SPARKLE}}}edSignature": signature,
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
    })
    first_item = next((i for i, node in enumerate(channel) if node.tag == "item"), len(channel))
    channel.insert(first_item, item)
    ET.indent(feed, space="  ")
    feed.write(archive.parent / "appcast.xml", encoding="utf-8", xml_declaration=True)
    (archive.parent / "SHA256SUMS").write_text(f"{checksum}  {archive.name}\n")
    (archive.parent / "switcheroo.rb").write_text(f'''cask "switcheroo" do
  version "{version}"
  sha256 "{checksum}"

  url "https://github.com/{REPOSITORY}/releases/download/switcheroo-v#{{version}}/Switcheroo-#{{version}}.zip"
  name "Switcheroo"
  desc "Window and browser tab switcher"
  homepage "https://github.com/{REPOSITORY}"

  auto_updates true
  depends_on macos: :{macos_symbol}

  app "Switcheroo.app"
end
''')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("version")
    metadata = commands.add_parser("generate")
    metadata.add_argument("version")
    metadata.add_argument("archive", type=Path)
    metadata.add_argument("signature")
    metadata.add_argument("--previous-feed", type=Path, default=ROOT / "browser-tabs-appcast.xml")
    args = parser.parse_args()
    try:
        if args.command == "validate":
            validate_version(args.version)
        else:
            generate(args.version, args.archive, args.signature, args.previous_feed)
    except (ValueError, OSError, ET.ParseError) as error:
        parser.exit(1, f"Release metadata: {error}\n")


if __name__ == "__main__":
    main()
