#!/usr/bin/env bash
#
# Provisions a Debian/Ubuntu image to resemble a typical desktop installation
# plus a set of applications, ready to be scanned by osv-scanner.
#
# Usage (runs inside the container during `podman build`):
#   provision.sh <debian|ubuntu>
#
set -euo pipefail

FAMILY="${1:?usage: provision.sh <debian|ubuntu>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

export DEBIAN_FRONTEND=noninteractive

# Remove the 'universe' component from the apt sources so only main/restricted
# (Canonical-supported) packages are installable. Must run before apt-get update
# so the universe indexes are never fetched. Ubuntu 24.04+ uses the deb822
# ubuntu.sources file; older layouts use sources.list.
disable_universe() {
	log "Disabling the 'universe' repository component"
	local changed=0
	if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
		sed -i -E '/^Components:/ { s/\buniverse\b//g; s/[[:space:]]+/ /g; s/[[:space:]]+$// }' \
			/etc/apt/sources.list.d/ubuntu.sources
		changed=1
	fi
	if [ -s /etc/apt/sources.list ]; then
		sed -i -E '/^deb(-src)? / s/\buniverse\b//g' /etc/apt/sources.list
		changed=1
	fi
	if [ "$changed" = "0" ]; then
		warn "no apt sources found to edit for universe"
	fi
	echo "Effective components:"
	grep -hE '^Components:' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
}

install_base() {
	if [ "${DISABLE_UNIVERSE:-0}" = "1" ]; then
		disable_universe
	fi

	log "Refreshing package lists"
	apt-get update

	# A real desktop install is fully patched. The base image freezes packages
	# at build time, so bring everything to the current point release; otherwise
	# stale base packages show up as (real or spurious) findings in the scan.
	log "Upgrading base packages to current versions"
	apt-get -y full-upgrade

	# Wireshark asks (via debconf) whether non-root users may capture packets.
	# Pre-answer it so the desktop metapackage install stays non-interactive.
	echo 'wireshark-common wireshark-common/install-setuid boolean false' \
		| debconf-set-selections

	log "Installing base tooling for repo/key management"
	apt-get install -y ca-certificates curl gnupg apt-utils
}

install_desktop() {
	log "Installing full $FAMILY desktop environment"
	case "$FAMILY" in
	debian)
		# task-desktop pulls Xorg and the desktop base; task-gnome-desktop
		# pulls the same GNOME set the Debian installer's "GNOME" task does.
		apt-get install -y task-desktop task-gnome-desktop
		;;
	ubuntu)
		apt-get install -y ubuntu-desktop
		;;
	*)
		echo "Unknown family: $FAMILY" >&2
		exit 1
		;;
	esac
}

install_chrome() {
	local arch
	arch="$(dpkg --print-architecture)"
	if [ "$arch" != "amd64" ]; then
		warn "Google Chrome is amd64-only; skipping on $arch"
		return 0
	fi

	log "Adding Google Chrome apt repository"
	install -d -m 0755 /etc/apt/keyrings
	curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
		| gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
	echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
		> /etc/apt/sources.list.d/google-chrome.list
	apt-get update

	apt_install_available google-chrome-stable
}

install_apps() {
	log "Installing requested applications (skipping any not in the repos)"
	local pkgs=()
	mapfile -t pkgs < <(read_list "$SCRIPT_DIR/apps.list")
	apt_install_available "${pkgs[@]}"
}

record_manifest() {
	log "Recording installed-package manifest"
	dpkg-query -W -f='${Package}\t${Version}\n' > /opt/provision/installed-packages.txt
	echo "Installed $(wc -l < /opt/provision/installed-packages.txt) packages."
}

cleanup() {
	log "Cleaning apt caches"
	apt-get clean
	rm -rf /var/lib/apt/lists/*
}

main() {
	install_base
	install_desktop
	install_chrome
	install_apps
	record_manifest
	cleanup
	log "Provisioning complete for $FAMILY"
}

main "$@"
