#!/usr/bin/env bash
# README-style report for the dependency scan, written to the job summary.
#
# Usage: scripts/dep-report.sh <trivy-fs-json>
#
# Unlike an image scan, a filesystem scan knows WHERE a dependency is declared.
# Trivy keeps that in .Results[].Packages[].Locations, separate from the
# vulnerability itself, so this joins the two by package name to print
# "pom.xml:35-39" next to each finding.
set -euo pipefail
TRIVY="${1:?trivy fs json path}"

CRIT=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$TRIVY")
HIGH=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")]     | length' "$TRIVY")
TOTAL=$((CRIT + HIGH))

echo "# Dependency report"
echo
if [ "$TOTAL" -eq 0 ]; then
  echo "**PASS** — no fixable HIGH or CRITICAL findings in declared dependencies."
else
  echo "**FAIL** — $TOTAL fixable finding(s): $CRIT CRITICAL, $HIGH HIGH."
fi
echo

if [ "$TOTAL" -gt 0 ]; then
  cat <<'MD'
Each row points at the exact declaration. **Direct** dependencies carry a line
number in the manifest; **transitive** ones have no line of their own, because
nothing in your file declares them — they arrive through a parent. Fix those by
upgrading the dependency that pulls them in, or by adding a managed version.

| Package | CVE | Severity | Installed | Fixed in | Declared at |
|---|---|---|---|---|---|
MD
  jq -r '
    # index package name -> "file:start-end", from the Packages block.
    # Bind the root first: from_entries replaces "." with the index.
    . as $root
    | [ $root.Results[]? as $r
      | $r.Packages[]?
      | select(.Locations != null)
      | { key: .Name,
          value: ($r.Target + ":" + (.Locations[0].StartLine|tostring)
                  + "-" + (.Locations[0].EndLine|tostring)) } ]
    | from_entries as $loc
    | $root.Results[]?.Vulnerabilities[]?
    | select(.Severity=="HIGH" or .Severity=="CRITICAL")
    | . as $v
    | "| `\($v.PkgName)` | [\($v.VulnerabilityID)](\($v.PrimaryURL // "https://nvd.nist.gov")) | \($v.Severity) | `\($v.InstalledVersion)` | `\($v.FixedVersion // "none")` | " +
      (if $loc[$v.PkgName] then "`" + $loc[$v.PkgName] + "` (direct)" else "_transitive_" end) + " |"
  ' "$TRIVY"
  echo
fi

echo "## What was scanned"
echo
echo "| Manifest | Type | Packages | Findings |"
echo "|---|---|---|---|"
jq -r '.Results[]? | "| `\(.Target)` | \(.Class // "-") | \((.Packages // []) | length) | \((.Vulnerabilities // []) | length) |"' "$TRIVY"
echo
cat <<'MD'
Only **fixable** findings fail this job (`--ignore-unfixed`). Unfixable ones are
tracked in `.trivyignore` with an owner and a review date rather than silenced.
MD
