#!/usr/bin/env bash
# dnf/rpm helpers for the RHEL provisioning script.
# Sourced (alongside common.sh) by provision-rhel.sh, not executed.

# dnf_install_available PKG...
#
# RHEL counterpart of apt_install_available: installs every package that
# actually exists in the enabled repos and skips the rest, so a package
# missing on RHEL never aborts the build. strict=0 keeps dnf from failing the
# whole transaction over an unavailable/broken package; a per-package retry is
# the final fallback.
dnf_install_available() {
	local pkg
	local available=()

	for pkg in "$@"; do
		if dnf -q info "$pkg" >/dev/null 2>&1; then
			available+=("$pkg")
		else
			warn "not in repos, skipping: $pkg"
		fi
	done

	if [ ${#available[@]} -eq 0 ]; then
		warn "nothing available to install from this set"
		return 0
	fi

	log "Installing: ${available[*]}"
	# --allowerasing lets dnf swap conflicting packages (e.g. the UBI base's
	# curl-minimal for full curl) instead of aborting the transaction.
	if dnf install -y --setopt=strict=0 --skip-broken --allowerasing "${available[@]}"; then
		return 0
	fi

	warn "batch install failed; retrying each package individually"
	for pkg in "${available[@]}"; do
		dnf install -y --allowerasing "$pkg" || warn "FAILED to install: $pkg"
	done
}

# group_install_first NAME...
#
# Tries each group/environment name in turn and stops at the first that
# installs. Desktop group/environment ids vary a little between RHEL releases,
# so we try the most desktop-complete option first.
group_install_first() {
	local g
	for g in "$@"; do
		# --allowerasing so the desktop group can replace the UBI base's
		# slimmed-down packages (curl-minimal, coreutils-single, ...).
		if dnf -y --allowerasing group install "$g"; then
			return 0
		fi
		warn "group/environment not installable: $g"
	done
	warn "no desktop group could be installed"
	return 1
}
