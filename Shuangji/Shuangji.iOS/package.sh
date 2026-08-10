#!/usr/bin/env bash
# 一键出 tipa： ./package.sh
# 依赖：Xcode + brew(xcodegen, ldid)  —— 脚本会尝试自动 brew install
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
OUT="$ROOT/dist"
APP_NAME="水溶C"
BUNDLE_ID="com.shuiyong.ports"
DERIVED="$ROOT/.build"
SDK="${SDK:-iphoneos}"

echo "==> [1/6] 检查工具"
export HOMEBREW_NO_REQUIRE_TAP_TRUST="${HOMEBREW_NO_REQUIRE_TAP_TRUST:-1}"
brew untap aws/tap 2>/dev/null || true
if ! command -v xcodebuild >/dev/null; then
  echo "需要 Xcode 命令行工具"; exit 1
fi
if ! command -v xcodegen >/dev/null; then
  echo "安装 xcodegen..."
  brew install xcodegen || true
fi
if ! command -v xcodegen >/dev/null; then
  echo "缺少 xcodegen（请先在 CI 步骤安装）"; exit 1
fi
if ! command -v ldid >/dev/null; then
  echo "安装 ldid..."
  brew install ldid || brew install ldid-procursus || true
fi
if ! command -v ldid >/dev/null; then
  echo "缺少 ldid（请先在 CI 步骤安装）"; exit 1
fi

echo "==> [2/6] 生成工程"
xcodegen generate --spec project.yml
# 强制降到 Xcode 15 可读格式（防 XcodeGen 写出 objectVersion 77）
PBX="$ROOT/Shuiyong.xcodeproj/project.pbxproj"
if [[ -f "$PBX" ]]; then
  sed -i.bak 's/objectVersion = [0-9]*;/objectVersion = 56;/' "$PBX" || true
  sed -i.bak 's/compatibilityVersion = "Xcode 16[^"]*";/compatibilityVersion = "Xcode 15.0";/' "$PBX" || true
  sed -i.bak 's/preferredProjectObjectVersion = [0-9]*;/preferredProjectObjectVersion = 56;/' "$PBX" || true
  rm -f "$PBX.bak"
fi

echo "==> [3/6] 编译 App + dylib + Tunnel"
mkdir -p "$ROOT/Resources"
rm -rf "$DERIVED"
xcodebuild \
  -project Shuiyong.xcodeproj \
  -scheme Shuiyong \
  -configuration Release \
  -sdk "$SDK" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_PATH="$(find "$DERIVED/Build/Products" -name '*.app' -maxdepth 3 | head -n1)"
if [[ -z "$APP_PATH" ]]; then
  echo "找不到 .app"; exit 1
fi
echo "APP=$APP_PATH"

echo "==> [4/6] 编 syinject 并塞进 App"
mkdir -p "$APP_PATH"
clang -arch arm64 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -miphoneos-version-min=15.0 -O2 \
  -o "$APP_PATH/syinject" "$ROOT/Tools/syinject.c"
chmod +x "$APP_PATH/syinject"
# 把 dylib 放进资源（注入器用）
DYLIB="$(find "$DERIVED/Build/Products" -name 'ShuiyongMem.dylib' | head -n1 || true)"
if [[ -n "$DYLIB" ]]; then
  cp -f "$DYLIB" "$APP_PATH/ShuiyongMem.dylib"
  mkdir -p "$APP_PATH/Frameworks"
  cp -f "$DYLIB" "$APP_PATH/Frameworks/ShuiyongMem.dylib" || true
fi

echo "==> [5/6] ldid 伪签（必须带 App.entitlements，否则注入页读不到已装应用）"
ENT_APP="$ROOT/entitlements/App.entitlements"
ENT_TUN="$ROOT/entitlements/Tunnel.entitlements"
# 主程序
MAIN_BIN="$APP_PATH/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist" 2>/dev/null || echo Shuiyong)"
[[ -f "$MAIN_BIN" ]] || MAIN_BIN="$(find "$APP_PATH" -maxdepth 1 -type f -perm -111 | head -n1)"
echo "MAIN_BIN=$MAIN_BIN"
ldid -S"$ENT_APP" "$MAIN_BIN"
# 核对关键 entitlement 是否已写入
if command -v ldid >/dev/null; then
  ENT_DUMP="$(ldid -e "$MAIN_BIN" 2>/dev/null || true)"
  if ! grep -q "canmaplsdatabase" <<<"$ENT_DUMP"; then
    echo "警告: 主程序 entitlement 可能未写入 canmaplsdatabase，重试一次"
    ldid -S"$ENT_APP" "$MAIN_BIN"
  fi
  if ! grep -q "no-sandbox" <<<"$ENT_DUMP"; then
    echo "警告: 主程序 entitlement 可能未写入 no-sandbox"
  fi
fi
ldid -S"$ENT_APP" "$APP_PATH/syinject" 2>/dev/null || ldid -S "$APP_PATH/syinject" || true
[[ -f "$APP_PATH/ShuiyongMem.dylib" ]] && ldid -S "$APP_PATH/ShuiyongMem.dylib" || true
# 扩展
EXT="$(find "$APP_PATH/PlugIns" -name '*.appex' 2>/dev/null | head -n1 || true)"
if [[ -n "$EXT" ]]; then
  EXT_BIN="$EXT/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$EXT/Info.plist")"
  ldid -S"$ENT_TUN" "$EXT_BIN" || ldid -S"$ENT_APP" "$EXT_BIN"
fi
rm -rf "$APP_PATH/_CodeSignature" "$APP_PATH/embedded.mobileprovision" || true

echo "==> [6/6] 打 tipa"
rm -rf "$OUT/Payload" "$OUT/${APP_NAME}.tipa"
mkdir -p "$OUT/Payload"
cp -R "$APP_PATH" "$OUT/Payload/${APP_NAME}.app"
(
  cd "$OUT"
  zip -qr "${APP_NAME}.tipa" Payload
  rm -rf Payload
)
ls -lh "$OUT/${APP_NAME}.tipa"
echo ""
echo "完成: $OUT/${APP_NAME}.tipa"
echo "用 TrollStore 安装即可。"
