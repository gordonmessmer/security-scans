#!/usr/bin/env bash
#
# Convenience wrapper: build every image, then scan every image.
#
# Usage:
#   scripts/run-all.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/build.sh" all
"$SCRIPT_DIR/scan.sh" all
