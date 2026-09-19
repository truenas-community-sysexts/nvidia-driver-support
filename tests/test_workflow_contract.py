"""Contract: the issue release.yml opens, closed through promote.yml, yields
release notes the installer's selection accepts, for that train only.

Each stage runs the real code (release.yml's and promote.yml's github-script
under node, the selection snippet from get.sh), so a marker format change in
any one of them breaks CI instead of silently approving nothing, or
everything."""
import unittest

from release_fixtures import marker, release
from test_hardware_test_issue import render
from test_promote import apply, close
from test_release_selection import run_selection

VERSIONS = {"25.10": "25.10.7", "26": "26.0.0-BETA.3"}


def selected(releases, train):
    p = run_selection(releases, VERSIONS[train], train)
    return p.stdout if p.returncode == 0 else None


class SignOffChain(unittest.TestCase):
    def setUp(self):
        issues = render(run="80")["issues"]
        self.issues = {}
        for iss in issues:
            key = "26" if "26 beta" in iss["title"] else "25.10"
            self.issues[key] = dict(iss, number=len(self.issues) + 1,
                                    labels=[{"name": n} for n in iss["labels"]])
        self.releases = [release("v80", prerelease=True), release("v79")]

    def sign_off(self, train):
        out = close(self.issues[train], self.releases)
        self.assertEqual(len(out["updates"]), 1, out)
        self.releases = apply(self.releases, out["updates"][0])

    def test_before_any_sign_off_both_trains_keep_the_grandfathered_release(self):
        self.assertEqual(selected(self.releases, "25.10"), "v79")
        self.assertEqual(selected(self.releases, "26"), "v79")

    def test_a_sign_off_approves_its_own_train_only(self):
        self.sign_off("26")
        self.assertEqual(selected(self.releases, "26"), "v80")
        self.assertEqual(selected(self.releases, "25.10"), "v79")
        self.sign_off("25.10")
        self.assertEqual(selected(self.releases, "25.10"), "v80")
        self.assertEqual(selected(self.releases, "26"), "v80")

    def test_fixture_marker_matches_what_promote_writes(self):
        self.sign_off("25.10")
        self.assertIn(f"\n\n{marker('25.10')}\n", self.releases[0]["body"])


if __name__ == "__main__":
    unittest.main()
