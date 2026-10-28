#!/usr/bin/env python3
"""Local Developer ID release. Reuses ~/.apple.json common; never uploads to App Store Connect."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    result = subprocess.run(
        [str(a) for a in args],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        **kwargs,
    )
    if result.returncode:
        # Tool output can contain signing identities. Keep it in a protected local log.
        log = Path.home() / "dev/build/linvell/release-error.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_bytes(result.stdout)
        log.chmod(0o600)
        raise SystemExit(
            f"{Path(args[0]).name} failed; inspect the protected local release-error.log"
        )
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument(
        "--publish",
        action="store_true",
        help="Publish the prepared, notarized artifacts as a GitHub release",
    )
    parser.add_argument("--config", type=Path, default=Path.home() / ".apple.json")
    parser.add_argument(
        "--update-test-base-version",
        help="Create a separately signed local baseline app for update integration tests",
    )
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        raise SystemExit("Expected a release version, e.g. 0.1.1")
    if args.update_test_base_version and not re.fullmatch(
        r"\d+\.\d+\.\d+-preview\.\d+", args.update_test_base_version
    ):
        raise SystemExit("Invalid update test baseline version")
    os.chdir(ROOT)
    if run(["git", "status", "--porcelain"]).strip():
        raise SystemExit("Commit the reviewed source before packaging.")
    if (
        plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())[
            "CFBundleShortVersionString"
        ]
        != args.version.split("-")[0]
    ):
        raise SystemExit("Bundle version does not match release version")
    if (
        plistlib.loads((ROOT / "Resources/Info.plist").read_bytes()).get(
            "LinvellReleaseVersion"
        )
        != args.version
    ):
        raise SystemExit("Update version does not match release version")
    revision = run(["git", "rev-parse", "HEAD"]).decode().strip()
    config = json.loads(args.config.expanduser().read_text())
    common = config["common"]
    cert = common["certificates"]["developerIdApplication"]
    asc = common["appStoreConnect"]
    output = Path.home() / "dev/build/linvell/releases" / args.version
    output.mkdir(parents=True, exist_ok=True)
    print("Running tests and building Universal macOS app locally…", flush=True)
    run(["swift", "test"])
    env = dict(os.environ, CONFIGURATION="release", LINVELL_UNIVERSAL="1")
    run(["bash", "script/build_and_run.sh", "--build-only"], env=env)
    app = Path.home() / "dev/build/linvell/release/Linvell.app"
    architectures = (
        run(["lipo", "-archs", app / "Contents/MacOS/Linvell"]).decode().strip().split()
    )
    if set(architectures) != {"arm64", "x86_64"}:
        raise SystemExit("Universal binary verification failed")
    load_commands = run(
        ["xcrun", "vtool", "-show-build", app / "Contents/MacOS/Linvell"]
    ).decode()
    if re.findall(r"minos\s+(\S+)", load_commands) != ["15.6", "15.6"]:
        raise SystemExit("Mach-O minimum system version does not match macOS 15.6")
    with tempfile.TemporaryDirectory(prefix="linvell-sign-") as raw:
        temp = Path(raw)
        temp.chmod(0o700)
        p12 = temp / "developer-id.p12"
        p12.write_bytes(base64.b64decode(cert["p12Base64"], validate=True))
        p12.chmod(0o600)
        key = temp / "notary.p8"
        key.write_bytes(base64.b64decode(asc["privateKeyBase64"], validate=True))
        key.chmod(0o600)
        keychain = temp / "release.keychain-db"
        password = common["temporaryKeychainPassword"]
        print("Signing with Developer ID and Hardened Runtime…", flush=True)
        try:
            run(["security", "create-keychain", "-p", password, keychain])
            run(["security", "set-keychain-settings", "-lut", "21600", keychain])
            run(["security", "unlock-keychain", "-p", password, keychain])
            run(
                [
                    "security",
                    "import",
                    p12,
                    "-k",
                    keychain,
                    "-P",
                    cert["password"],
                    "-T",
                    "/usr/bin/codesign",
                ]
            )
            run(
                [
                    "security",
                    "set-key-partition-list",
                    "-S",
                    "apple-tool:,apple:,codesign:",
                    "-s",
                    "-k",
                    password,
                    keychain,
                ]
            )
            signing = [
                "codesign",
                "--force",
                "--sign",
                cert["identity"],
                "--keychain",
                keychain,
                "--timestamp",
                "--options",
                "runtime",
            ]
            run(signing + [app / "Contents/Helpers/LinvellUpdater"])
            run(signing + [app])
            run(["codesign", "--verify", "--deep", "--strict", app])
            submission = temp / "submission.zip"
            run(
                [
                    "ditto",
                    "-c",
                    "-k",
                    "--sequesterRsrc",
                    "--keepParent",
                    app,
                    submission,
                ]
            )
            print("Submitting to Apple notarization…", flush=True)
            response = json.loads(
                run(
                    [
                        "xcrun",
                        "notarytool",
                        "submit",
                        submission,
                        "--key",
                        key,
                        "--key-id",
                        asc["keyId"],
                        "--issuer",
                        asc["issuerId"],
                        "--wait",
                        "--timeout",
                        "20m",
                        "--output-format",
                        "json",
                    ]
                )
            )
            if response.get("status") != "Accepted":
                raise SystemExit(
                    "Notarization was not accepted. No release was published."
                )
            run(["xcrun", "stapler", "staple", app])
            run(["xcrun", "stapler", "validate", app])
            run(["spctl", "--assess", "--type", "execute", app])
            print(
                "Notarization accepted; staple and Gatekeeper checks passed.",
                flush=True,
            )
            if args.update_test_base_version:
                baseline = output / "update-test-base" / "Linvell.app"
                if baseline.exists():
                    raise SystemExit(
                        "Update test baseline already exists; preserve it before retrying"
                    )
                run(["ditto", app, baseline])
                info_path = baseline / "Contents/Info.plist"
                info = plistlib.loads(info_path.read_bytes())
                info["LinvellReleaseVersion"] = args.update_test_base_version
                info["CFBundleVersion"] = "1"
                info_path.write_bytes(plistlib.dumps(info))
                run(signing + [baseline])
                run(["codesign", "--verify", "--deep", "--strict", baseline])
                print("Signed local update-test baseline prepared.", flush=True)
        finally:
            search_list = shlex.split(
                run(["security", "list-keychains", "-d", "user"]).decode()
            )
            retained = [path for path in search_list if Path(path) != keychain]
            if retained != search_list:
                run(["security", "list-keychains", "-d", "user", "-s", *retained])
            subprocess.run(
                ["security", "delete-keychain", str(keychain)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
    zip_path = output / f"Linvell-{args.version}-universal.zip"
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path])
    staging = output / "dmg-content"
    staging.mkdir(exist_ok=True)
    run(["ditto", app, staging / "Linvell.app"])
    link = staging / "Applications"
    if not link.exists():
        link.symlink_to("/Applications")
    dmg = output / f"Linvell-{args.version}-universal.dmg"
    run(
        [
            "hdiutil",
            "create",
            "-volname",
            "Linvell",
            "-srcfolder",
            staging,
            "-ov",
            "-format",
            "UDZO",
            dmg,
        ]
    )
    # The stapled .app is identical in both archives. DMG itself has no executable code.
    checksums = output / "SHA256SUMS.txt"
    checksums.write_text(
        "".join(
            hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name + "\n"
            for p in [zip_path, dmg]
        )
    )
    manifest = {
        "version": args.version,
        "commit": revision,
        "architectures": architectures,
        "minimumMacOS": "15.6",
        "notarization": "Accepted",
        "stapled": True,
        "gatekeeper": "accepted",
        "distribution": "GitHub Releases",
        "build": "local Mac",
        "intelRuntimeTested": False,
    }
    manifest_path = output / "release-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    if args.publish:
        notes = ROOT / "docs/releases" / (args.version + ".md")
        if not notes.is_file():
            raise SystemExit("Release notes must exist before publishing")
        run(
            [
                "git",
                "-c",
                "credential.helper=",
                "-c",
                "credential.helper=!gh auth git-credential",
                "push",
                "origin",
                "HEAD:main",
            ]
        )
        run(
            [
                "gh",
                "release",
                "create",
                "v" + args.version,
                "--repo",
                "huluxiaohuowa/Linvell",
                "--target",
                revision,
                "--title",
                "Linvell " + args.version,
                "--latest",
                "--notes-file",
                notes,
                zip_path,
                dmg,
                checksums,
                manifest_path,
            ]
        )
        print("Published GitHub release v" + args.version, flush=True)
    print("Artifacts: " + str(output), flush=True)


if __name__ == "__main__":
    main()
