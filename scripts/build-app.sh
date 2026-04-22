#!/bin/bash
set -e
cd "$(dirname "$0")/.."

swift build

# Create .app bundle
mkdir -p Belve.app/Contents/MacOS
cp .build/arm64-apple-macosx/debug/Belve Belve.app/Contents/MacOS/
cp -r .build/arm64-apple-macosx/debug/Belve_Belve.bundle Belve.app/Contents/MacOS/ 2>/dev/null || true

cat > Belve.app/Contents/Info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Belve</string>
    <key>CFBundleIdentifier</key>
    <string>com.belve.app</string>
    <key>CFBundleName</key>
    <string>Belve</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Build belve-persist (process persistence tool) for Linux
PERSIST_DIR="tools/belve-persist"
if [ -d "$PERSIST_DIR" ]; then
    echo "Building belve-persist..."
    # `-trimpath -buildvcs=false` で deterministic build を保証する。
    # belve-setup の md5 比較が空振りしないように (= source 不変なら md5 不変)。
    (cd "$PERSIST_DIR" && \
        CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -buildvcs=false -ldflags="-s -w" -o belve-persist-linux-amd64 . && \
        CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -buildvcs=false -ldflags="-s -w" -o belve-persist-linux-arm64 . && \
        CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -buildvcs=false -ldflags="-s -w" -o belve-persist-darwin-arm64 . \
    ) 2>/dev/null || true
fi

# Copy Resources (belve CLI + claude wrapper + belve-persist binaries)
mkdir -p Belve.app/Contents/Resources/bin
cp Sources/Belve/Resources/bin/belve Belve.app/Contents/Resources/bin/ 2>/dev/null || true
cp Sources/Belve/Resources/bin/claude Belve.app/Contents/Resources/bin/ 2>/dev/null || true
cp Sources/Belve/Resources/bin/codex Belve.app/Contents/Resources/bin/ 2>/dev/null || true
cp Sources/Belve/Resources/bin/belve-setup Belve.app/Contents/Resources/bin/ 2>/dev/null || true
cp Sources/Belve/Resources/bin/session-bootstrap.sh Belve.app/Contents/Resources/bin/ 2>/dev/null || true
# belve-connect was removed (tunnel migration); purge stale copy from previous builds
rm -f Belve.app/Contents/Resources/bin/belve-connect
cp "$PERSIST_DIR/belve-persist-linux-amd64" Belve.app/Contents/Resources/bin/ 2>/dev/null || true
cp "$PERSIST_DIR/belve-persist-linux-arm64" Belve.app/Contents/Resources/bin/ 2>/dev/null || true
cp "$PERSIST_DIR/belve-persist-darwin-arm64" Belve.app/Contents/Resources/bin/ 2>/dev/null || true
chmod +x Belve.app/Contents/Resources/bin/* 2>/dev/null || true

# Sign Go binaries individually (macOS kills unsigned Mach-O binaries)
for bin in Belve.app/Contents/Resources/bin/belve-persist-darwin-arm64; do
    [ -f "$bin" ] && codesign --force --sign - "$bin" 2>/dev/null
done

# Move resource bundle out of MacOS to avoid codesign sub-bundle issues
mkdir -p Belve.app/Contents/Resources
if [ -d "Belve.app/Contents/MacOS/Belve_Belve.bundle" ]; then
    rm -rf Belve.app/Contents/Resources/Belve_Belve.bundle
    mv Belve.app/Contents/MacOS/Belve_Belve.bundle Belve.app/Contents/Resources/
fi

# Re-sign so Info.plist is bound to the signature (required for notifications)
codesign --force --sign - Belve.app

echo "Belve.app built successfully"
