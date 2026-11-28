#!/usr/bin/env bash
# Dwa PR-y na tej samej bazie, zmiany bazy i głowy oraz ponowienia po awarii GitHuba.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
jq -e '.draftPR == true' "$root/renovate.json" > /dev/null || {
  echo 'FAIL: an unprepared Platform dependency PR must start in draft' >&2
  exit 1
}

python3 -B - "$root" <<'PY'
import importlib.util
import sys
from contextlib import redirect_stdout
from copy import deepcopy
from io import StringIO
from pathlib import Path
from unittest.mock import patch

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("readiness", root / "scripts/dependency-pr-readiness.py")
readiness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(readiness)
repo = "example/Platform"
bot = "dependency-app[bot]"
base = "a" * 40

def proposal(number, branch, head):
    return {"number": number, "state": "open", "draft": True, "user": {"login": bot},
            "base": {"ref": "main", "sha": base},
            "head": {"ref": branch, "sha": head, "repo": {"full_name": repo}}, "labels": []}

first = proposal(21, "renovate/frontend", "b" * 40)
second = proposal(22, "renovate/actions", "c" * 40)
foreign = proposal(23, "renovate/fork", "d" * 40)
foreign["head"]["repo"]["full_name"] = "fork/Platform"
human = proposal(24, "renovate/manual", "e" * 40)
human["user"]["login"] = "maintainer"
foreign["draft"] = human["draft"] = False
pulls = [second, human, first, foreign]
runs = {}
mutations = []
before_promotion = None

def record_ci(pr, conclusion, tested_base, step_result="success"):
    number = pr["number"]
    run = {"id": number, "head_sha": pr["head"]["sha"], "head_branch": pr["head"]["ref"],
           "head_repository": {"full_name": repo}, "status": "completed", "conclusion": conclusion}
    step = {"name": f"Check the proposed dependency release (PR {number}, base {tested_base})",
            "conclusion": step_result}
    runs[pr["head"]["sha"]] = (run, step)

def api(path, *, paginate=False):
    prefix = f"repos/{repo}/"
    assert path.startswith(prefix), path
    path = path[len(prefix):]
    if path == "git/ref/heads/main":
        return {"object": {"sha": base}}
    if path.startswith("pulls?"):
        assert paginate and "state=open" in path and "base=main" in path
        return [deepcopy(pulls[:2]), deepcopy(pulls[2:])]
    if path.startswith("actions/workflows/ci.yml/runs?"):
        from urllib.parse import parse_qs, urlsplit
        query = parse_qs(urlsplit(path).query)
        assert query["event"] == ["pull_request"]
        data = runs.get(query["head_sha"][0])
        return {"workflow_runs": [data[0]] if data else []}
    if path.startswith("actions/runs/"):
        assert paginate
        number = int(path.split("/")[2])
        step = next(step for run, step in runs.values() if run["id"] == number)
        return [{"jobs": [{"steps": [step]}]}]
    if path.startswith("pulls/"):
        pr = next(pr for pr in pulls if pr["number"] == int(path.split("/")[1]))
        if before_promotion:
            before_promotion(pr)
        return deepcopy(pr)
    raise AssertionError(path)

def set_draft(repo_arg, number, draft):
    assert repo_arg == repo
    pr = next(pr for pr in pulls if pr["number"] == number)
    assert pr["draft"] != draft
    mutations.append((number, draft))
    pr["draft"] = draft

def expect(*changes):
    mutations.clear()
    with redirect_stdout(StringIO()), patch.object(readiness, "api", api), patch.object(readiness, "set_draft", set_draft):
        readiness.reconcile(repo, bot)
    assert mutations == list(changes), mutations

expect()
record_ci(first, "failure", base)
expect()
record_ci(first, "success", base)
runs[first["head"]["sha"]][0]["status"] = "in_progress"
expect()
record_ci(first, "success", base, "skipped")
expect()
record_ci(first, "success", base)
record_ci(second, "success", base)
expect((21, False))
expect()
second["draft"] = False
expect((22, True))
pulls.remove(first)
base = "f" * 40
second["base"]["sha"] = base
expect()
record_ci(second, "success", base)
before_promotion = lambda pr: pr["head"].update(sha="1" * 40)
expect()
before_promotion = None
runs.clear()
record_ci(second, "success", base)
expect((22, False))
base = "2" * 40
second["base"]["sha"] = base
expect((22, True))
with patch.dict(readiness.os.environ, PR_TOKEN="fixture"), patch.object(readiness.subprocess, "run") as command:
    readiness.set_draft(repo, 22, True)
    assert command.call_args.args[0] == ["gh", "pr", "ready", "22", "--repo", repo, "--undo"]
    assert command.call_args.kwargs["check"] and command.call_args.kwargs["env"]["GH_TOKEN"] == "fixture"
    readiness.set_draft(repo, 22, False)
    assert command.call_args.args[0] == ["gh", "pr", "ready", "22", "--repo", repo]
print("OK: only one prepared dependency PR with successful CI on the current head and base becomes ready")
PY

ruby -ryaml - "$root" <<'RB'
root = ARGV.first
on_key = ->(workflow) { workflow.fetch("on") { workflow.fetch(true) } }
ci = YAML.load_file("#{root}/.github/workflows/ci.yml")
steps = ci.fetch("jobs").fetch("templates").fetch("steps")
gate = steps.find { |step| step["name"] == 'Check the proposed dependency release (PR ${{ github.event.pull_request.number }}, base ${{ github.event.pull_request.base.sha }})' }
abort "FAIL: the CI result must identify the PR and tested base" unless gate && gate.fetch("run").include?('git merge-base --is-ancestor')
workflow = YAML.load_file("#{root}/.github/workflows/dependency-pr-readiness.yml")
events = on_key.call(workflow)
abort "FAIL: dependency readiness must follow CI completion and main updates" unless
  events.fetch("workflow_run").fetch("workflows").include?("CI") &&
  events.fetch("workflow_run").fetch("types").include?("completed") &&
  events.fetch("push").fetch("branches") == ["main"] && events.fetch("pull_request_target").fetch("types") == ["closed"]
reconcile = workflow.fetch("jobs").fetch("reconcile")
abort "FAIL: unrelated CI events must not displace queued readiness checks" if workflow.key?("concurrency")
abort "FAIL: readiness writers must be serialized" unless reconcile.fetch("concurrency") == {"group" => "dependency-pr-readiness", "cancel-in-progress" => false}
steps = reconcile.fetch("steps")
abort "FAIL: readiness must run from trusted main" unless steps.any? { |s| s["uses"].to_s.start_with?("actions/checkout@") && s.dig("with", "ref") == "refs/heads/main" } &&
  steps.any? { |s| s["run"] == "python3 scripts/dependency-pr-readiness.py" }
RB
