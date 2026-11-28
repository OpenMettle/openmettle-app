import json
from pathlib import Path
import tempfile
import unittest

from android_fixture import APP_ID, CALLBACK, ISSUER, REDIRECT, association, update_fixture


class AndroidFixtureTest(unittest.TestCase):
    certificate = "-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n"

    def test_only_the_installed_debug_signer_is_associated(self):
        # Known SHA-256 of the synthetic certificate bytes b'abc'.
        expected = 'BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD'
        for signer in ('Signer #1 certificate', 'V2 Signer: certificate'):
            report = f'{signer} SHA-256 digest: unused\n' + self.certificate
            target = association(report)[0]['target']
            self.assertEqual(target['package_name'], APP_ID)
            self.assertEqual(target['sha256_cert_fingerprints'], [expected])

    def test_refuses_absent_ambiguous_or_malformed_certificates(self):
        for report in ('', self.certificate * 2, self.certificate.replace('YWJj', ''),
                       self.certificate.replace('YWJj', 'invalid!')):
            with self.subTest(report=report), self.assertRaises(ValueError):
                association(report)

    def test_realm_and_api_use_the_same_exact_native_callback(self):
        with tempfile.TemporaryDirectory() as work:
            realm = Path(work) / 'realm.json'
            settings = Path(work) / 'auth.json'
            realm.write_text(json.dumps({'clients': [{'redirectUris': [ISSUER + '/callback']}]}))
            settings.write_text(json.dumps({'browser': {'provider_id': 'fixture-provider'}}))
            update_fixture(realm, 'realm')
            update_fixture(settings, 'settings')
            document = json.loads(settings.read_text())
            native = document['native']
            key = Path(document['cursor_keys']['active']['path'])
            self.assertEqual(key.stat().st_size, 32)
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(realm.read_text())['clients'][0]['redirectUris'],
                             [ISSUER + '/callback', native['callback']])
            self.assertEqual((native['callback'], native['redirect_uri'], native['provider_id']),
                             (CALLBACK, REDIRECT, 'fixture-provider'))
