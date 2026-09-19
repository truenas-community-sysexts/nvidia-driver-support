"""Unit tests for the approved-for-train release selection.

get.sh and scripts/install-nvidia-driver.sh each carry a verbatim copy of the
shared block between the BEGIN/END approved-release sentinels (both are
self-contained curl|bash scripts). The Python between the BEGIN/END
release-selection sentinels is extracted verbatim and run with canned GitHub
releases JSON on stdin, exactly how the scripts run it; the shell functions
are run under bash with stubbed commands."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from release_fixtures import release

ROOT = Path(__file__).resolve().parents[1]
GET_SH = ROOT / "get.sh"
INSTALL_SH = ROOT / "scripts" / "install-nvidia-driver.sh"
TRACKED = ROOT / ".github" / "tracked-versions.json"
REPO = "truenas-community-sysexts/nvidia-driver-support"


def between(path, begin, end):
    text = path.read_text()
    return text[text.index(begin):text.index(end)]


def shared_block(path):
    return between(path, "# BEGIN approved-release", "# END approved-release")


def selection_snippet():
    return between(GET_SH, "# BEGIN release-selection", "# END release-selection")


def run_selection_raw(text, version, train):
    return subprocess.run(
        ["python3", "-c", selection_snippet()],
        input=text, capture_output=True, text=True,
        env={"VERSION": version, "TRAIN": train, "REPO": REPO,
             "PATH": os.environ["PATH"]})


def run_selection(releases, version, train):
    return run_selection_raw(json.dumps(releases), version, train)


def run_block(commands, env=None):
    """Run the shared block from get.sh, then `commands`, under bash."""
    script = f"REPO={REPO}\n{shared_block(GET_SH)}\n{commands}\n"
    return subprocess.run(["bash", "-c", script], capture_output=True,
                          text=True, env=dict(os.environ, **(env or {})))


def train_key(version):
    p = run_block(f'truenas_train_key "{version}"')
    return p.stdout.strip() if p.returncode == 0 else None


STABLE = ("25.10.7", "25.10")
BETA = ("26.0.0-BETA.3", "26")


class SharedCopies(unittest.TestCase):
    def test_block_is_identical_in_get_sh_and_the_installer(self):
        self.assertEqual(shared_block(GET_SH), shared_block(INSTALL_SH))


class Approval(unittest.TestCase):
    def test_marker_for_the_train_is_approved(self):
        rels = [release("v80", trains=["26"]), release("v79")]
        p = run_selection(rels, *BETA)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v80")

    def test_marker_for_another_train_only_is_rejected(self):
        # A 26 sign-off says nothing about 25.10: those boxes keep v79.
        rels = [release("v80", trains=["26"]), release("v79")]
        p = run_selection(rels, *STABLE)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v79")

    def test_grandfathered_full_release_is_approved_for_every_train(self):
        rels = [release("v79"), release("v77", prerelease=True)]
        for version, train in (STABLE, BETA, ("25.04.2.6", "25.04")):
            p = run_selection(rels, version, train)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout, "v79", train)

    def test_prerelease_without_marker_is_rejected(self):
        rels = [release("v80", prerelease=True), release("v79")]
        for version, train in (STABLE, BETA):
            p = run_selection(rels, version, train)
            self.assertEqual(p.stdout, "v79", train)

    def test_prerelease_with_marker_is_approved(self):
        # The marker is the approval; the prerelease flag does not veto it
        # (per-kernel repos keep signed-off preview builds as prereleases).
        rels = [release("v80", prerelease=True, trains=["26"]), release("v79")]
        p = run_selection(rels, *BETA)
        self.assertEqual(p.stdout, "v80")

    def test_draft_is_rejected(self):
        rels = [release("v81", draft=True, trains=["25.10"]),
                release("v81-draft-full", draft=True), release("v79")]
        p = run_selection(rels, *STABLE)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v79")

    def test_newest_approved_release_wins(self):
        rels = [release("v78", trains=["25.10"]), release("v80", trains=["25.10"]),
                release("v79", trains=["25.10"]), release("v81", prerelease=True)]
        p = run_selection(rels, *STABLE)
        self.assertEqual(p.stdout, "v80")

    def test_newest_is_by_publication_date_not_list_order(self):
        rels = [release("v79", published="2026-09-19T00:00:00Z"),
                release("v80", trains=["25.10"], published="2026-09-20T00:00:00Z")]
        p = run_selection(list(reversed(rels)), *STABLE)
        self.assertEqual(p.stdout, "v80")

    def test_marker_must_start_a_line(self):
        # A changelog line quoting a marker (a PR title, say) is not an
        # approval: promote.yml writes the marker on a line of its own.
        body = "## Changelog\n* ci: add <!-- verified-train: 25.10 --> by @x\n"
        rels = [release("v80", prerelease=True, body=body), release("v79")]
        p = run_selection(rels, *STABLE)
        self.assertEqual(p.stdout, "v79")

    def test_marker_spacing_and_crlf_are_tolerated(self):
        body = "notes\r\n\r\n<!--verified-train:26-->\r\n"
        rels = [release("v80", body=body), release("v79")]
        p = run_selection(rels, *BETA)
        self.assertEqual(p.stdout, "v80")

    def test_marker_does_not_match_a_longer_train_key(self):
        rels = [release("v80", trains=["25.1"]), release("v79")]
        p = run_selection(rels, *STABLE)
        self.assertEqual(p.stdout, "v79")

    def test_beta_tagged_full_release_is_not_grandfathered(self):
        # Mirrors the preview lock in the per-kernel repos; this repo's v<N>
        # tags never carry BETA/RC.
        rels = [release("v26.0.0-BETA.1-r5")]
        p = run_selection(rels, *STABLE)
        self.assertNotEqual(p.returncode, 0)


class NoCandidate(unittest.TestCase):
    def test_no_approved_release_fails_clearly(self):
        rels = [release("v80", prerelease=True), release("v81", prerelease=True),
                release("v82", trains=["25.10"])]
        p = run_selection(rels, *BETA)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("No release is approved for TrueNAS train 26 yet", p.stderr)
        self.assertIn("26.0.0-BETA.3", p.stderr)
        # Newest first, drafts left out.
        self.assertLess(p.stderr.index("v82"), p.stderr.index("v80"))
        self.assertIn(f"https://github.com/{REPO}/issues?q=is%3Aissue+is%3Aopen"
                      "+label%3Apreview-hardware-test", p.stderr)

    def test_stable_box_is_pointed_at_stable_hardware_tests(self):
        p = run_selection([release("v80", prerelease=True)], *STABLE)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("label%3Ahardware-test", p.stderr)

    def test_empty_release_list(self):
        p = run_selection([], *STABLE)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("No release is approved", p.stderr)


class Pagination(unittest.TestCase):
    def test_concatenated_pages_are_merged(self):
        page1 = [release(f"v{n}", prerelease=True) for n in range(200, 100, -1)]
        page2 = [release("v24")]
        text = json.dumps(page1) + "\n" + json.dumps(page2) + "\n"
        p = run_selection_raw(text, *STABLE)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, "v24")

    def test_api_error_object_on_any_page_is_reported(self):
        text = json.dumps([]) + "\n" + json.dumps(
            {"message": "API rate limit exceeded for 1.2.3.4"}) + "\n"
        p = run_selection_raw(text, *STABLE)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("rate limit", p.stderr)

    def test_empty_input_is_a_parse_error(self):
        p = run_selection_raw("", *STABLE)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("Failed to parse", p.stderr)

    def test_fetch_loop_reads_every_page(self):
        # The shell loop asks for the next page only after a full one, and
        # the selection sees the releases of every page.
        with tempfile.TemporaryDirectory() as d:
            pages = [[release(f"v{n}", prerelease=True) for n in range(200, 100, -1)],
                     [release("v24")]]
            for i, page in enumerate(pages, 1):
                Path(d, f"page{i}.json").write_text(json.dumps(page))
            stub = f"""
curl() {{
    local url="${{*: -1}}" n
    n="${{url##*page=}}"
    echo "$n" >> "{d}/calls"
    cat "{d}/page$n.json" 2>/dev/null || echo '[]'
}}
midclt() {{ echo '{{"version": "25.10.7"}}'; }}
approved_release_tag
"""
            p = run_block(stub)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout.strip(), "v24")
            self.assertEqual(Path(d, "calls").read_text().split(), ["1", "2"])
            self.assertIn("TrueNAS 25.10.7 (train 25.10): newest approved release is v24",
                          p.stderr)

    def test_api_failure_is_an_error_not_a_fallback(self):
        p = run_block("""
curl() { return 7; }
midclt() { echo '{"version": "26.0.0-BETA.3"}'; }
approved_release_tag
""")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, "")
        self.assertIn("Failed to query GitHub releases", p.stderr)


class TrainKey(unittest.TestCase):
    def test_before_26_the_train_is_major_minor(self):
        self.assertEqual(train_key("25.10.7"), "25.10")
        self.assertEqual(train_key("25.10.4"), "25.10")
        self.assertEqual(train_key("25.04.2.6"), "25.04")
        self.assertEqual(train_key("25.10-RC.1"), "25.10")

    def test_from_26_the_train_is_the_major(self):
        self.assertEqual(train_key("26.0.0-BETA.3"), "26")
        self.assertEqual(train_key("26.1.0"), "26")
        self.assertEqual(train_key("26.1.2"), "26")
        self.assertEqual(train_key("27.0.0-RC.1"), "27")

    def test_garbage_has_no_train(self):
        for v in ("", "abc", "25", "25.", "x25.10"):
            self.assertIsNone(train_key(v), v)


class TrackedTrains(unittest.TestCase):
    # release.yml writes <!-- train: KEY --> from tracked-versions.json and
    # promote.yml turns it into the verified-train marker the selection
    # matches against truenas_train_key's output: a key that function can
    # never produce would approve releases for no box at all.
    def test_every_tracked_key_is_a_real_train_key(self):
        for t in json.loads(TRACKED.read_text())["trains"]:
            self.assertEqual(train_key(t["key"] + ".0"), t["key"], t)

    def test_smoke_build_target_is_a_tracked_train(self):
        tracked = json.loads(TRACKED.read_text())
        keys = [t["key"] for t in tracked["trains"]]
        self.assertIn(train_key(tracked["truenas"]["version"]), keys)


class SnippetBashSafety(unittest.TestCase):
    def test_snippet_survives_double_quote_expansion(self):
        # The snippet lives inside a double-quoted bash string; bash rewrites
        # $..., backticks, and backslash-before-special before Python ever
        # runs. The extraction tests run the raw text, so any such character
        # would make production execute different code than the tests.
        snip = selection_snippet()
        self.assertNotIn("$", snip)
        self.assertNotIn('"', snip)
        self.assertNotIn(chr(96), snip)  # backtick
        for i, ch in enumerate(snip):
            if ch == "\\":
                self.assertNotIn(snip[i + 1], "$\"\\\n" + chr(96),
                                 f"bash-active backslash escape at offset {i}")


if __name__ == "__main__":
    unittest.main()
