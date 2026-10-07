#!/usr/bin/env bash
# Shared distro matrix, sourced by build.sh, scan.sh and the tests.
# This file is meant to be sourced, not executed.

# The set of images this project knows how to build and scan.
# For debian/ubuntu the key is "<family>-<tag>"; the rhel keys select the base
# RHEL 9 image with or without the extra (EPEL + RPM Fusion) repos.
DISTROS=(
	debian-12
	debian-13
	ubuntu-24.04
	ubuntu-24.04-nouniverse
	ubuntu-26.04
	rhel-9
	rhel-9-extras
)

# distro_family <distro-key>  ->  debian | ubuntu | rhel
distro_family() {
	case "$1" in
	debian-*) echo debian ;;
	ubuntu-*) echo ubuntu ;;
	rhel-*) echo rhel ;;
	*)
		echo "unknown distro: $1" >&2
		return 1
		;;
	esac
}

# distro_tag <distro-key>  ->  the base-image tag (e.g. 12, 24.04)
distro_tag() {
	echo "${1#*-}"
}

# distro_build_args <distro-key>  ->  the "KEY=VALUE" build args for the image
distro_build_args() {
	case "$1" in
	ubuntu-24.04-nouniverse) echo "DIST_TAG=24.04 DISABLE_UNIVERSE=1" ;;
	debian-* | ubuntu-*) echo "DIST_TAG=$(distro_tag "$1")" ;;
	rhel-9) echo "ENABLE_EXTRAS=0" ;;
	rhel-9-extras) echo "ENABLE_EXTRAS=1" ;;
	*)
		echo "unknown distro: $1" >&2
		return 1
		;;
	esac
}

# distro_image <distro-key>  ->  the local image name we build/scan
distro_image() {
	echo "localhost/security-scan-$1:latest"
}

# is_known_distro <distro-key>  ->  exit 0 if in DISTROS
is_known_distro() {
	local d
	for d in "${DISTROS[@]}"; do
		[ "$d" = "$1" ] && return 0
	done
	return 1
}
