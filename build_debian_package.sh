#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_DIR="${SCRIPT_DIR}/packages"
SRC_DIR="${SCRIPT_DIR}/IMSProg"

mkdir -p "${PACKAGES_DIR}"

echo "=== Building IMSProg Debian arm64 package using Podman container ==="

podman run --rm \
    --security-opt label=disable \
    -v "${SRC_DIR}:/src:ro" \
    -v "${PACKAGES_DIR}:/packages:rw" \
    imsprog-debian-builder \
    bash -c '
set -euo pipefail

echo "--> [1/5] Copying source to build container..."
mkdir -p /tmp/src /tmp/build /tmp/pkg
cp -a /src/. /tmp/src/


echo "--> [3/6] Configuring and building with 64K page alignment..."
cd /tmp/build
cmake /tmp/src \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr

cmake --build . -j$(nproc)

echo "--> [4/6] Installing to package root..."
DESTDIR=/tmp/pkg cmake --install .

echo "--> Verifying ELF page alignment (should be 0x10000 = 64KB):"
readelf -l /tmp/pkg/usr/bin/IMSProg | grep LOAD -A 1
readelf -l /tmp/pkg/usr/bin/IMSProg_editor | grep LOAD -A 1
readelf -l /tmp/pkg/usr/bin/IMSProg_database_update | grep LOAD -A 1

echo "--> [5/6] Creating Debian package metadata..."
mkdir -p /tmp/pkg/DEBIAN
mkdir -p /tmp/pkg/debian
cat <<EOF > /tmp/pkg/debian/control
Source: imsprog
Maintainer: Mikhail Medvedev <bigbigmdm@mail.ru>

Package: imsprog
Architecture: arm64
Description: IMSProg programmer
EOF

cd /tmp/pkg
SHLIBS_DEPS=$(dpkg-shlibdeps -O usr/bin/IMSProg usr/bin/IMSProg_editor usr/bin/IMSProg_database_update | sed -e "s/^shlibs:Depends=//")
rm -rf /tmp/pkg/debian

echo "Detected dependencies: ${SHLIBS_DEPS}"


INSTALLED_SIZE=$(du -sk /tmp/pkg/usr | cut -f1)

cat <<EOF > /tmp/pkg/DEBIAN/control
Package: imsprog
Version: 1.9.1-1
Architecture: arm64
Maintainer: Mikhail Medvedev <bigbigmdm@mail.ru>
Installed-Size: ${INSTALLED_SIZE}
Depends: ${SHLIBS_DEPS}
Section: electronics
Priority: optional
Homepage: https://github.com/bigbigmdm/IMSProg
Description: I2C, SPI and MicroWire EEPROM/Flash chip programmer with EZP2023+ support
 IMSProg is a free software for CH341A/CH347T/FT232H and EZP2023+/EZP2019
 based chip programmers with graphical interface. With IMSProg you can read,
 verify, program, erase I2C, SPI, SPI NOR, MicroWire, Dataflash EEPROM chips.
 Includes support for 4K and 16K kernel page sizes on arm64.
EOF

cat <<\EOF > /tmp/pkg/DEBIAN/postinst
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger --subsystem-match=usb 2>/dev/null || true
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database -q /usr/share/applications 2>/dev/null || true
    fi
fi
exit 0
EOF
chmod 755 /tmp/pkg/DEBIAN/postinst

cat <<\EOF > /tmp/pkg/DEBIAN/postrm
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null || true
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database -q /usr/share/applications 2>/dev/null || true
    fi
fi
exit 0
EOF
chmod 755 /tmp/pkg/DEBIAN/postrm

echo "--> [6/6] Generating .deb package..."
dpkg-deb --build --root-owner-group /tmp/pkg /packages/imsprog_1.9.1-1_arm64.deb

echo "--> Creating standalone tarball..."
tar -C /tmp/pkg -czf /packages/imsprog-1.9.1-debian12-arm64.tar.gz usr

echo "--> Debian arm64 build completed successfully!"
'

echo "=== Debian build finished ==="
