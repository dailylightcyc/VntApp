#!/bin/bash
set -euo pipefail

# GitHub Actions 的 Docker 没有交互式终端。tzdata 等软件包必须使用
# 非交互模式，否则会停在地区/时区选择界面等待输入。
export DEBIAN_FRONTEND=noninteractive
export TZ=Etc/UTC

if [ "$#" -ne 2 ]; then
  echo "用法: $0 <bundle-dir> <appimage-arch>" >&2
  exit 2
fi

BUNDLE=$1
APPIMAGE_ARCH=$2

step() { echo -e "\n\033[1;36m>>> $1\033[0m\n"; }

step "安装系统依赖"
ln -fs /usr/share/zoneinfo/${TZ} /etc/localtime
apt-get update -q
apt-get install -y --no-install-recommends --no-install-suggests \
  curl git cmake ninja-build pkg-config clang \
  libgtk-3-dev libblkid-dev liblzma-dev \
  libappindicator3-dev libkeybinder-3.0-dev \
  libsecret-1-dev libjsoncpp-dev \
  ca-certificates wget file xz-utils unzip tzdata
dpkg-reconfigure --frontend noninteractive tzdata

step "安装 Flutter 3.44.9"
git clone --depth 1 --branch 3.44.9 \
  https://github.com/flutter/flutter.git /opt/flutter
export PATH="/opt/flutter/bin:$PATH"
flutter precache --linux
flutter --version

step "安装 Rust stable"
export CARGO_HOME=/opt/cargo
export RUSTUP_HOME=/opt/rustup
export PATH="/opt/cargo/bin:$PATH"
curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | \
  sh -s -- -y --default-toolchain stable --no-modify-path \
    --no-update-default-toolchain
rustup set auto-self-update disable
rustup default stable
rustc -V
cargo -V

step "构建 Flutter Linux Release"
flutter config --no-analytics
flutter pub get
flutter build linux --release -v

step "下载并解压 appimagetool"
APPIMAGETOOL_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${APPIMAGE_ARCH}.AppImage"
echo "下载: $APPIMAGETOOL_URL"
wget -q -O appimagetool.AppImage "$APPIMAGETOOL_URL"
chmod +x appimagetool.AppImage
./appimagetool.AppImage --appimage-extract
mv squashfs-root appimagetool-extracted

step "构建 AppDir"
mkdir -p AppDir/usr/share/icons/hicolor/256x256/apps
cp -r "${BUNDLE}/." AppDir/
cp assets/app_icon.png AppDir/vnt_app.png
cp assets/app_icon.png AppDir/usr/share/icons/hicolor/256x256/apps/vnt_app.png

cat > AppDir/vnt_app.desktop << EOF
[Desktop Entry]
Name=VNT App
Exec=vnt_app
Icon=vnt_app
Type=Application
Categories=Network;
EOF

cat > AppDir/AppRun << 'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/vnt_app" "$@"
EOF
chmod +x AppDir/AppRun

step "打包 AppImage（arch=${APPIMAGE_ARCH}）"
ARCH=${APPIMAGE_ARCH} ./appimagetool-extracted/AppRun AppDir \
  vntApp-linux-${APPIMAGE_ARCH}.AppImage

step "完成 ✓ vntApp-linux-${APPIMAGE_ARCH}.AppImage"
