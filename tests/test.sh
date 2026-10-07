#!/usr/bin/env bash
#
# Offline sanity checks for the scripts and config in this repo.
# These do NOT build or scan anything (no network, no podman required); they
# validate syntax, the distro matrix, and the app-list parsing.
#
# Usage: tests/test.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0
fail=0

ok() {
	printf '  \033[1;32mok\033[0m   %s\n' "$*"
	pass=$((pass + 1))
}

no() {
	printf '  \033[1;31mFAIL\033[0m %s\n' "$*"
	fail=$((fail + 1))
}

check() {
	# check "<description>" <command...>
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		ok "$desc"
	else
		no "$desc"
	fi
}

echo "== bash syntax =="
while IFS= read -r -d '' f; do
	check "parse $(basename "$f")" bash -n "$f"
done < <(find "$ROOT_DIR/scripts" "$ROOT_DIR/tests" -name '*.sh' -print0)

echo "== shellcheck (if installed) =="
if command -v shellcheck >/dev/null 2>&1; then
	while IFS= read -r -d '' f; do
		check "shellcheck $(basename "$f")" shellcheck -x "$f"
	done < <(find "$ROOT_DIR/scripts" "$ROOT_DIR/tests" -name '*.sh' -print0)
else
	echo "  (shellcheck not installed, skipping)"
fi

echo "== distro matrix =="
# shellcheck source=scripts/distros.sh
source "$ROOT_DIR/scripts/distros.sh"

[ "${#DISTROS[@]}" -eq 7 ] && ok "seven distros defined" || no "expected 7 distros, got ${#DISTROS[@]}"
[ "$(distro_family debian-12)" = "debian" ] && ok "family(debian-12)=debian" || no "family(debian-12)"
[ "$(distro_family ubuntu-24.04)" = "ubuntu" ] && ok "family(ubuntu-24.04)=ubuntu" || no "family(ubuntu-24.04)"
[ "$(distro_family ubuntu-24.04-nouniverse)" = "ubuntu" ] && ok "family(ubuntu-24.04-nouniverse)=ubuntu" || no "family(ubuntu-24.04-nouniverse)"
[ "$(distro_family rhel-9-extras)" = "rhel" ] && ok "family(rhel-9-extras)=rhel" || no "family(rhel-9-extras)"
[ "$(distro_tag debian-13)" = "13" ] && ok "tag(debian-13)=13" || no "tag(debian-13)"
[ "$(distro_tag ubuntu-26.04)" = "26.04" ] && ok "tag(ubuntu-26.04)=26.04" || no "tag(ubuntu-26.04)"
[ "$(distro_build_args debian-12)" = "DIST_TAG=12" ] && ok "build_args(debian-12)=DIST_TAG=12" || no "build_args(debian-12)"
[ "$(distro_build_args ubuntu-24.04-nouniverse)" = "DIST_TAG=24.04 DISABLE_UNIVERSE=1" ] && ok "build_args(ubuntu-24.04-nouniverse)" || no "build_args(ubuntu-24.04-nouniverse)"
[ "$(distro_build_args rhel-9)" = "ENABLE_EXTRAS=0" ] && ok "build_args(rhel-9)=ENABLE_EXTRAS=0" || no "build_args(rhel-9)"
[ "$(distro_build_args rhel-9-extras)" = "ENABLE_EXTRAS=1" ] && ok "build_args(rhel-9-extras)=ENABLE_EXTRAS=1" || no "build_args(rhel-9-extras)"
check "is_known_distro debian-12" is_known_distro debian-12
if is_known_distro nope-1; then no "is_known_distro rejects unknown"; else ok "is_known_distro rejects unknown"; fi

echo "== containerfiles exist =="
check "Containerfile.debian" test -f "$ROOT_DIR/containerfiles/Containerfile.debian"
check "Containerfile.ubuntu" test -f "$ROOT_DIR/containerfiles/Containerfile.ubuntu"
check "Containerfile.rhel" test -f "$ROOT_DIR/containerfiles/Containerfile.rhel"

echo "== apps.list parsing =="
# shellcheck source=scripts/common.sh
source "$ROOT_DIR/scripts/common.sh"
mapfile -t apps < <(read_list "$ROOT_DIR/apps.list")
[ "${#apps[@]}" -gt 0 ] && ok "apps.list yields ${#apps[@]} packages" || no "apps.list parsed empty"
if printf '%s\n' "${apps[@]}" | grep -q '#'; then
	no "apps.list still contains comments after parsing"
else
	ok "apps.list comments stripped"
fi
if printf '%s\n' "${apps[@]}" | grep -q 'chrome'; then
	no "apps.list should not list chrome (handled separately)"
else
	ok "apps.list excludes chrome"
fi

echo "== build.sh dry-run mapping =="
out="$(DRY_RUN=1 "$ROOT_DIR/scripts/build.sh" ubuntu-24.04)"
if grep -q 'DIST_TAG=24.04' <<<"$out" && grep -q 'Containerfile.ubuntu' <<<"$out"; then
	ok "build.sh maps ubuntu-24.04 correctly"
else
	no "build.sh dry-run mapping for ubuntu-24.04"
fi

# The no-universe variant must pass both the tag and the disable flag.
out="$(DRY_RUN=1 "$ROOT_DIR/scripts/build.sh" ubuntu-24.04-nouniverse)"
if grep -q 'DIST_TAG=24.04' <<<"$out" && grep -q 'DISABLE_UNIVERSE=1' <<<"$out" && grep -q 'Containerfile.ubuntu' <<<"$out"; then
	ok "build.sh maps ubuntu-24.04-nouniverse correctly"
else
	no "build.sh dry-run mapping for ubuntu-24.04-nouniverse"
fi

# RHEL dry-run must not require credentials and must wire up the secrets.
out="$(DRY_RUN=1 "$ROOT_DIR/scripts/build.sh" rhel-9-extras)"
if grep -q 'ENABLE_EXTRAS=1' <<<"$out" && grep -q 'Containerfile.rhel' <<<"$out" && grep -q 'id=rhsm_key' <<<"$out"; then
	ok "build.sh maps rhel-9-extras correctly (with secrets)"
else
	no "build.sh dry-run mapping for rhel-9-extras"
fi

echo "== summarize.sh =="
# Help works without any reports present and lists a distro key.
if "$ROOT_DIR/scripts/summarize.sh" --help | grep -q '<distro-key>'; then
	ok "summarize.sh --help prints usage"
else
	no "summarize.sh --help"
fi
# Unknown distro is rejected (also with --csv).
if "$ROOT_DIR/scripts/summarize.sh" nope-1 >/dev/null 2>&1; then
	no "summarize.sh rejects unknown distro"
else
	ok "summarize.sh rejects unknown distro"
fi
# --csv emits the expected header as its first line.
csv_out="$("$ROOT_DIR/scripts/summarize.sh" --csv debian-12)"
if [ "$(printf '%s\n' "$csv_out" | sed -n '1p')" = \
	'distro,scanner,critical,high,medium,low,unknown,unique_cves' ]; then
	ok "summarize.sh --csv prints header row"
else
	no "summarize.sh --csv header"
fi

echo
echo "== summary: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
