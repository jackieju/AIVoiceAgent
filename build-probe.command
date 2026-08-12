#!/bin/bash
set -e
cd "$(dirname "$0")"

swift build -c release

APP="Probe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/VoiceAgentMac "$APP/Contents/MacOS/Probe"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Probe</string>
    <key>CFBundleIdentifier</key><string>com.joycom.aivoiceagent.probe</string>
    <key>CFBundleName</key><string>Probe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>AEC probe needs the microphone to measure echo cancellation.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo ""
echo "打包完成: $APP"
echo "请在终端运行 (能看到输出, 且有麦克风权限):"
echo "    ./$APP/Contents/MacOS/Probe"
echo "注意: 用扬声器外放, 切勿戴耳机, 全程保持安静。"
