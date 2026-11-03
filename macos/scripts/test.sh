#!/bin/zsh
# Logic tests in MeetyKit, then an app build.
set -euo pipefail
cd "$(dirname "$0")/.."
(cd MeetyKit && swift test --quiet "$@")
scripts/build.sh
