#!/usr/bin/env python3
"""Materialize only CI's selected Apple release fields outside the checkout."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets

ROOT = Path(__file__).resolve().parents[1]


def selected_config(value):
    common = value["common"]
    certificate = common["certificates"]["developerIdApplication"]
    asc = common["appStoreConnect"]
    for item in [certificate["p12Base64"], asc["privateKeyBase64"]]:
        base64.b64decode(item, validate=True)
    for item in [certificate["password"], certificate["identity"], asc["issuerId"], asc["keyId"]]:
        if not isinstance(item, str) or not item:
            raise ValueError("Missing Apple release field")
    return {"common": {
        "teamId": common["teamId"],
        "temporaryKeychainPassword": secrets.token_urlsafe(32),
        "certificates": {"developerIdApplication": {
            key: certificate[key] for key in ["p12Base64", "password", "identity"]
        }},
        "appStoreConnect": {
            key: asc[key] for key in ["issuerId", "keyId", "privateKeyBase64"]
        },
    }}


def materialize(value, output):
    output = output.resolve()
    if output.is_relative_to(ROOT):
        raise ValueError("Apple configuration must stay outside the checkout")
    content = json.dumps(selected_config(value)).encode()
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as file:
        file.write(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        materialize(json.loads(os.environ["APPLE_RELEASE_CONFIG"]), args.output)
    except Exception:
        raise SystemExit("Apple CI configuration is missing or invalid; no credential values were logged.")


if __name__ == "__main__":
    main()
