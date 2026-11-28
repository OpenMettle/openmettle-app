"""Regression tests for the native iOS build profile and associated domain."""

from base64 import b64encode
import unittest

from configure_native_auth import native_profile


ISSUER = "OPENMETTLE_NATIVE_ISSUER=https://app.relying.test:18443"
CLIENT = "OPENMETTLE_NATIVE_CLIENT_ID=synthetic.ios"
REDIRECT = "OPENMETTLE_NATIVE_REDIRECT_URI=https://return.relying.test/native/complete"


def dart_defines(*entries):
    return ",".join(b64encode(entry.encode()).decode() for entry in entries)


class NativeBuildProfileTests(unittest.TestCase):
    def test_configured_profile_and_registration_share_the_same_define(self):
        profile, entitlements = native_profile(
            dart_defines(ISSUER, CLIENT, REDIRECT, "IGNORED=a=b")
        )
        self.assertEqual(
            profile,
            {
                "OpenMettleNativeIssuer": "https://app.relying.test:18443",
                "OpenMettleNativeClientID": "synthetic.ios",
                "OpenMettleNativeRedirectURI": "https://return.relying.test/native/complete",
            },
        )
        self.assertEqual(
            entitlements,
            {"com.apple.developer.associated-domains": ["webcredentials:return.relying.test"]},
        )

    def test_unconfigured_build_has_no_profile_or_associated_domain(self):
        self.assertEqual(native_profile(""), ({}, {}))
        self.assertEqual(native_profile(dart_defines("OTHER=value")), ({}, {}))

    def test_partial_and_duplicate_defines_fail_the_build(self):
        for entries in [(ISSUER,), (ISSUER, CLIENT), (ISSUER, CLIENT, REDIRECT, REDIRECT)]:
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                native_profile(dart_defines(*entries))

    def test_malformed_values_fail_the_build(self):
        for entries in [
            (ISSUER.replace("18443", "443"), CLIENT, REDIRECT),
            (ISSUER + "/", CLIENT, REDIRECT),
            (ISSUER, CLIENT + " ", REDIRECT),
            (ISSUER, CLIENT, REDIRECT + "?code=data"),
            (ISSUER, CLIENT, REDIRECT.replace("/complete", "/../complete")),
            (ISSUER, CLIENT, REDIRECT.replace(".test", ".test:8443")),
            (ISSUER, CLIENT, REDIRECT.replace("https://", "http://")),
            (ISSUER, CLIENT, "OPENMETTLE_NATIVE_REDIRECT_URI="),
        ]:
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                native_profile(dart_defines(*entries))
        with self.assertRaises(ValueError):
            native_profile("!")


if __name__ == "__main__":
    unittest.main()
