#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v swift >/dev/null || { echo 'Swift toolchain is required.' >&2; exit 1; }
swift build "$@"
