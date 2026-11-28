"""Exercise the fixture identity check without a browser or provider."""

import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from journey import fixture_account


class Failure(Exception):
    pass


class FixtureAccountTest(unittest.TestCase):
    keycloak = SimpleNamespace(Failure=Failure, MAX_INPUT_BYTES=1024)
    approved = {
        "username": "synthetic-approved",
        "subject": "00000000-0000-4000-8000-0000000000a1",
        "password": "fixture-only",
    }
    invited = {
        "username": "synthetic-invited",
        "subject": "00000000-0000-4000-8000-0000000000b2",
        "password": "other-fixture-only",
    }

    def read(self, value):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            (directory / "accounts.json").write_text(json.dumps(value), encoding="utf-8")
            return fixture_account(directory, self.keycloak)

    def test_selects_the_exact_approved_identity(self):
        self.assertEqual(
            self.read({"approved": self.approved, "invited": self.invited}), self.approved)

    def test_refuses_other_identities_and_redacts_fixture_input(self):
        for value in (
            {"invited": self.invited},
            {"approved": self.invited},
            {"approved": {**self.approved, "subject": self.invited["subject"]}},
            {"approved": {**self.approved, "password": ""}},
            {"approved": {**self.approved, "password": "x" * 1024}},
        ):
            with self.subTest(case=list(value)):
                with self.assertRaisesRegex(Failure, "^approved fixture account invalid$"):
                    self.read(value)


if __name__ == "__main__":
    unittest.main()
