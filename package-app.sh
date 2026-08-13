#!/bin/bash
# 把 VoiceAgentMac 打包成可双击的 macOS .app
# 关键：Info.plist 必须声明麦克风 + 语音识别用途，否则 macOS 直接 crash 而非弹权限框
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="AIVoiceAgent"
BUILD_DIR="$ROOT/.build/release"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
BIN_SRC="$BUILD_DIR/VoiceAgentMac"

echo "==> release 编译"
swift build -c release

if [[ ! -x "$BIN_SRC" ]]; then
  echo "❌ 找不到可执行文件: $BIN_SRC" >&2
  exit 1
fi

echo "==> 清理并重建 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 真正的可执行文件放进 bundle
cp "$BIN_SRC" "$APP/Contents/MacOS/VoiceAgentMac-bin"

# 双击入口：在 Terminal.app 打开，让命令行式 print 输出可见
cat > "$APP/Contents/MacOS/$APP_NAME" <<'LAUNCHER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/VoiceAgentMac-bin"
# 在 Terminal 里运行真正的二进制，这样能看到聆听/思考/说话状态和对话文本
osascript <<OSA
tell application "Terminal"
    activate
    do script "'$BIN'"
end tell
OSA
LAUNCHER
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# Info.plist —— 用 defaults/PlistBuddy 避免 XML 手写出错
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.ju.aivoiceagent" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 0.1.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.1.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string AIVoiceAgent 需要麦克风来听你说话。" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string AIVoiceAgent 需要语音识别把你的话转成文字。" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool false" "$PLIST"

echo "==> ad-hoc 签名（TCC 权限归属靠稳定签名）"
codesign --force --deep --sign - "$APP"

echo "==> 完成: $APP"
echo "    双击运行，或: open '$APP'"
