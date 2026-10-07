#!/usr/bin/env bash
#
# Build one or all desktop images.
#
# Usage:
#   scripts/build.sh <distro-key>     # e.g. debian-12, ubuntu-24.04
#   scripts/build.sh all              # build every distro in the matrix
#   scripts/build.sh list             # print the known distro keys
#
# Environment:
#   CONTAINER_ENGINE   container CLI to use (default: podman)
#   DRY_RUN=1          print the build command(s) instead of running them
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/distros.sh
source "$SCRIPT_DIR/distros.sh"

ENGINE="${CONTAINER_ENGINE:-podman}"

# Temp files holding RHSM secrets, cleaned up on exit.
TMP_SECRETS=()
cleanup_secrets() {
	if [ ${#TMP_SECRETS[@]} -gt 0 ]; then
		rm -f "${TMP_SECRETS[@]}"
	fi
}
trap cleanup_secrets EXIT

# add_rhel_secrets <cmd-array-name>
#
# Appends the `--secret` args carrying the RHSM activation key + org id. The
# secrets are mounted into the build only (never stored in an image layer). In
# DRY_RUN we just show placeholders so no credentials are required to preview.
add_rhel_secrets() {
	local -n _cmd="$1"
	if [ -n "${RHEL_BASE:-}" ]; then
		_cmd+=(--build-arg "RHEL_BASE=$RHEL_BASE")
	fi
	if [ "${DRY_RUN:-0}" = "1" ]; then
		_cmd+=(--secret "id=rhsm_org,src=<RHSM_ORG>" --secret "id=rhsm_key,src=<RHSM_ACTIVATION_KEY>")
		return 0
	fi
	: "${RHSM_ORG:?RHEL builds need RHSM_ORG (your subscription org id)}"
	: "${RHSM_ACTIVATION_KEY:?RHEL builds need RHSM_ACTIVATION_KEY (your activation key)}"
	local org_file key_file
	org_file="$(mktemp)"
	key_file="$(mktemp)"
	chmod 600 "$org_file" "$key_file"
	printf '%s' "$RHSM_ORG" > "$org_file"
	printf '%s' "$RHSM_ACTIVATION_KEY" > "$key_file"
	TMP_SECRETS+=("$org_file" "$key_file")
	_cmd+=(--secret "id=rhsm_org,src=$org_file" --secret "id=rhsm_key,src=$key_file")
}

build_one() {
	local distro="$1"
	local family image containerfile arg

	if ! is_known_distro "$distro"; then
		echo "error: unknown distro '$distro' (try: scripts/build.sh list)" >&2
		return 1
	fi

	family="$(distro_family "$distro")"
	image="$(distro_image "$distro")"
	containerfile="$ROOT_DIR/containerfiles/Containerfile.$family"

	local cmd=("$ENGINE" build -f "$containerfile")
	for arg in $(distro_build_args "$distro"); do
		cmd+=(--build-arg "$arg")
	done
	if [ "$family" = "rhel" ]; then
		add_rhel_secrets cmd
	fi
	cmd+=(-t "$image" "$ROOT_DIR")

	echo "==> Building $image"
	if [ "${DRY_RUN:-0}" = "1" ]; then
		printf '    %q ' "${cmd[@]}"
		printf '\n'
		return 0
	fi
	"${cmd[@]}"
}

main() {
	local target="${1:-}"

	case "$target" in
	"" | -h | --help)
		sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	list)
		printf '%s\n' "${DISTROS[@]}"
		exit 0
		;;
	all)
		local d
		for d in "${DISTROS[@]}"; do
			build_one "$d"
		done
		;;
	*)
		build_one "$target"
		;;
	esac
}

main "$@"
