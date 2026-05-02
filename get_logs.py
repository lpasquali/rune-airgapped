import subprocess
import json

res = subprocess.run(["gh", "run", "list", "--repo", "lpasquali/rune-airgapped", "--branch", "chore/enable-dependabot", "--limit", "1", "--json", "databaseId"], capture_output=True, text=True)
run_id = json.loads(res.stdout)[0]["databaseId"]

res_jobs = subprocess.run(["gh", "api", f"repos/lpasquali/rune-airgapped/actions/runs/{run_id}/jobs"], capture_output=True, text=True)
jobs = json.loads(res_jobs.stdout)["jobs"]
for job in jobs:
    if job["conclusion"] == "failure":
        if "Merge Gate" in job["name"]: continue
        print(f"--- Failed job: {job['name']} ---")
        log_res = subprocess.run(["gh", "api", f"repos/lpasquali/rune-airgapped/actions/jobs/{job['id']}/logs"], capture_output=True, text=True)
        for line in log_res.stdout.split("\n")[-40:]:
            print(line)
