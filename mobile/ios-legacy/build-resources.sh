#!/bin/sh
set -eu

# Finder-launched Xcode does not inherit interactive shell startup files.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
if [ -f "$SRCROOT/.xcode.env.local" ]; then
    . "$SRCROOT/.xcode.env.local"
fi

if ! node --version >/dev/null; then
    echo "error: A working Node.js installation is required. Set PATH in mobile/ios-legacy/.xcode.env.local."
    exit 1
fi
if ! command -v pnpm >/dev/null; then
    echo "error: pnpm is required. Set PATH in mobile/ios-legacy/.xcode.env.local."
    exit 1
fi
if [ ! -d "$SRCROOT/../../web/node_modules/postcss" ]; then
    echo "error: Install the current workspace dependencies with pnpm install at the repository root."
    exit 1
fi

exec node "$SRCROOT/../scripts/build-legacy-ipa.mjs" --xcode-resources \
    "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
