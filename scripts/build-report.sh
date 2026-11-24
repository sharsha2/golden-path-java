#!/usr/bin/env bash
# Write a README-style build report to the GitHub Actions job summary.
#
# Usage: scripts/build-report.sh <trivy-json> <sbom-cdx-json> <image-ref>
#
# Reads Trivy's JSON scan and the CycloneDX SBOM, and prints Markdown. In CI the
# caller redirects this into $GITHUB_STEP_SUMMARY, which renders it on the run
# page. Locally, just run it and read stdout.
set -euo pipefail

TRIVY="${1:?trivy json path}"
SBOM="${2:?sbom path}"
IMAGE="${3:-golden-path:ci}"

# ---------- image facts ----------
SIZE=$(docker image inspect "$IMAGE" --format '{{.Size}}' 2>/dev/null || echo 0)
SIZE_H=$(awk -v b="$SIZE" 'BEGIN{printf "%.0f MB", b/1048576}')
USER=$(docker image inspect "$IMAGE" --format '{{.Config.User}}' 2>/dev/null || echo "")
[ -z "$USER" ] && USER='**root** (!)' || USER="\`$USER\`"
BASE=$(awk '/^FROM/{last=$2} END{print last}' Dockerfile 2>/dev/null || echo unknown)

# ---------- vulnerability counts ----------
counts() { # $1=severity
  jq -r --arg s "$1" '[.Results[]?.Vulnerabilities[]? | select(.Severity==$s)] | length' "$TRIVY"
}
CRIT=$(counts CRITICAL); HIGH=$(counts HIGH)
TOTAL=$((CRIT + HIGH))

if [ "$TOTAL" -eq 0 ]; then
  VERDICT="**PASS** — no fixable HIGH or CRITICAL findings"
else
  VERDICT="**FAIL** — $TOTAL fixable finding(s) block this build"
fi

# ---------- write the report ----------
cat <<MD
# Build report

$VERDICT

| | |
|---|---|
| Image | \`$IMAGE\` |
| Size | $SIZE_H |
| Runs as | $USER |
| Base | \`$BASE\` |

## 1. Vulnerability gate (Trivy)

Only **fixable** HIGH/CRITICAL findings fail the build (\`--ignore-unfixed\`), so
every row here is something you can actually act on by upgrading.

| Severity | Count |
|---|---|
| CRITICAL | $CRIT |
| HIGH | $HIGH |

### Where the findings live

This is the OS-vs-application split: \`debian\` rows are the base image, \`jar\`
rows are your own dependencies. They have different owners and different fixes —
an OS finding needs a new base image, an app finding needs a dependency bump.

| Target | Type | Findings |
|---|---|---|
MD
jq -r '.Results[]? | "| `\(.Target)` | \(.Type // "-") | \((.Vulnerabilities // []) | length) |"' "$TRIVY"

if [ "$TOTAL" -gt 0 ]; then
  cat <<'MD'

### What is blocking the build

| Package | CVE | Severity | Installed | Fixed in | Comes from | Image layer |
|---|---|---|---|---|---|---|
MD
  jq -r '
    .Results[]? as $r
    | $r.Vulnerabilities[]?
    | select(.Severity=="HIGH" or .Severity=="CRITICAL")
    | "| `\(.PkgName)` | [\(.VulnerabilityID)](\(.PrimaryURL // "https://nvd.nist.gov")) | \(.Severity) | `\(.InstalledVersion)` | `\(.FixedVersion // "none")` | \(if $r.Type=="jar" then "application" else "base OS" end) | `\((.Layer.Digest // "-")[0:19])` |"
  ' "$TRIVY"
  cat <<'MD'

**There is no source line for these, and that is not a gap in the report.** An
image finding is a *package version installed in a layer*, not a line anyone
wrote: nothing in this repo mentions `zlib1g`. The layer digest above is the
equivalent locator — it tells you which layer introduced the package, and
therefore who owns the fix.

**How to fix:** a `base OS` row means the pinned base image predates the patch —
bump the digest in `Dockerfile`. An `application` row means bump the dependency
in `pom.xml`; the **Dependency report** on the `dependency-scan` job gives the
exact `pom.xml` line for those.
MD
fi

# ---------- SBOM ----------
COMPS=$(jq '[.components[]?] | length' "$SBOM")
DEB=$(jq '[.components[]? | select(.purl? // "" | startswith("pkg:deb"))] | length' "$SBOM")
MVN=$(jq '[.components[]? | select(.purl? // "" | startswith("pkg:maven"))] | length' "$SBOM")
OTHER=$((COMPS - DEB - MVN))
SPEC=$(jq -r '"\(.bomFormat) \(.specVersion)"' "$SBOM")

cat <<MD

## 2. Software inventory (SBOM)

$SPEC, generated from the image that was just scanned — so the inventory and the
verdict above always describe the same bytes.

| Component kind | Count | What it is |
|---|---|---|
| Debian packages (\`pkg:deb\`) | $DEB | the base OS: libc, zlib, ca-certificates, the JRE's native deps |
| Java libraries (\`pkg:maven\`) | $MVN | your application's dependencies, read out of the jar |
| Other | $OTHER | the OS component itself and anything unclassified |
| **Total** | **$COMPS** | |

Download the full SBOM from the **Artifacts** section at the bottom of this run.

<details><summary>Java libraries in the image (click to expand)</summary>

| Library | Version |
|---|---|
MD
jq -r '[.components[]? | select(.purl? // "" | startswith("pkg:maven"))]
       | sort_by(.name)[] | "| `\(.name)` | \(.version // "-") |"' "$SBOM"
echo
echo "</details>"

cat <<'MD'

<details><summary>Why there are so many OS packages (click to expand)</summary>

A distroless image has no shell and no package manager, but it is not empty: the
JRE needs a C library, a TLS trust store, timezone data and fonts. Those are the
`pkg:deb` rows. They are the reason a "distroless" image still gets CVEs — and
why fixing one means pulling a newer base image rather than patching in place.

</details>
MD
