#!/usr/bin/env bash
#
# Scan a built image with osv-scanner (run from its official container image)
# and write reports under reports/<distro-key>/.
#
# Usage:
#   scripts/scan.sh <distro-key>      # e.g. debian-12, ubuntu-24.04
#   scripts/scan.sh all               # scan every distro in the matrix
#
# Environment:
#   CONTAINER_ENGINE   container CLI to use (default: podman)
#   OSV_IMAGE          osv-scanner image (default: ghcr.io/google/osv-scanner:latest)
#   KEEP_TAR=1         keep the exported image tarball (default: delete it)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/distros.sh
source "$SCRIPT_DIR/distros.sh"

ENGINE="${CONTAINER_ENGINE:-podman}"
OSV_IMAGE="${OSV_IMAGE:-ghcr.io/google/osv-scanner:latest}"

scan_one() {
	local distro="$1"
	local image outdir tar rc

	if ! is_known_distro "$distro"; then
		echo "error: unknown distro '$distro' (try: scripts/build.sh list)" >&2
		return 1
	fi

	image="$(distro_image "$distro")"
	outdir="$ROOT_DIR/reports/$distro"
	tar="$outdir/image.tar"

	if ! "$ENGINE" image exists "$image"; then
		echo "error: image $image not found — run scripts/build.sh $distro first" >&2
		return 1
	fi

	mkdir -p "$outdir"

	echo "==> Exporting $image to a tarball for scanning"
	# podman save --format docker-archive refuses to write to an existing file,
	# so clear any tarball left over from a previous run first.
	rm -f "$tar"
	"$ENGINE" save --format docker-archive -o "$tar" "$image"

	echo "==> Scanning $distro with osv-scanner ($OSV_IMAGE)"
	# One report file per format. json is the machine-readable canonical
	# artifact; markdown and html are for reading/sharing. osv-scanner writes a
	# single format per run, but each run is quick (the tarball export above is
	# the slow part), so we just invoke it once per format.
	local fmt ext
	for fmt in json markdown html; do
		case "$fmt" in
		markdown) ext=md ;;
		*) ext="$fmt" ;;
		esac
		echo "  -> report.$ext"
		# osv-scanner exits 1 when it finds vulnerabilities (a normal outcome),
		# so only treat exit codes greater than 1 as real failures.
		rc=0
		osv_run "$outdir" scan image --archive /work/image.tar \
			--format "$fmt" --output-file "/work/report.$ext" || rc=$?
		if [ "$rc" -gt 1 ]; then
			echo "error: osv-scanner failed generating $fmt (exit $rc)" >&2
			return "$rc"
		fi
	done

	if [ "${KEEP_TAR:-0}" != "1" ]; then
		rm -f "$tar"
	fi

	echo "==> Reports written to reports/$distro/ (report.json, report.md, report.html)"
}

# osv_run <report-dir> <osv-scanner args...>
# Runs osv-scanner in a container with <report-dir> mounted at /work.
osv_run() {
	local mount="$1"
	shift
	"$ENGINE" run --rm -v "$mount":/work:z "$OSV_IMAGE" "$@"
}

main() {
	local target="${1:-}"

	case "$target" in
	"" | -h | --help)
		sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	all)
		local d
		echo "==> Pre-pulling $OSV_IMAGE"
		"$ENGINE" pull "$OSV_IMAGE"
		for d in "${DISTROS[@]}"; do
			scan_one "$d"
		done
		;;
	*)
		scan_one "$target"
		;;
	esac
}

main "$@"
