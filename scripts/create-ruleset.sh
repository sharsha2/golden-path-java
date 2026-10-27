#!/usr/bin/env bash
# Create the branch ruleset for main (Week 4, Part C3).
#
# Equivalent to: Settings -> Rules -> Rulesets -> New branch ruleset.
# Doing it as code means it is reviewable and repeatable.
#
# IMPORTANT: run this only AFTER one fully green pipeline run. A required status
# check must have reported at least once, or GitHub will not recognise the name
# and every PR will sit forever waiting for a check that never arrives.
#
# Usage: ./scripts/create-ruleset.sh [owner/repo]
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
echo "Creating ruleset on $REPO"

# required_approving_review_count is 0 on purpose: GitHub does not let you
# approve your own pull request, so on a solo repo any value above 0 would
# block every merge. Raise it the moment a second person contributes.
gh api -X POST "repos/$REPO/rulesets" --input - <<'JSON'
{
  "name": "main protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "test" },
          { "context": "dependency-scan" },
          { "context": "secret-scan" },
          { "context": "workflow-scan" },
          { "context": "image" }
        ]
      }
    }
  ]
}
JSON

echo
echo "Done. Verify with:  gh api repos/$REPO/rulesets --jq '.[].name'"
