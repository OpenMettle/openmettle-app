"""Add the exact Android registration to the private core CI fixture."""
import base64
import hashlib
import json
import sys
from pathlib import Path

APP_ID = "org.openmettle.app.debug"
CLIENT = "synthetic.android"
ISSUER = "https://app.relying.test:18443"
CALLBACK = ISSUER + "/auth/native/callback"
LINK_HOST = "return.relying.test"
REDIRECT = "https://" + LINK_HOST + "/native/complete"


def update_fixture(path, stage):
    document = json.loads(path.read_bytes())
    if stage == "realm":
        client, = document["clients"]
        if client["redirectUris"] != [ISSUER + "/callback"]:
            raise ValueError("unexpected fixture redirect")
        client["redirectUris"].append(CALLBACK)
    elif stage == "settings":
        document["native"] = {
            "provider_id": document["browser"]["provider_id"], "issuer": ISSUER,
            "callback": CALLBACK, "client_id": CLIENT, "redirect_uri": REDIRECT,
            "rate": {"burst": 20, "interval_milliseconds": 500}, "max_in_flight": 8,
        }
    else:
        raise ValueError("unknown fixture stage")
    path.write_text(json.dumps(document), encoding="utf-8")


def association(signer_report):
    # apksigner verifies the APK before printing its public certificate. The
    # surrounding signer labels differ across Android Build Tools versions.
    lines = signer_report.splitlines()
    begin, end = "-----BEGIN CERTIFICATE-----", "-----END CERTIFICATE-----"
    if lines.count(begin) != 1 or lines.count(end) != 1:
        raise ValueError("expected one APK signing certificate")
    encoded = "".join(lines[lines.index(begin) + 1:lines.index(end)])
    if not encoded:
        raise ValueError("empty APK signing certificate")
    certificate = base64.b64decode(encoded, validate=True)
    fingerprint = hashlib.sha256(certificate).digest().hex(":").upper()
    return [{"relation": ["delegate_permission/common.handle_all_urls"], "target": {
        "namespace": "android_app", "package_name": APP_ID,
        "sha256_cert_fingerprints": [fingerprint],
    }}]


if __name__ == "__main__":
    if sys.argv[1] == "assetlinks":
        print(json.dumps(association(sys.stdin.read())))
    else:
        update_fixture(Path(sys.argv[2]), sys.argv[1])
