#!/bin/bash
# Build belve-persist and sync to app bundle.
# Use this instead of `go build` to ensure deploy_bundle sees the new binary.
set -e
cd "$(dirname "$0")/.."

PERSIST_DIR="tools/belve-persist"
BUNDLE_DIR="Belve.app/Contents/Resources/bin"

echo "Building belve-persist..."
(cd "$PERSIST_DIR" && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o belve-persist-linux-amd64 . && \
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o belve-persist-linux-arm64 . && \
    CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o belve-persist-darwin-arm64 . \
)

if [ -d "$BUNDLE_DIR" ]; then
    cp "$PERSIST_DIR/belve-persist-linux-amd64" "$BUNDLE_DIR/"
    cp "$PERSIST_DIR/belve-persist-linux-arm64" "$BUNDLE_DIR/"
    cp "$PERSIST_DIR/belve-persist-darwin-arm64" "$BUNDLE_DIR/"
    chmod +x "$BUNDLE_DIR"/belve-persist-*
    codesign --force --sign - "$BUNDLE_DIR/belve-persist-darwin-arm64" 2>/dev/null || true
    codesign --force --sign - Belve.app 2>/dev/null || true
    echo "Synced to app bundle"
else
    echo "Warning: $BUNDLE_DIR not found. Run ./scripts/build-app.sh first."
fi
