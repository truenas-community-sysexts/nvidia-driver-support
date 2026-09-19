"""End-to-end runs of get.sh, and of the installer's release resolution,
against stub `midclt` and `curl` commands on PATH.

The curl stub serves canned GitHub API pages and, for a release download,
writes a fake asset script that prints which asset and release it is and the
arguments it got, so the tests see exactly what get.sh would run."""
import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from urllib.parse import urlparse

from release_fixtures import release

ROOT = Path(__file__).resolve().parents[1]
GET_SH = ROOT / "get.sh"
INSTALL_SH = ROOT / "scripts" / "install-nvidia-driver.sh"


def logged_host(line):
    """Hostname of the URL in a stub-log line ("curl <url>"), or "" for other lines."""
    parts = line.split()
    if len(parts) > 1 and parts[0] == "curl":
        return urlparse(parts[1]).hostname or ""
    return ""


CURL_STUB = textwrap.dedent("""\
    #!/usr/bin/env python3
    import json, os, re, sys
    from urllib.parse import urlparse
    args = sys.argv[1:]
    url = args[-1]
    with open(os.environ["STUB_LOG"], "a") as f:
        f.write("curl " + url + "\\n")
    parsed = urlparse(url)
    host, path = parsed.hostname, parsed.path
    if host == "api.github.com":
        page = int(re.search(r"(?:^|&)page=(\\d+)", parsed.query).group(1))
        pages = json.load(open(os.environ["STUB_PAGES"]))
        print(json.dumps(pages[page - 1] if page <= len(pages) else []))
    elif host == "github.com" and "/releases/download/" in path:
        tag, asset = path.split("/releases/download/")[1].split("/")
        with open(args[args.index("-o") + 1], "w") as f:
            f.write(f'#!/usr/bin/env bash\\necho "RAN {asset} from {tag} with: $*"\\n')
    else:
        sys.exit(22)
    """)

MIDCLT_STUB = textwrap.dedent("""\
    #!/usr/bin/env bash
    echo "midclt $*" >> "$STUB_LOG"
    [ -n "$STUB_VERSION" ] || exit 1
    echo "{\\"version\\": \\"$STUB_VERSION\\"}"
    """)

RELEASES = [release("v81", prerelease=True), release("v80", trains=["26"]),
            release("v79"), release("v78")]


class Stubbed(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        for name, text in (("curl", CURL_STUB), ("midclt", MIDCLT_STUB)):
            path = self.dir / name
            path.write_text(text)
            path.chmod(0o755)
        self.log = self.dir / "log"
        self.log.write_text("")

    def tearDown(self):
        self._tmp.cleanup()

    def run_bash(self, args, version, releases=RELEASES):
        pages = self.dir / "pages.json"
        pages.write_text(json.dumps([releases]))
        env = dict(os.environ, PATH=f"{self.dir}:{os.environ['PATH']}",
                   STUB_LOG=str(self.log), STUB_PAGES=str(pages),
                   STUB_VERSION=version, TMPDIR=str(self.dir))
        return subprocess.run(["bash", *args], capture_output=True, text=True,
                              env=env)

    def calls(self):
        return self.log.read_text().splitlines()


class GetSh(Stubbed):
    def get(self, *args, version="25.10.7", releases=RELEASES):
        return self.run_bash([str(GET_SH), *args], version, releases)

    def test_runs_the_approved_releases_installer_pinned_to_it(self):
        p = self.get()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(),
                         "RAN install-nvidia-driver.sh from v79 with: --release=v79")
        self.assertIn("TrueNAS 25.10.7 (train 25.10): newest approved release is v79",
                      p.stderr)

    def test_each_train_gets_its_own_approved_release(self):
        p = self.get(version="26.0.0-BETA.3")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("from v80 with: --release=v80", p.stdout)

    def test_arguments_pass_through(self):
        p = self.get("--branch=legacy-580", "--dry-run")
        self.assertIn("with: --branch=legacy-580 --dry-run --release=v79", p.stdout)

    def test_uninstall_runs_the_approved_releases_uninstaller_without_release(self):
        p = self.get("--uninstall", "--keep-cache")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(),
                         "RAN uninstall-nvidia-driver.sh from v79 with: --keep-cache")

    def test_pinned_release_skips_selection(self):
        p = self.get("--release=v81", "--check")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(),
                         "RAN install-nvidia-driver.sh from v81 with: --check --release=v81")
        self.assertFalse(any(c.startswith("midclt")
                             or logged_host(c) == "api.github.com"
                             for c in self.calls()), self.calls())

    def test_pinned_uninstall(self):
        p = self.get("--uninstall", "--release=v81")
        self.assertEqual(p.stdout.strip(),
                         "RAN uninstall-nvidia-driver.sh from v81 with:")

    def test_no_approved_release_stops_before_any_download(self):
        p = self.get(version="26.0.0-BETA.3",
                     releases=[release("v81", prerelease=True)])
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("No release is approved for TrueNAS train 26 yet", p.stderr)
        self.assertFalse(any("/releases/download/" in c for c in self.calls()))

    def test_unreadable_truenas_version_is_an_error(self):
        p = self.get(version="")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("could not read the TrueNAS version", p.stderr)
        self.assertFalse(any("/releases/download/" in c for c in self.calls()))

    def test_empty_release_flag_is_refused(self):
        p = self.get("--release=")
        self.assertEqual(p.returncode, 2)

    def test_temp_dir_is_removed(self):
        self.get()
        self.assertEqual(list(self.dir.glob("nvidia-get.*")), [])


class InstallerResolve(Stubbed):
    """install-nvidia-driver.sh run from outside a checkout (raw main, or a
    copy of the script alone) resolves its tooling release by the same rule."""

    def resolve(self, version, release_tag="", script_dir="/nonexistent",
                releases=RELEASES):
        text = INSTALL_SH.read_text()
        block = text[text.index("# BEGIN approved-release"):
                     text.index("# END approved-release")]
        fn = re.search(r"^resolve_release_for_install\(\) \{\n.*?^\}\n", text,
                       re.S | re.M).group(0)
        script = self.dir / "resolve.sh"
        script.write_text(
            f'REPO="truenas-community-sysexts/nvidia-driver-support"\n'
            f'RELEASE_TAG="{release_tag}"\nRESOLVED_TAG=""\nRELEASE_DL_BASE=""\n'
            f'SCRIPT_DIR="{script_dir}"\n{block}\n{fn}\n'
            'resolve_release_for_install\necho "tag=${RESOLVED_TAG} base=${RELEASE_DL_BASE}"\n')
        return self.run_bash([str(script)], version, releases)

    def test_auto_resolve_takes_the_approved_release(self):
        p = self.resolve("26.1.0")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("tag=v80 base=https://github.com/truenas-community-sysexts/"
                      "nvidia-driver-support/releases/download/v80", p.stdout)

    def test_no_approved_release_stops_instead_of_using_main(self):
        p = self.resolve("26.1.0", releases=[release("v81", prerelease=True)])
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("tag=", p.stdout)
        self.assertIn("No release is approved for TrueNAS train 26 yet", p.stderr)

    def test_explicit_release_is_trusted(self):
        p = self.resolve("", release_tag="v81")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("tag=v81 ", p.stdout)
        self.assertFalse(any(c.startswith("midclt") for c in self.calls()))

    def test_full_checkout_uses_its_own_scripts(self):
        p = self.resolve("", script_dir=str(ROOT / "scripts"))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("tag= base=", p.stdout)


if __name__ == "__main__":
    unittest.main()
