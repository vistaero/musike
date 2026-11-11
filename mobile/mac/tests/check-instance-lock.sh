#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/musike-instance-check.XXXXXX")
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc -module-cache-path "$TASK_TMP/modules" "$SCRIPT_DIR/../App/Mac/MacInstanceLock.swift" "$SCRIPT_DIR/InstanceLockChecks.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
