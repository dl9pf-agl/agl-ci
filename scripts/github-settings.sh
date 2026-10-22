#!/usr/bin/env bash
# Apply the repository settings that the audit story depends on. Idempotent; needs `gh` with admin rights.
# Usage: github-settings.sh [OWNER/REPO]            apply defaults (0 required approvals: solo maintainer)
#        APPROVALS=1 BYPASS=admin github-settings.sh  require N approvals; BYPASS=admin lets repo admins bypass
# Settings that live in the web UI only are listed in docs/manual/12-repo-hardening.md.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
repo="${1:-$(. policy/project.env; echo "$PROJECT_REPO")}"
approvals="${APPROVALS:-0}"; bypass="${BYPASS:-none}"

body="$(python3 -I - policy/github/ruleset-main.json "$approvals" "$bypass" <<'PY'
import json, sys
f, n, bypass = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = json.load(open(f))
for r in d["rules"]:
    if r["type"] == "pull_request":
        r["parameters"]["required_approving_review_count"] = n
if bypass == "admin":   # RepositoryRole 5 = admin
    d["bypass_actors"] = [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]
print(json.dumps(d))
PY
)"
id="$(gh api "repos/$repo/rulesets" --jq '.[]|select(.name=="main" or .name=="default-protection-delete-and-force")|.id' | head -1)"
if [ -n "$id" ]; then gh api -X PUT "repos/$repo/rulesets/$id" --input - <<<"$body" >/dev/null; else gh api -X POST "repos/$repo/rulesets" --input - <<<"$body" >/dev/null; fi
echo "ruleset main: PR required, check 'lint' required, approvals=$approvals, bypass=$bypass"

gh api -X PATCH "repos/$repo" --input - >/dev/null <<'JSON'
{"delete_branch_on_merge": true, "allow_squash_merge": true, "allow_merge_commit": true, "allow_rebase_merge": false,
 "security_and_analysis": {"secret_scanning": {"status": "enabled"}, "secret_scanning_push_protection": {"status": "enabled"}}}
JSON
echo "secret scanning + push protection enabled"
gh api -X PUT "repos/$repo/private-vulnerability-reporting" >/dev/null && echo "private vulnerability reporting enabled"
gh api -X PUT "repos/$repo/actions/permissions" -F enabled=true -f allowed_actions=all -F sha_pinning_required=true >/dev/null && echo "full-SHA pinning required"
gh api -X PUT "repos/$repo/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors >/dev/null && echo "fork PR workflows: approval for all external contributors"
gh api -X PUT "repos/$repo/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false >/dev/null && echo "default GITHUB_TOKEN: read-only, Actions cannot approve PRs"
