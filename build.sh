#!/bin/bash
# Build WingScreen.app — bản universal (chạy trên cả Mac Intel và Apple Silicon, macOS 12.3+)
# Một app chứa cả 2 chế độ: Máy chính (phát) và Màn hình phụ (nhận).
#   ./build.sh            -> dist/WingScreen.app (universal)
#   ./build.sh native     -> chỉ build cho kiến trúc của máy đang dùng (nhanh hơn)
set -euo pipefail
cd "$(dirname "$0")"
OUT="dist"
NAME="WingScreen"
mkdir -p "$OUT"

case "${1:-universal}" in
  native) ARCHS=("$(uname -m)") ;;
  *)      ARCHS=(arm64 x86_64) ;;
esac

# Không liên kết thư viện tương thích Swift cũ (libswiftCompatibility56...):
# macOS 12.3+ đã có sẵn Swift runtime, và Command Line Tools mới không còn kèm bản x86_64 của thư viện này.
SWIFT_FLAGS=(-Xswiftc -runtime-compatibility-version -Xswiftc none)

BINS=()
FAILED=()
for arch in "${ARCHS[@]}"; do
  echo "==> Build $NAME ($arch)"
  # Mỗi kiến trúc một thư mục build riêng (tránh bản sau ghi đè bản trước)
  SCRATCH=".build/arch-$arch"
  if swift build -c release --arch "$arch" --product "$NAME" --scratch-path "$SCRATCH" "${SWIFT_FLAGS[@]}"; then
    mkdir -p "$OUT/.bin/$arch"
    cp "$(swift build -c release --arch "$arch" --scratch-path "$SCRATCH" --show-bin-path)/$NAME" "$OUT/.bin/$arch/$NAME"
    BINS+=("$OUT/.bin/$arch/$NAME")
  else
    echo "!! Build $arch thất bại — bỏ qua kiến trúc này"
    FAILED+=("$arch")
  fi
done
if [ "${#BINS[@]}" -eq 0 ]; then
  echo "Build thất bại cho mọi kiến trúc."
  exit 1
fi

APP="$OUT/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#BINS[@]}" -gt 1 ]; then
  lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$NAME"
else
  cp "${BINS[0]}" "$APP/Contents/MacOS/$NAME"
fi

# Icon app (Finder, Dock, Login Items): icons/WingScreen.png — ảnh vuông, nên 1024x1024
ICON_PLIST=""
PNG="icons/$NAME.png"
if [ -f "$PNG" ]; then
  TMP="$(mktemp -d)"
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$TMP"
  ICON_PLIST="<key>CFBundleIconFile</key><string>AppIcon</string>"
  echo "    + icon app: $PNG"
fi

# Icon trên thanh menu (chế độ máy chính): icons/MenuBarIcon.png — hình đen, nền trong suốt
if [ -f "icons/MenuBarIcon.png" ]; then
  cp "icons/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
  echo "    + icon thanh menu: icons/MenuBarIcon.png"
fi

# Nội dung "Giới thiệu": about.json (sửa file này để tuỳ chỉnh). Phiên bản ghi đè được bằng WINGSCREEN_VERSION.
json_get() {   # json_get <khoá> — đọc chuỗi trong about.json
  [ -f about.json ] || return 0
  plutil -extract "$1" raw -o - about.json 2>/dev/null ||
    /usr/bin/python3 -c "import json,sys; print(json.load(open('about.json')).get(sys.argv[1],''))" "$1" 2>/dev/null || true
}
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

VERSION="${WINGSCREEN_VERSION:-}"
VERSION="${VERSION#v}"
[ -n "$VERSION" ] || VERSION="$(json_get version)"
VERSION="${VERSION:-1.0}"
DISPLAY_NAME="$(json_get name)"
DISPLAY_NAME="${DISPLAY_NAME:-WingScreen}"
COPYRIGHT="$(json_get copyright)"
BUILD_DATE="$(date '+%Y-%m-%d')"
BUILD_NUMBER="$(date '+%Y%m%d%H%M')"
if [ -f about.json ]; then
  cp about.json "$APP/Contents/Resources/about.json"
  echo "    + about.json: $DISPLAY_NAME $VERSION ($BUILD_DATE)"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>vn.wingscreen.WingScreen</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$(xml_escape "$DISPLAY_NAME")</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(xml_escape "$VERSION")</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>WSBuildDate</key><string>$BUILD_DATE</string>
  <key>NSHumanReadableCopyright</key><string>$(xml_escape "$COPYRIGHT")</string>
  <key>LSMinimumSystemVersion</key><string>12.3</string>
  <key>NSHighResolutionCapable</key><true/>
  $ICON_PLIST
  <key>NSLocalNetworkUsageDescription</key><string>WingScreen kết nối các máy tính để dùng làm màn hình phụ.</string>
  <key>NSBonjourServices</key><array><string>_wingscreen._tcp</string></array>
</dict>
</plist>
EOF
# Dọn thuộc tính mở rộng (ổ ngoài exFAT/NTFS hay tạo file ._*), đảm bảo quyền chạy, rồi ký ad-hoc
find "$APP" -name '._*' -delete 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true
chmod 755 "$APP/Contents/MacOS/$NAME"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "    + chữ ký hợp lệ"
plutil -lint -s "$APP/Contents/Info.plist" && echo "    + Info.plist hợp lệ"

# Gói zip để chép sang máy khác (giữ quyền chạy + chữ ký). Giải nén bằng Finder trên máy kia.
rm -f "$OUT/WingScreen-macOS.zip"
ditto -c -k --keepParent "$APP" "$OUT/WingScreen-macOS.zip"
echo "    + $OUT/WingScreen-macOS.zip"
echo
echo "Xong: $APP  ($(lipo -archs "$APP/Contents/MacOS/$NAME"))"
echo "Chép WingScreen.app vào thư mục Applications trên mọi máy Mac (macOS 12.3+)."
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "Lưu ý: không build được cho ${FAILED[*]} (xem lỗi phía trên) — app chỉ chạy trên: $(lipo -archs "$APP/Contents/MacOS/$NAME")"
fi
rm -rf "$OUT/.bin"
