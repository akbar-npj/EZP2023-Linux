# EZP2023+ USB High-Speed Programmer (Linux Port & IMSProg Integration)

This repository contains the complete reverse-engineered Linux support for the **EZP2023+** USB High-Speed SPI Flash / EEPROM Programmer (as well as compatible **EZP2019 / EZP2019+ / EZP2020 / EZP2023** devices).

It provides:
1. **Full GUI Integration in IMSProg**: Upstream-ready port of [IMSProg](https://github.com/akbar-npj/IMSProg) with native EZP2023+ support.
2. **Pre-built Packages**: Ready-to-install `.deb` (Debian/Ubuntu/Raspberry Pi OS) and `.rpm` (Fedora/RHEL) packages for ARM64/AArch64 with both **4K and 16K kernel page size support**.
3. **Standalone CLI Utilities**: Both a zero-dependency Python script ([`linux/ezp2023.py`](linux/ezp2023.py)) and a high-performance native C tool ([`linux/ezp2023.c`](linux/ezp2023.c)).
4. **Database & Protocol Specs**: Extracted 878-chip database and protocol reverse engineering notes in [`linux/README.md`](linux/README.md).

---

## ⚡ Highlights

* **No Kernel Modules**: Driven completely in **userspace** using **`libusb-1.0`**.
* **4K & 16K Page Support**: All arm64 binaries are linked with `-Wl,-z,max-page-size=65536` (`0x10000` alignment), allowing them to run without `SIGSEGV` or alignment issues across standard 4KB kernels (Raspberry Pi 4, Debian/Ubuntu) and 16KB kernels (Raspberry Pi 5 default, Apple Silicon Asahi Linux).
* **Multiple Interfaces**: Choose between the full Qt6 GUI ([`IMSProg`](IMSProg/)) or lightweight terminal CLI tools.

---

## 📦 Quick Install (Pre-built Packages)

Pre-built binaries for **ARM64 / AArch64** are provided in the [`packages/`](packages/) directory:

### Debian / Ubuntu / Raspberry Pi OS (`arm64`):
```bash
sudo apt update
sudo apt install -y ./packages/imsprog_1.9.1-1_arm64.deb
```

### Fedora / RHEL (`aarch64`):
```bash
sudo dnf install ./packages/imsprog-1.9.1-1.fc44.aarch64.rpm
```

### Standalone Portable Archives:
If you prefer not to use package managers:
```bash
# For Debian/Ubuntu based systems:
sudo tar -C / -xzf packages/imsprog-1.9.1-debian12-arm64.tar.gz

# For Fedora/RHEL based systems:
sudo tar -C / -xzf packages/imsprog-1.9.1-fedora-aarch64.tar.gz

# Reload udev rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

---

## 🛠️ Compiling IMSProg From Source

### 1. Prerequisites

#### Debian / Ubuntu / Raspberry Pi OS:
```bash
sudo apt update
sudo apt install -y \
    build-essential \
    cmake \
    pkg-config \
    qt6-base-dev \
    qt6-tools-dev \
    qt6-tools-dev-tools \
    qt6-l10n-tools \
    libusb-1.0-0-dev \
    libftdi1-dev
```

#### Fedora / RHEL:
```bash
sudo dnf install -y \
    gcc-c++ \
    cmake \
    pkgconf-pkg-config \
    qt6-qtbase-devel \
    qt6-qttools-devel \
    qt6-linguist \
    libusb1-devel \
    libftdi-devel
```

---

### 2. Native Compilation (All Subprojects)

Clone the repository with submodules:
```bash
git clone --recurse-submodules https://github.com/akbar-npj/EZP2023-Linux.git
cd EZP2023-Linux/IMSProg
```

Configure and build:
```bash
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build . -j$(nproc)
sudo cmake --install .
sudo udevadm control --reload-rules && sudo udevadm trigger
```

> [!NOTE]
> On ARM64 systems, CMake automatically applies `-Wl,-z,max-page-size=65536` so the generated binaries are 64KB page-aligned and compatible with both 4KB and 16KB kernels.

---

### 3. Containerized Build (Debian .deb via Podman / Docker)

You can build a clean, reproducible Debian `.deb` package in an isolated container without installing dev dependencies on your host:

```bash
# Run the automated build script:
./build_debian_package.sh
```

This compiles inside a Debian 12 container and outputs:
* `packages/imsprog_1.9.1-1_arm64.deb`
* `packages/imsprog-1.9.1-debian12-arm64.tar.gz`

---

### 4. Building the Fedora RPM Package

```bash
cd IMSProg

# Prepare source tarball for rpmbuild
mkdir -p ~/rpmbuild/SOURCES
tar --transform 's|^|IMSProg-1.9.1/|' --exclude='.git' --exclude='build*' -czf ~/rpmbuild/SOURCES/v1.9.1.tar.gz -C . .

# Build the RPM
rpmbuild -ba rpm/imsprog.spec
```
The output package will be placed in `~/rpmbuild/RPMS/aarch64/`.

---

## 💻 Standalone CLI Tools

For headless servers, fast scripting, or environments without Qt, standalone CLI tools are available in [`linux/`](linux/).

### Python CLI (`linux/ezp2023.py`)
Requires only standard Python 3 and `libusb-1.0` (zero external Python pip packages required):

```bash
# Detect chip & query database
./linux/ezp2023.py detect

# Backup / Read flash to file
./linux/ezp2023.py read bios_backup.bin

# Erase chip
./linux/ezp2023.py erase

# Check if chip is blank (0xFF)
./linux/ezp2023.py blankcheck

# Write image to flash (with automatic verification)
./linux/ezp2023.py write new_bios.bin

# Verify flash content against a file
./linux/ezp2023.py verify new_bios.bin
```

### High-Performance Native C CLI (`linux/ezp2023.c`)
```bash
cd linux
make
./ezp2023 detect
./ezp2023 read backup.bin 16777216
./ezp2023 erase
./ezp2023 write new_bios.bin
```

---

## 🔌 Hardware & Protocol Overview

* **Supported Programmer Models**:
  * `EZP2019 / EZP2023+`: USB VID `0x1FC8`, PID `0x310B`
  * `EZP2019+`: USB VID `0x1FC8`, PID `0x310C`
  * `EZP2023`: USB VID `0x1FC8`, PID `0x310D`
* **Endpoints**:
  * `0x02` (Bulk OUT): 64-byte command packets
  * `0x82` (Bulk IN): 64-byte command responses & read data
  * `0x01` (Bulk OUT): High-speed bulk write data stream
* **Mandatory Handshake**: Device requires `GET_DESCRIPTOR` string requests (strings `1` & `2`) before accepting bulk packets.
* **Detailed Protocol Specification**: See [`linux/README.md`](linux/README.md) for full reverse-engineering notes and packet breakdown.

---

## 📁 Repository Structure

```
├── build_debian_package.sh    # Automated script to build Debian arm64 .deb
├── Dockerfile.debian-arm64    # Container definition for Debian arm64 builds
├── packages/                  # Pre-compiled .deb, .rpm, and tarball packages
│   ├── imsprog_1.9.1-1_arm64.deb
│   ├── imsprog-1.9.1-1.fc44.aarch64.rpm
│   └── README.md
├── IMSProg/                   # Submodule with EZP2023+ Qt GUI driver integration
│   ├── IMSProg_programmer/    # GUI chip programmer & EZP2023+ bulk driver
│   ├── IMSProg_editor/        # Chip database editor
│   └── IMSProg_database_update/ # Database updater
├── linux/                     # Standalone Linux CLI drivers & reverse engineering
│   ├── 99-ezp2023.rules       # Udev rules for device permissions
│   ├── ezp2023.py             # Pure-Python CLI tool
│   ├── ezp2023.c              # Fast native C CLI tool
│   ├── ezp_db.py              # Chip database parser & search tool
│   └── README.md              # Detailed protocol & hardware specification
└── EZP2023+ ver3.0/           # Original Windows v3.0 binaries & driver archive
```

---

## 📄 License & Credits

* Hardware protocol reverse-engineered from official software for open-source Linux interoperability.
* Drivers and tools released under **GPL-2.0-or-later** / **GPL-3.0-or-later**.
