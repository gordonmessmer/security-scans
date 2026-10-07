#!/usr/bin/env bash
#
# Summarize the vulnerability counts ("CVE classes" by severity) from the
# reports already written under reports/<distro-key>/.
#
# It reads whichever report files are present and prints a severity breakdown:
#   - Trivy (trivy.json): findings by severity.
#   - osv-scanner (report.json): findings by severity and unique CVE count.
# The two scanners store severity differently, so each is summarized on its own
# terms (see below); the numbers are not expected to match between scanners.
#
# Usage:
#   scripts/summarize.sh [--csv] <distro-key>   # e.g. debian-12, ubuntu-24.04
#   scripts/summarize.sh [--csv] all            # every distro in the matrix
#
# With --csv the output is one row per (distro, scanner) with a header line,
# suitable for a spreadsheet: distro,scanner,critical,high,medium,low,unknown,unique_cves
# (unique_cves is only reported by osv-scanner; it is blank for Trivy).
#
# Requirements: jq (the reports are JSON).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/distros.sh
source "$SCRIPT_DIR/distros.sh"

# Trivy tags every vulnerability with a severity label already, so we just tally
# the labels. .Severity may be absent, hence the ?. The two jq programs differ
# only in framing: the text one prints "  LABEL: N" lines, the CSV one emits the
# five counts comma-joined.
TRIVY_TALLY='reduce (.Results[]?.Vulnerabilities[]?.Severity) as $s ({}; .[$s] += 1)'
# osv-scanner does not attach a severity label; it records a numeric CVSS score
# per finding group in .max_severity (empty when it has none). We bucket that
# score into the usual CVSS v3 severity classes so the output is comparable to
# Trivy's. A finding "group" is one advisory (with its aliases) per package.
OSV_TALLY='
	reduce (.results[].packages[].groups[].max_severity) as $s ({};
		( if   $s == "" then "UNKNOWN"
		  elif ($s|tonumber) >= 9.0 then "CRITICAL"
		  elif ($s|tonumber) >= 7.0 then "HIGH"
		  elif ($s|tonumber) >= 4.0 then "MEDIUM"
		  elif ($s|tonumber) >  0.0 then "LOW"
		  else "UNKNOWN" end ) as $b
		| .[$b] += 1)
'
OSV_UNIQUE_CVES='
	[.results[].packages[].groups[].aliases[] | select(startswith("CVE-"))]
	| unique | length
'
# Render a tally object as "  LABEL: N" lines (text mode) or as comma-joined
# counts (CSV mode), in a fixed class order.
TO_LINES='. as $c | (["CRITICAL","HIGH","MEDIUM","LOW","UNKNOWN"][] | "  \(.): \($c[.] // 0)")'
TO_CSV='. as $c | [ ("CRITICAL","HIGH","MEDIUM","LOW","UNKNOWN") | ($c[.] // 0) ] | @csv'

summarize_text() {
	local distro="$1" trivy="$2" osv="$3"

	echo "== $distro =="
	if [ -f "$trivy" ]; then
		echo "Trivy findings by severity:"
		jq -r "$TRIVY_TALLY | $TO_LINES" "$trivy"
	fi
	if [ -f "$osv" ]; then
		echo "osv-scanner findings by severity (bucketed from CVSS score):"
		jq -r "$OSV_TALLY | $TO_LINES" "$osv"
		echo "osv-scanner unique CVE ids: $(jq -r "$OSV_UNIQUE_CVES" "$osv")"
	fi
	if [ ! -f "$trivy" ] && [ ! -f "$osv" ]; then
		echo "  (no reports found — run scripts/scan.sh and/or scripts/trivy-scan.sh $distro)"
	fi
	echo
}

summarize_csv() {
	local distro="$1" trivy="$2" osv="$3"

	if [ -f "$trivy" ]; then
		printf '%s,Trivy,%s,\n' "$distro" "$(jq -r "$TRIVY_TALLY | $TO_CSV" "$trivy")"
	fi
	if [ -f "$osv" ]; then
		printf '%s,osv-scanner,%s,%s\n' "$distro" \
			"$(jq -r "$OSV_TALLY | $TO_CSV" "$osv")" \
			"$(jq -r "$OSV_UNIQUE_CVES" "$osv")"
	fi
}

main() {
	local format=text

	if [ "${1:-}" = "--csv" ]; then
		format=csv
		shift
	fi

	local target="${1:-}"
	case "$target" in
	"" | -h | --help)
		sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	esac

	if ! command -v jq >/dev/null 2>&1; then
		echo "error: jq is required but not found on PATH" >&2
		exit 1
	fi

	local targets=()
	if [ "$target" = all ]; then
		targets=("${DISTROS[@]}")
	elif is_known_distro "$target"; then
		targets=("$target")
	else
		echo "error: unknown distro '$target' (try: scripts/build.sh list)" >&2
		exit 1
	fi

	[ "$format" = csv ] && echo "distro,scanner,critical,high,medium,low,unknown,unique_cves"

	local d outdir
	for d in "${targets[@]}"; do
		outdir="$ROOT_DIR/reports/$d"
		"summarize_$format" "$d" "$outdir/trivy.json" "$outdir/report.json"
	done
}

main "$@"
