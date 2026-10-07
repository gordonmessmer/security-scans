# Desktop OS vulnerability scans

Builds container images that resemble a **typical desktop installation** of
Debian, Ubuntu, and RHEL, plus a set of desktop applications, then scans each
image for vulnerabilities with two scanners:

- [osv-scanner](https://google.github.io/osv-scanner/) — `scripts/scan.sh`
- [Trivy](https://trivy.dev/) (vuln scanner) — `scripts/trivy-scan.sh`

Both read the distro's package database (`/var/lib/dpkg/status` or the rpm DB)
inside the image, so the reports reflect the OS and application packages actually
installed. They draw on different data, so running both is a useful cross-check —
see [Two scanners](#two-scanners) below.

## Distributions

| Distro key       | Base image                | Desktop                           |
| ---------------- | ------------------------- | --------------------------------- |
| `debian-12`      | `debian:12`               | `task-desktop task-gnome-desktop` |
| `debian-13`      | `debian:13`               | `task-desktop task-gnome-desktop` |
| `ubuntu-24.04`   | `ubuntu:24.04`            | `ubuntu-desktop`                  |
| `ubuntu-24.04-nouniverse` | `ubuntu:24.04`   | `ubuntu-desktop`, **`universe` disabled** |
| `ubuntu-26.04`   | `ubuntu:26.04`            | `ubuntu-desktop`                  |
| `rhel-9`         | UBI 9 (registered)        | `Workstation` (base repos only)   |
| `rhel-9-extras`  | UBI 9 (registered)        | `Workstation` + EPEL + RPM Fusion |

The full desktop metapackages/groups make each image multi-gigabyte; builds
take a while and pull a lot of data.

The **`ubuntu-24.04-nouniverse`** image is the same as `ubuntu-24.04` except the
`universe` component is disabled *before any package is installed*, so only
Canonical-supported `main`/`restricted` packages are available. It's meant to
demonstrate how much thinner the installable app set becomes: `ubuntu-desktop`,
Chrome (from Google's repo), and the `main`/`restricted` apps (gimp, git, nmap,
screen, rsync, tcpdump, wine, ffmpeg, enscript) still install, but the
`universe`-only apps (kicad, prusa-slicer, obs-studio, wireshark, keepassxc,
ncdu, fzf, magic-wormhole, glc, xscreensaver) are skipped.

### RHEL 9 (authentic, needs a subscription)

The two `rhel-9*` images install genuine RHEL 9 content. They start from Red
Hat's freely-pullable **UBI 9** base and register it with `subscription-manager`
at build time so the real RHEL 9 BaseOS/AppStream/CRB repos are used. The two
variants differ only in repos: `rhel-9` uses base RHEL repos only, while
`rhel-9-extras` also enables **EPEL** and **RPM Fusion** to install more apps.

You supply your subscription credentials as environment variables; they are
passed to the build as `--secret` mounts (never written to an image layer), and
the build **unregisters and runs `subscription-manager clean` in the same
layer**, so no key, entitlement, or subscription state ends up in the image.

```sh
export RHSM_ORG=1234567                 # your subscription org id
export RHSM_ACTIVATION_KEY=my-key       # an activation key in that org
scripts/build.sh rhel-9
scripts/build.sh rhel-9-extras
```

To use the full RHEL base image instead of UBI, `podman login registry.redhat.io`
first and set `RHEL_BASE=registry.redhat.io/rhel9/rhel`.

App availability on RHEL 9 is much thinner than on Debian/Ubuntu (as expected):

- **Base repos:** wireshark, gimp, iotop, git, nmap, rsync, tcpdump, enscript.
- **+ EPEL + RPM Fusion:** also obs-studio, keepassxc, ncdu, screen, fzf, wine,
  ffmpeg, xscreensaver (plus Chrome from Google's repo).
- **Not in EL9 repos (skipped):** kicad, prusa-slicer, magic-wormhole, glc.

## Applications

The requested applications are listed in [`apps.list`](apps.list) and installed
if present in the distro's repos (missing ones are skipped, never fatal). As of
this writing all of them are available in all four distros:

kicad, prusa-slicer, obs-studio, wireshark, gimp, iotop, keepassxc, git, ncdu,
nmap, screen, rsync, tcpdump, fzf, magic-wormhole, wine, ffmpeg, glc, enscript,
xscreensaver.

**Google Chrome** is not in the distro repos, so it is installed from Google's
own signed apt repository (`google-chrome-stable`). This is amd64-only; on other
architectures Chrome is skipped and the rest of the build continues.

## Requirements

- [podman](https://podman.io/) (set `CONTAINER_ENGINE=docker` to use Docker instead)
- Network access to pull base images, the Google Chrome repo, and the scanner
  images. Both scanners run from their official container images
  (`ghcr.io/google/osv-scanner:latest`, `ghcr.io/aquasecurity/trivy:latest`), so
  no local install is needed. Trivy also downloads its vulnerability DB on first
  run and caches it under `reports/.trivy-cache/`.

## Usage

```sh
# List the distro keys
scripts/build.sh list

# Build one image, or all of them
scripts/build.sh debian-12
scripts/build.sh all

# Scan one image, or all of them (osv-scanner)
scripts/scan.sh debian-12
scripts/scan.sh all

# Scan with Trivy instead (or as well)
scripts/trivy-scan.sh debian-12
scripts/trivy-scan.sh all

# Build everything then scan everything (with osv-scanner)
scripts/run-all.sh

# Print CVE-class (severity) counts from the reports already written
scripts/summarize.sh debian-12
scripts/summarize.sh all

# ...or as CSV (one row per distro+scanner) for a spreadsheet
scripts/summarize.sh --csv all > summary.csv
```

`summarize.sh` reads whichever report files exist under `reports/<distro-key>/`
and prints a severity breakdown for each scanner. Trivy already labels every
finding with a severity, so its counts are tallied directly. osv-scanner records
a numeric CVSS score instead of a label, so its findings are bucketed into the
usual CVSS v3 classes. The two scanners use different data, so their counts are
not expected to match.

Reports land in `reports/<distro-key>/`:

| File          | Scanner     | Notes                                    |
| ------------- | ----------- | ---------------------------------------- |
| `report.json` | osv-scanner | machine-readable, the canonical artifact |
| `report.md`   | osv-scanner | readable Markdown summary                |
| `report.html` | osv-scanner | self-contained HTML report               |
| `trivy.json`  | Trivy       | machine-readable                         |
| `trivy.html`  | Trivy       | self-contained HTML report               |

osv-scanner exits `1` when it finds vulnerabilities; `scan.sh` treats that as a
normal result (only exit codes greater than `1` are errors). Trivy exits `0`
regardless of findings.

## Two scanners

osv-scanner and Trivy both scan the installed package database but use different
vulnerability data, so their results differ and complement each other:

- **osv-scanner** matches packages against the [OSV](https://osv.dev/) database.
- **Trivy** (with `--scanners vuln`) uses the distro security trackers
  (Debian/Ubuntu/Red Hat) and does source-package version comparison, and by
  default it *also lists vulnerabilities with no fix available yet*.

The difference is easy to see on `samba`: osv-scanner reports the `libldb2`
library (built from the samba source, but versioned `2:2.6.2+samba…`) as a
vulnerable `samba` needing an upgrade to `4.17.10`, even though the installed
`deb12u4` already contains those fixes — a false positive caused by comparing
`ldb`'s version scheme against samba advisories. Trivy reports `libldb2` under
its own name with no bogus "fixed" version. Running both makes such
scanner-specific artifacts obvious.

Trivy lists unfixed vulnerabilities by default; pass `--ignore-unfixed` (edit
`trivy-scan.sh`) if you only want actionable, fix-available findings.

### Useful environment variables

| Variable           | Default                              | Effect                                  |
| ------------------ | ------------------------------------ | --------------------------------------- |
| `CONTAINER_ENGINE`     | `podman`                            | Container CLI used to build/scan        |
| `OSV_IMAGE`            | `ghcr.io/google/osv-scanner:latest` | osv-scanner image to run                |
| `TRIVY_IMAGE`          | `ghcr.io/aquasecurity/trivy:latest` | Trivy image to run                      |
| `KEEP_TAR=1`           | (unset)                             | Keep the exported `image.tar` after scan |
| `DRY_RUN=1`            | (unset)                             | `build.sh` prints commands instead of running |
| `RHSM_ORG`             | (unset)                             | RHEL builds: subscription org id (required) |
| `RHSM_ACTIVATION_KEY`  | (unset)                             | RHEL builds: activation key (required)  |
| `RHEL_BASE`            | `…/ubi9/ubi`                        | RHEL builds: override the base image     |

## Layout

```
apps.list                      # applications to install if available
containerfiles/
  Containerfile.debian         # parameterized by DIST_TAG (12, 13, ...)
  Containerfile.ubuntu         # parameterized by DIST_TAG (24.04, 26.04, ...)
  Containerfile.rhel           # UBI 9 + subscription-manager, ENABLE_EXTRAS arg
scripts/
  common.sh                    # apt helpers (install-if-available, list parsing)
  common-rhel.sh               # dnf helpers (install-if-available, group install)
  distros.sh                   # the distro matrix, shared by build/scan
  provision.sh                 # Debian/Ubuntu: desktop + chrome + apps
  provision-rhel.sh            # RHEL: register + repos + desktop + chrome + apps
  build.sh                     # build one/all images
  scan.sh                      # scan one/all images with osv-scanner
  trivy-scan.sh                # scan one/all images with Trivy (vuln scanner)
  summarize.sh                 # print severity counts from the written reports
  run-all.sh                   # build all, then scan all
tests/
  test.sh                      # offline sanity checks (no build/scan needed)
```

## Tests

`tests/test.sh` runs offline checks — bash syntax, the distro matrix, app-list
parsing, and `build.sh`'s command mapping — without building or scanning
anything. It also runs `shellcheck` on the scripts if it is installed.

```sh
tests/test.sh
```
