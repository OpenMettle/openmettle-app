"""Add the exact Android registration to the private core CI fixture."""
import json
import re
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


def association(fingerprint):
    if not re.fullmatch(r"[0-9a-fA-F]{64}", fingerprint):
        raise ValueError("invalid signing certificate fingerprint")
    return [{"relation": ["delegate_permission/common.handle_all_urls"], "target": {
        "namespace": "android_app", "package_name": APP_ID,
        "sha256_cert_fingerprints": [":".join(re.findall("..", fingerprint.upper()))],
    }}]


if __name__ == "__main__":
    if sys.argv[1] == "assetlinks":
        print(json.dumps(association(sys.argv[2])))
    else:
        update_fixture(Path(sys.argv[2]), sys.argv[1])
