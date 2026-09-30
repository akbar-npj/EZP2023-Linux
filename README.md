# EZP2023+ USB High-Speed Programmer (Linux Port & Protocol Specification)

This repository contains the reverse-engineered Linux driver, standalone CLI tools (both Python and native C), protocol documentation, and original Windows distribution for the **EZP2023+** USB High-Speed SPI Flash / EEPROM Programmer (as well as compatible **EZP2019 / EZP2019+ / EZP2020 / EZP2023** devices).

---

## ⚡ Key Highlights

* **No Kernel Module Needed**: The Windows driver is an INF wrapper around `libusb-win32` (v1.2.6.0). On Linux, the programmer is driven natively in **userspace** using **`libusb-1.0`**.
* **Zero-Dependency Python Utility**: [`linux/ezp2023.py`](linux/ezp2023.py) works out of the box using Python's built-in `ctypes` to talk to system `libusb-1.0`.
* **High-Performance Native C Tool**: [`linux/ezp2023.c`](linux/ezp2023.c) compiles cleanly with `make` for maximum flash read/write speed.
* **Full Database Integration**: Supports the 878 chip definitions extracted from the official [`EZP2023+.Dat`](EZP2023+%20ver3.0/EZP2023+.Dat) file via [`linux/ezp_db.py`](linux/ezp_db.py).
* **udev Rules Included**: [`linux/99-ezp2023.rules`](linux/99-ezp2023.rules) enables non-root access on any standard Linux distribution.

---

## 📁 Repository Structure

```
├── EZP2023+ ver3.0/          # Original Windows software, manuals, drivers & database
│   ├── EZP2023+.exe          # Official Windows 32-bit application
│   ├── EZP2023+.Dat          # 878-chip database (68-byte binary records)
│   ├── Win10_11_driver/      # libusb-win32 INF and driver package
│   └── *.pdf                 # Official user manuals (Chinese & English)
│
├── linux/                    # Linux Port & Reverse Engineering
│   ├── 99-ezp2023.rules      # Udev rules for device permissions
│   ├── ezp2023.py            # Standalone Python CLI programmer (ctypes + libusb)
│   ├── ezp_db.py             # Parser / search tool for EZP2023+.Dat
│   ├── ezp2023.c             # Fast native C implementation
│   ├── Makefile              # Build script for native C binary
│   └── README.md             # Complete technical reverse-engineering documentation
│
└── .gitignore
```

---

## 🚀 Quick Start (Linux)

### 1. Install udev permissions
```bash
sudo cp linux/99-ezp2023.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

### 2. Run the Python CLI Tool
```bash
# Auto-detect chip & query database
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

### 3. Build & Run Native C Binary
```bash
cd linux
make
./ezp2023 detect
./ezp2023 read backup.bin 16777216
./ezp2023 erase
./ezp2023 write new_bios.bin
```

---

## 🔍 Hardware & Protocol Overview

* **USB VID / PID**: `0x1FC8` / `0x310B` (EZP2019, EZP2023+), `0x310C` (EZP2019+), `0x310D` (EZP2023)
* **Endpoints**:
  * `0x02` (Bulk OUT): 64-byte command packet
  * `0x82` (Bulk IN): 64-byte command response & bulk read data stream
  * `0x01` (Bulk OUT): Fast bulk data write stream
* **Mandatory Handshake**: Device firmware requires string descriptor queries (`GET_DESCRIPTOR` for strings `1` and `2`, `"www.zhifengsoft.com"` / `"WinUSBComm Device"`) before accepting bulk transfers.
* Detailed protocol layout and command packet structure is available in [**`linux/README.md`**](linux/README.md).

---

## 📄 License & Credits

* Hardware protocol reverse-engineered from the original software for open-source Linux interoperability.
* Linux driver code provided under GPL-2.0-or-later.
