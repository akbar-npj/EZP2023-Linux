# Pre-built IMSProg Packages with EZP2023+ Support (ARM64 / AArch64)

These pre-built packages contain **IMSProg** with **EZP2023+ / EZP2019** programmer support compiled specifically for **ARM64 / AArch64** systems.

### 4K and 16K Kernel Page Size Support
All binaries are linked with `-Wl,-z,max-page-size=65536` (`0x10000` alignment), guaranteeing full runtime compatibility across both:
* **4KB kernel page size** (Raspberry Pi 4, standard Debian/Ubuntu arm64)
* **16KB kernel page size** (Raspberry Pi 5 default kernel, Apple Silicon Asahi Linux)

---

## Available Packages

| Package / Archive | Target OS | Description | SHA256 Checksum |
| :--- | :--- | :--- | :--- |
| `imsprog_1.9.1-1_arm64.deb` | Debian 12 / Ubuntu / Raspberry Pi OS | Native Debian package with auto-resolved library dependencies and udev hooks | `fad6fe275608c8b7c2054b5265917e63bc206d71ec6b9458465175503c295717` |
| `imsprog-1.9.1-1.fc44.aarch64.rpm` | Fedora / RHEL / CentOS | Native RPM package with systemd-udev rules and menu entries | `0189ba384041c9fab7c7de857519b7067054151510276cd57896b608397c050d` |
| `imsprog-1.9.1-debian12-arm64.tar.gz` | Debian 12 / Ubuntu | Standalone binary tarball (portable install to `/usr` or `/usr/local`) | `1debb78adde8e91be3c618b203d22082eab35dc26136be9847bef612124b28f8` |
| `imsprog-1.9.1-fedora-aarch64.tar.gz` | Fedora / RHEL | Standalone binary tarball (portable install to `/usr` or `/usr/local`) | `f361a9a329e6edac6b0c1510d9b5f69a48b9fa6a2cd6571303286a6f485fbfc8` |

---

## Installation

### Debian, Ubuntu & Raspberry Pi OS (`arm64`):
```bash
sudo apt update
sudo apt install -y ./imsprog_1.9.1-1_arm64.deb
```

### Fedora (`aarch64`):
```bash
sudo dnf install ./imsprog-1.9.1-1.fc44.aarch64.rpm
```

### Standalone Tarball (any distro):
```bash
sudo tar -C / -xzf imsprog-1.9.1-debian12-arm64.tar.gz
sudo udevadm control --reload-rules && sudo udevadm trigger
```
