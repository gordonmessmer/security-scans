#!/usr/bin/env bash
# Helpers shared by the in-container provisioning scripts.
# This file is meant to be sourced, not executed.

log() {
	printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"
}

warn() {
	printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2
}

# apt_install_available PKG...
#
# Installs every package that actually exists in the configured repos and
# quietly skips the rest, so a package that is missing on one distro never
# aborts the build. If a batch install fails (e.g. an unsatisfiable
# dependency), it retries the survivors one at a time so a single bad package
# can't take the others down with it.
apt_install_available() {
	local pkg
	local available=()

	for pkg in "$@"; do
		if apt-cache show "$pkg" >/dev/null 2>&1; then
			available+=("$pkg")
		else
			warn "not in repo, skipping: $pkg"
		fi
	done

	if [ ${#available[@]} -eq 0 ]; then
		warn "nothing available to install from this set"
		return 0
	fi

	log "Installing: ${available[*]}"
	if apt-get install -y "${available[@]}"; then
		return 0
	fi

	warn "batch install failed; retrying each package individually"
	for pkg in "${available[@]}"; do
		apt-get install -y "$pkg" || warn "FAILED to install: $pkg"
	done
}

# read_list FILE
#
# Prints the packages from a list file, dropping comments and blank lines.
read_list() {
	sed -e 's/#.*//' -e 's/[[:space:]]\+$//' "$1" | grep -v '^[[:space:]]*$'
}
