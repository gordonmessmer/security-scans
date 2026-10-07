#!/usr/bin/env bash
#
# Provisions an authentic RHEL 9 image to resemble a Workstation desktop plus a
# set of applications, ready to be scanned by osv-scanner.
#
# It runs inside the container during `podman build`. It registers the system
# with subscription-manager using an activation key supplied as build secrets
# (/run/secrets/rhsm_org, /run/secrets/rhsm_key), installs from the genuine RHEL
# repos, then unregisters and cleans up in the same layer so no entitlement,
# key, or subscription state is baked into the image.
#
# Environment:
#   ENABLE_EXTRAS   1 to add EPEL + RPM Fusion (default 0 = base repos only)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=scripts/common-rhel.sh
source "$SCRIPT_DIR/common-rhel.sh"

ENABLE_EXTRAS="${ENABLE_EXTRAS:-0}"
ARCH="$(rpm --eval '%{_arch}')"

registered=0
cleanup_subscription() {
	if [ "$registered" = "1" ]; then
		log "Unregistering and cleaning subscription state"
		subscription-manager unregister || true
		subscription-manager clean || true
		# Belt and suspenders: make sure no entitlement/consumer certs remain.
		rm -rf /etc/pki/entitlement/* /etc/pki/consumer/* 2>/dev/null || true
	fi
}
# Always run on exit (success or failure) so a failed build still releases the
# entitlement and never leaves secrets in the layer.
trap cleanup_subscription EXIT

register_subscription() {
	if [ -r /run/secrets/rhsm_org ] && [ -r /run/secrets/rhsm_key ]; then
		log "Registering with subscription-manager (activation key)"
		subscription-manager register \
			--org "$(cat /run/secrets/rhsm_org)" \
			--activationkey "$(cat /run/secrets/rhsm_key)"
		registered=1
	elif subscription-manager identity >/dev/null 2>&1; then
		log "System already entitled; using existing subscription"
	else
		echo "ERROR: no RHSM activation-key secrets provided and system is not entitled." >&2
		echo "       Set RHSM_ORG and RHSM_ACTIVATION_KEY and build via scripts/build.sh." >&2
		exit 1
	fi
}

enable_base_repos() {
	log "Enabling RHEL 9 BaseOS + AppStream"
	# With Simple Content Access these may already be on; enabling is idempotent.
	subscription-manager repos \
		--enable "rhel-9-for-${ARCH}-baseos-rpms" \
		--enable "rhel-9-for-${ARCH}-appstream-rpms" \
		|| warn "could not toggle base repos (SCA may enable them automatically)"
}

enable_extra_repos() {
	log "Enabling CodeReady Builder + EPEL + RPM Fusion"
	# EPEL (and thus RPM Fusion) needs CodeReady Builder for build-time deps.
	subscription-manager repos --enable "codeready-builder-for-rhel-9-${ARCH}-rpms" \
		|| warn "could not enable CodeReady Builder"
	dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
	# RPM Fusion (free + nonfree) provides obs-studio, full ffmpeg, etc.
	dnf install -y "https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-9.noarch.rpm"
	dnf install -y "https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-9.noarch.rpm"
}

install_desktop() {
	log "Installing the RHEL Workstation desktop"
	dnf install -y dnf-plugins-core
	# The UBI base ships slimmed-down variants that conflict with the full
	# packages the desktop group pulls. Swap the known ones up front; on a
	# genuine RHEL base these are no-ops (the minimal package isn't installed).
	dnf -y --allowerasing swap curl-minimal curl || true
	dnf -y --allowerasing swap coreutils-single coreutils || true
	group_install_first "Workstation" "Server with GUI" "GNOME"
}

install_chrome() {
	if [ "$ARCH" != "x86_64" ]; then
		warn "Google Chrome is x86_64-only; skipping on $ARCH"
		return 0
	fi
	log "Adding Google Chrome yum repository"
	cat > /etc/yum.repos.d/google-chrome.repo <<-'REPO'
		[google-chrome]
		name=google-chrome
		baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
		enabled=1
		gpgcheck=1
		gpgkey=https://dl.google.com/linux/linux_signing_key.pub
	REPO
	dnf_install_available google-chrome-stable
}

install_apps() {
	log "Installing requested applications (skipping any not in the repos)"
	local pkgs=()
	mapfile -t pkgs < <(read_list "$SCRIPT_DIR/apps.list")
	dnf_install_available "${pkgs[@]}"
}

record_manifest() {
	log "Recording installed-package manifest"
	rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' | sort \
		> /opt/provision/installed-packages.txt
	echo "Installed $(wc -l < /opt/provision/installed-packages.txt) packages."
}

cleanup() {
	log "Cleaning dnf caches"
	dnf clean all
	rm -rf /var/cache/dnf
}

main() {
	register_subscription
	enable_base_repos
	if [ "$ENABLE_EXTRAS" = "1" ]; then
		enable_extra_repos
	fi
	dnf -y makecache
	# A real desktop is fully patched; bring the base to current before adding to
	# it, so stale base packages don't surface as findings in the scan.
	log "Upgrading base packages to current versions"
	dnf -y --allowerasing upgrade
	install_desktop
	install_chrome
	install_apps
	record_manifest
	cleanup
	# subscription cleanup runs via the EXIT trap.
	log "Provisioning complete for RHEL 9 (extras=$ENABLE_EXTRAS)"
}

main "$@"
