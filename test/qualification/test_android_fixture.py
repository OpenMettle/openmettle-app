import json
from pathlib import Path
import tempfile
import unittest

from android_fixture import APP_ID, CALLBACK, ISSUER, REDIRECT, association, update_fixture


class AndroidFixtureTest(unittest.TestCase):
    def test_only_the_installed_debug_signer_is_associated(self):
        digest = '0123456789abcdef' * 4
        target = association(digest)[0]['target']
        self.assertEqual(target['package_name'], APP_ID)
        self.assertEqual(target['sha256_cert_fingerprints'], [bytes.fromhex(digest).hex(':').upper()])
        for invalid in (digest[:63], digest + '\n', 'not-a-digest'):
            with self.assertRaises(ValueError):
                association(invalid)

    def test_realm_and_api_use_the_same_exact_native_callback(self):
        with tempfile.TemporaryDirectory() as work:
            realm = Path(work) / 'realm.json'
            settings = Path(work) / 'auth.json'
            realm.write_text(json.dumps({'clients': [{'redirectUris': [ISSUER + '/callback']}]}))
            settings.write_text(json.dumps({'browser': {'provider_id': 'fixture-provider'}}))
            update_fixture(realm, 'realm')
            update_fixture(settings, 'settings')
            native = json.loads(settings.read_text())['native']
            self.assertEqual(json.loads(realm.read_text())['clients'][0]['redirectUris'],
                             [ISSUER + '/callback', native['callback']])
            self.assertEqual((native['callback'], native['redirect_uri'], native['provider_id']),
                             (CALLBACK, REDIRECT, 'fixture-provider'))
