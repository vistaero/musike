#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/musike-batch-check.XXXXXX")
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc -module-cache-path "$TASK_TMP/modules" "$SCRIPT_DIR/../App/App/BatchSearchModel.swift" "$SCRIPT_DIR/../App/App/SearchUtilities.swift" "$SCRIPT_DIR/BatchSearchChecks.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
