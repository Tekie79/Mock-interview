#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v git >/dev/null || { echo 'Git is required.' >&2; exit 1; }
command -v swift >/dev/null || { echo 'Provision Swift 6.x from an official toolchain before running this script.' >&2; exit 1; }
swift --version
./scripts/test.sh
