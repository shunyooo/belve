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

# Copy Resources (belve CLI + claude wrapper)
mkdir -p Belve.app/Contents/Resources/bin
cp Sources/Belve/Resources/bin/belve Belve.app/Contents/Resources/bin/ 2>/dev/null || true
cp Sources/Belve/Resources/bin/claude Belve.app/Contents/Resources/bin/ 2>/dev/null || true
chmod +x Belve.app/Contents/Resources/bin/belve Belve.app/Contents/Resources/bin/claude 2>/dev/null || true

# Move resource bundle out of MacOS to avoid codesign sub-bundle issues
mkdir -p Belve.app/Contents/Resources
if [ -d "Belve.app/Contents/MacOS/Belve_Belve.bundle" ]; then
    rm -rf Belve.app/Contents/Resources/Belve_Belve.bundle
    mv Belve.app/Contents/MacOS/Belve_Belve.bundle Belve.app/Contents/Resources/
fi

# Re-sign so Info.plist is bound to the signature (required for notifications)
codesign --force --sign - Belve.app

echo "Belve.app built successfully"
