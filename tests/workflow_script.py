"""Run a workflow step's github-script body under node.

The `script: |` block of the named step is extracted verbatim (dedented from
its YAML indentation) and wrapped in a harness that provides the stub
`github`, `context` and `core` objects actions/github-script injects, so the
tests execute exactly the code the workflow runs. node runs from the repo
root, where the scripts read catalog/ and .github/tracked-versions.json.
"""
import json
import subprocess
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OWNER, REPO = "truenas-community-sysexts", "nvidia-driver-support"


def step_script(workflow, step_name):
    lines = (ROOT / ".github" / "workflows" / workflow).read_text().splitlines()
    step = next(i for i, ln in enumerate(lines)
                if ln.strip() == f"- name: {step_name}")
    start = next(i for i in range(step, len(lines))
                 if lines[i].strip() == "script: |")
    indent = len(lines[start]) - len(lines[start].lstrip())
    block = []
    for ln in lines[start + 1:]:
        if ln.strip() and len(ln) - len(ln.lstrip()) <= indent:
            break
        block.append(ln)
    return textwrap.dedent("\n".join(block))


def run_script(harness, script, state, env=None):
    """harness has one %s for the script. It reads `state` (JSON) on stdin
    and prints the recorded calls as JSON on stdout."""
    p = subprocess.run(["node", "-e", harness % script],
                       input=json.dumps(state), capture_output=True,
                       text=True, cwd=ROOT, env=env)
    if p.returncode != 0:
        raise AssertionError(f"node failed: {p.stderr}")
    return json.loads(p.stdout)
