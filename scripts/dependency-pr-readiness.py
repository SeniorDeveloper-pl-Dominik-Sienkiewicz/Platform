"""Keep at most one prepared Platform dependency pull request ready for review."""

import json
import os
import subprocess
from urllib.parse import urlencode


def api(path, *, paginate=False):
    command = ["gh", "api"]
    if paginate:
        command.extend(["--paginate", "--slurp"])
    return json.loads(subprocess.check_output([*command, path]))


def set_draft(repo, number, draft):
    command = ["gh", "pr", "ready", str(number), "--repo", repo]
    if draft:
        command.append("--undo")
    subprocess.run(command, env={**os.environ, "GH_TOKEN": os.environ["PR_TOKEN"]}, check=True)


def passed_release_check(repo, pr, base):
    head = pr["head"]
    query = urlencode({"event": "pull_request", "head_sha": head["sha"], "branch": head["ref"]})
    runs = api(f"repos/{repo}/actions/workflows/ci.yml/runs?{query}")["workflow_runs"]
    latest = max((run for run in runs if run["head_sha"] == head["sha"]
                  and run["head_branch"] == head["ref"]
                  and (run["head_repository"] or {}).get("full_name") == repo),
                 key=lambda run: run["id"], default=None)
    if not latest or latest["status"] != "completed" or latest["conclusion"] != "success":
        return False

    expected = f"Check the proposed dependency release (PR {pr['number']}, base {base})"
    pages = api(f"repos/{repo}/actions/runs/{latest['id']}/jobs?filter=latest&per_page=100", paginate=True)
    return any(step["name"] == expected and step["conclusion"] == "success"
               for page in pages for job in page["jobs"] for step in job.get("steps", []))


def reconcile(repo, bot):
    base = api(f"repos/{repo}/git/ref/heads/main")["object"]["sha"]
    pages = api(f"repos/{repo}/pulls?state=open&base=main&per_page=100", paginate=True)
    candidates = [pr for page in pages for pr in page
                  if pr["user"]["login"] == bot and pr["base"]["ref"] == "main"
                  and (pr["head"]["repo"] or {}).get("full_name") == repo
                  and pr["head"]["ref"].startswith("renovate/")]
    candidates.sort(key=lambda pr: (pr["draft"], pr["number"]))

    selected = next((pr for pr in candidates if pr["base"]["sha"] == base
                     and passed_release_check(repo, pr, base)), None)
    for pr in candidates:
        if pr != selected and not pr["draft"]:
            set_draft(repo, pr["number"], True)

    if not selected:
        print(f"No dependency PR is ready for review against main at {base[:12]}.")
        return
    if selected["draft"]:
        live = api(f"repos/{repo}/pulls/{selected['number']}")
        if (live["state"] == "open" and live["draft"] and live["base"]["ref"] == "main"
                and live["base"]["sha"] == base and live["head"]["sha"] == selected["head"]["sha"]):
            set_draft(repo, selected["number"], False)
        else:
            print(f"PR #{selected['number']} changed during the readiness check.")
            return
    print(f"PR #{selected['number']} is ready for review against main at {base[:12]}.")


if __name__ == "__main__":
    reconcile(os.environ["GITHUB_REPOSITORY"], os.environ["BOT"])
