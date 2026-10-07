#!/usr/bin/env bash
#
# Scan a built image with Trivy's vulnerability scanner (run from its official
# container image) and write reports under reports/<distro-key>/.
#
# This is the Trivy counterpart of scan.sh. Trivy uses the distro security
# trackers (Debian/Ubuntu/Red Hat) for OS packages, so it's a useful cross-check
# against the osv-scanner reports.
#
# Usage:
#   scripts/trivy-scan.sh <distro-key>   # e.g. debian-12, ubuntu-24.04
#   scripts/trivy-scan.sh all            # scan every distro in the matrix
#
# Environment:
#   CONTAINER_ENGINE   container CLI to use (default: podman)
#   TRIVY_IMAGE        trivy image (default: ghcr.io/aquasecurity/trivy:latest)
#   KEEP_TAR=1         keep the exported image tarball (default: delete it)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/distros.sh
source "$SCRIPT_DIR/distros.sh"

ENGINE="${CONTAINER_ENGINE:-podman}"
TRIVY_IMAGE="${TRIVY_IMAGE:-ghcr.io/aquasecurity/trivy:latest}"
# Persist Trivy's vulnerability database between runs so it isn't re-downloaded
# for every image.
CACHE_DIR="$ROOT_DIR/reports/.trivy-cache"

scan_one() {
	local distro="$1"
	local image outdir tar

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

	mkdir -p "$outdir" "$CACHE_DIR"

	echo "==> Exporting $image to a tarball for scanning"
	# podman save --format docker-archive won't overwrite an existing file.
	rm -f "$tar"
	"$ENGINE" save --format docker-archive -o "$tar" "$image"

	echo "==> Scanning $distro with Trivy ($TRIVY_IMAGE)"
	# JSON report (machine-readable, the canonical artifact).
	echo "  -> trivy.json"
	trivy_run "$outdir" image --scanners vuln --input /work/image.tar \
		--format json --output /work/trivy.json
	# HTML report, rendered from the template bundled in the Trivy image.
	echo "  -> trivy.html"
	trivy_run "$outdir" image --scanners vuln --input /work/image.tar \
		--format template --template "@/contrib/html.tpl" --output /work/trivy.html

	if [ "${KEEP_TAR:-0}" != "1" ]; then
		rm -f "$tar"
	fi

	echo "==> Reports written to reports/$distro/ (trivy.json, trivy.html)"
}

# trivy_run <report-dir> <trivy args...>
# Runs Trivy in a container with <report-dir> at /work and the shared DB cache.
trivy_run() {
	local mount="$1"
	shift
	"$ENGINE" run --rm \
		-v "$mount":/work:z \
		-v "$CACHE_DIR":/trivycache:z \
		"$TRIVY_IMAGE" --cache-dir /trivycache "$@"
}

main() {
	local target="${1:-}"

	case "$target" in
	"" | -h | --help)
		sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	all)
		local d
		echo "==> Pre-pulling $TRIVY_IMAGE"
		"$ENGINE" pull "$TRIVY_IMAGE"
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
