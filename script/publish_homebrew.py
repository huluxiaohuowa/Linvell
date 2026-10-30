#!/usr/bin/env python3
"""Generate the Linvell cask from an already published, checksum-verified release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

REPOSITORY = "huluxiaohuowa/Linvell"


def version_tuple(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Only stable three-component versions can be published")
    return tuple(map(int, version.split(".")))


def checksum_for(text, filename):
    matches = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1] == filename:
            if not re.fullmatch(r"[0-9a-f]{64}", fields[0]):
                raise ValueError("Invalid release checksum")
            matches.append(fields[0])
    if len(matches) != 1:
        raise ValueError("Release checksum must identify the archive exactly once")
    return matches[0]


def render_cask(version, digest):
    version_tuple(version)
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("Invalid archive checksum")
    return f'''cask "linvell" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/{REPOSITORY}/releases/download/v#{{version}}/Linvell-#{{version}}-universal.zip"
  name "Linvell"
  desc "Native text and code editor"
  homepage "https://linvell.fuluwa.top/"

  depends_on macos: :sequoia

  app "Linvell.app"

  uninstall quit: "top.fuluwa.linvell"

  zap trash: [
    "~/Library/Application Support/Linvell",
    "~/Library/Caches/Linvell",
    "~/Library/Preferences/top.fuluwa.linvell.plist",
    "~/Library/Saved Application State/top.fuluwa.linvell.savedState",
  ]
end
'''


def write_cask(output, version, digest):
    if output.exists():
        old = re.search(r'^  version "([^\"]+)"$', output.read_text(), re.MULTILINE)
        if old and version_tuple(old[1]) > version_tuple(version):
            raise ValueError("Refusing to downgrade the Homebrew cask")
    content = render_cask(version, digest)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.tag.startswith("v"):
        raise SystemExit("Expected a stable vX.Y.Z release tag")
    version = args.tag[1:]
    version_tuple(version)
    release = json.loads(subprocess.check_output([
        "gh", "release", "view", args.tag, "--repo", REPOSITORY,
        "--json", "tagName,isDraft,isPrerelease,assets",
    ], text=True))
    if release["tagName"] != args.tag or release["isDraft"] or release["isPrerelease"]:
        raise SystemExit("Homebrew publication requires a published stable release")
    archive = f"Linvell-{version}-universal.zip"
    required = {archive, "SHA256SUMS.txt"}
    if not required.issubset({asset["name"] for asset in release["assets"]}):
        raise SystemExit("Published release is missing distribution assets")
    build = Path(os.environ.get("LINVELL_BUILD_DIR", Path.home() / "dev/build/linvell"))
    build.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="homebrew-", dir=build) as raw:
        directory = Path(raw)
        subprocess.run([
            "gh", "release", "download", args.tag, "--repo", REPOSITORY,
            "--pattern", archive, "--pattern", "SHA256SUMS.txt", "--dir", raw,
        ], check=True)
        expected = checksum_for((directory / "SHA256SUMS.txt").read_text(), archive)
        if hashlib.sha256((directory / archive).read_bytes()).hexdigest() != expected:
            raise SystemExit("Downloaded archive does not match the published checksum")
        write_cask(args.output, version, expected)
    print(f"Verified {args.tag}; generated {args.output}")


if __name__ == "__main__":
    main()
