#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Initializing submodules..."
git submodule update --init --recursive

echo "==> Checking GhosttyKit.xcframework..."
if [ -d "GhosttyKit.xcframework" ]; then
    echo "==> GhosttyKit.xcframework already exists, skipping download"
else
    GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
    TAG="xcframework-$GHOSTTY_SHA"
    URL="https://github.com/manaflow-ai/ghostty/releases/download/$TAG/GhosttyKit.xcframework.tar.gz"

    echo "==> Downloading prebuilt GhosttyKit (SHA: $GHOSTTY_SHA)..."
    curl -fSL "$URL" -o /tmp/GhosttyKit.xcframework.tar.gz
    echo "==> Extracting..."
    tar xzf /tmp/GhosttyKit.xcframework.tar.gz
    rm /tmp/GhosttyKit.xcframework.tar.gz
    echo "==> GhosttyKit.xcframework downloaded"
fi

echo "==> Setup complete!"
echo ""
echo "Build and run:"
echo "  ./scripts/build-app.sh"
echo "  open Belve.app"
