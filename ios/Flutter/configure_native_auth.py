"""Generate Runner's native sign-in configuration from Flutter's DART_DEFINES."""

import base64
import binascii
import os
from pathlib import Path
import plistlib
import re
import sys


PROFILE_KEYS = {
    "OPENMETTLE_NATIVE_ISSUER": "OpenMettleNativeIssuer",
    "OPENMETTLE_NATIVE_CLIENT_ID": "OpenMettleNativeClientID",
    "OPENMETTLE_NATIVE_REDIRECT_URI": "OpenMettleNativeRedirectURI",
}
DNS_LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
DNS_HOST = rf"({DNS_LABEL}(?:\.{DNS_LABEL})*\.[a-z](?:[a-z0-9-]{{0,61}}[a-z0-9])?)"
ISSUER = re.compile(rf"https://{DNS_HOST}(?::([1-9][0-9]{{0,4}}))?")
CLIENT_ID = re.compile(r"[A-Za-z0-9._-]{1,128}")
REDIRECT = re.compile(rf"https://{DNS_HOST}((?:/[A-Za-z0-9._~-]+)+)")


def native_profile(dart_defines):
    values = {}
    for entry in filter(None, dart_defines.split(",")):
        try:
            key, separator, value = base64.b64decode(entry, validate=True).decode().partition("=")
        except (binascii.Error, UnicodeError):
            raise ValueError("DART_DEFINES must contain base64-encoded UTF-8 entries.") from None
        if key not in PROFILE_KEYS:
            continue
        if not separator or key in values:
            raise ValueError("Each native sign-in define must appear once as KEY=VALUE.")
        values[key] = value

    if not values:
        return {}, {}
    if values.keys() != PROFILE_KEYS.keys():
        raise ValueError("Set all three OPENMETTLE_NATIVE_* defines, or omit all three.")

    issuer, client_id, redirect = (values[key] for key in PROFILE_KEYS)
    origin = ISSUER.fullmatch(issuer)
    if len(issuer) > 2048 or not origin or len(origin[1]) > 253:
        raise ValueError("OPENMETTLE_NATIVE_ISSUER must be a canonical HTTPS DNS origin.")
    if origin[2] and (int(origin[2]) > 65535 or int(origin[2]) == 443):
        raise ValueError("OPENMETTLE_NATIVE_ISSUER must use a canonical HTTPS port.")
    if not CLIENT_ID.fullmatch(client_id):
        raise ValueError("OPENMETTLE_NATIVE_CLIENT_ID must match [A-Za-z0-9._-]{1,128}.")

    link = REDIRECT.fullmatch(redirect)
    if (
        len(redirect) > 2048
        or not link
        or len(link[1]) > 253
        or any(segment in (".", "..") for segment in link[2].split("/"))
    ):
        raise ValueError("OPENMETTLE_NATIVE_REDIRECT_URI must be HTTPS with a DNS host and literal path.")

    profile = {plist_key: values[key] for key, plist_key in PROFILE_KEYS.items()}
    return profile, {"com.apple.developer.associated-domains": [f"webcredentials:{link[1]}"]}


def write_plist(path, data):
    contents = plistlib.dumps(data)
    if not path.exists() or path.read_bytes() != contents:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)


def main():
    try:
        profile, entitlements = native_profile(os.environ.get("DART_DEFINES", ""))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if len(sys.argv) == 3 and sys.argv[1] == "entitlements":
        write_plist(Path(sys.argv[2]), entitlements)
        return 0

    # Xcode packages signing inputs before any Runner build phase runs. Verify
    # that the scheme pre-action supplied the entitlement for this exact profile.
    entitlement_path = Path(os.environ["SCRIPT_INPUT_FILE_2"])
    if not entitlement_path.is_file() or plistlib.loads(entitlement_path.read_bytes()) != entitlements:
        print("error: Build with the shared Runner scheme to generate matching native sign-in entitlements.", file=sys.stderr)
        return 1
    template = plistlib.loads(Path(os.environ["SCRIPT_INPUT_FILE_1"]).read_bytes())
    if any(key in template for key in PROFILE_KEYS.values()):
        print("error: Supply the native profile through Flutter build defines.", file=sys.stderr)
        return 1
    write_plist(Path(os.environ["SCRIPT_OUTPUT_FILE_0"]), template | profile)
    return 0


if __name__ == "__main__":
    sys.exit(main())
