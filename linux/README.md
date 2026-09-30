# EZP2023+ / EZP2019 Linux Driver & Porting Guide

This directory contains the reverse-engineered Linux port and documentation for the **EZP2023+** USB High-Speed Flash Programmer (and compatible **EZP2019 / EZP2019+ / EZP2020 / EZP2023** devices).

---

## 1. Executive Summary: Driver Architecture

Analysis of the official Windows distribution (`EZP2023+ ver3.0`) reveals that:
- **No kernel driver development is needed on Linux.**
- The Windows driver package (`Win10_11_driver`, `WIN7_driver`) is simply an INF wrapper for **`libusb-win32` (v1.2.6.0)** generic USB driver.
- The official application (`EZP2023+.exe`) is a 32-bit PE GUI binary that dynamically loads `libusb0.dll` (`usb_open`, `usb_bulk_write`, `usb_bulk_read`, etc.) and performs all programmer operations in **userspace**.
- On Linux, this hardware communicates directly via **`libusb-1.0`** without any custom kernel modules.
- Only a standard `udev` rule is needed to allow non-root users access to the device.

---

## 2. Hardware & USB Layer Specifications

| Parameter | Specification |
|---|---|
| **Vendor ID (VID)** | `0x1FC8` (NXP Semiconductors / Zhifengsoft) |
| **Product IDs (PID)** | `0x310B` (EZP2019, EZP2023+)<br>`0x310C` (EZP2019+)<br>`0x310D` (EZP2023) |
| **USB Class / Subclass** | `0xFF / 0x00` (Vendor-Specific Class) |
| **Interface** | Interface `0`, Alternate Setting `0` |
| **Command OUT Endpoint** | `0x02` (Bulk OUT, 64-byte packets) |
| **Command Response / Read IN Endpoint** | `0x82` (Bulk IN, 64-byte packets / data stream) |
| **Fast Data Write OUT Endpoint** | `0x01` (Bulk OUT, page-aligned stream) |
| **Required Firmware Handshake** | Host must request String Descriptors 1 and 2 (`wIndex = 0x0409`) via `GET_DESCRIPTOR` control transfers prior to issuing bulk commands. |

---

## 3. Communication Protocol Specification

All commands are exchanged over 64-byte (`0x40`) structured packets. Numerical fields larger than 1 byte are transmitted in **big-endian (network byte order)** over USB.

### 3.1 Command Packet Layout (Host to Device)

| Offset | Size | Type | Field Description |
|---|---|---|---|
| `0x00` | 1 byte | uint8 | Control prefix (`0x00` for standard commands, `0x01` for RESET / ERASE) |
| `0x01` | 1 byte | uint8 | **Command ID**: `0x02` (Erase), `0x05` (Trigger), `0x07` (Read/Setup), `0x08` (Reset), `0x09` (Connect/Probe), `0x0A` (Status), `0x0B` (Write/Raw SPI) |
| `0x02..0x03` | 2 bytes | uint16_le | Protocol configuration (`0x00`=SPI NOR, `0x01`=Quad SPI, `0x02`=I2C, `0x03`=Microwire, `0x06`=4-Byte Addr) |
| `0x04..0x05` | 2 bytes | uint16_be | Page size in bytes (typically 256 for 25-series SPI flash) |
| `0x06..0x07` | 2 bytes | uint16_be | Timeout / retry counter (default: 1000) |
| `0x08..0x0B` | 4 bytes | uint32_be | Flash chip capacity (in bytes) or Address offset for Trigger |
| `0x0C..0x0F` | 4 bytes | uint32_be | JEDEC Chip ID |
| `0x10` | 1 byte | uint8 | Sub-mode / SPI speed divisor |
| `0x1A..0x1B` | 2 bytes | uint16_be | Erase parameter (`0x0080` for Chip Erase, or Sector Index for Sector Erase) |
| `0x1C` | 1 byte | uint8 | Voltage / UI flags (bit 0 = 1.8V Low Voltage mode) |
| `0x1D..0x3F` | 35 bytes | - | Reserved (zeroed) |

### 3.2 Operation Sequences

#### 1. Chip Detection (Probe)
1. Send 64-byte packet with `cmd = 0x09` (CONNECT) to EP `0x02`.
2. Wait 50 ms.
3. Read 64-byte response from EP `0x82` (wakes the SPI bus).
4. Send `cmd = 0x09` a second time and read 64-byte response.
5. Response payload:
   - `response[1]`: Manufacturer ID (e.g. `0xEF` for Winbond)
   - `response[2]`: Memory Type (e.g. `0x40`)
   - `response[3]`: Capacity Code (e.g. `0x18` = 16 MB)
   - JEDEC ID = `(response[1] << 16) | (response[2] << 8) | response[3]`

#### 2. Reading Flash Data
1. Send setup packet with `cmd = 0x07` (READ_SPI), specifying chip size and page size. Read 64-byte response.
2. Send trigger packet with `cmd = 0x05` (TRIGGER), setting `address = 0` at offset `0x08..0x0B`. Read 64-byte response.
3. Continuously read data from EP `0x82` in chunks of 256 bytes until the desired byte count is reached.

#### 3. Writing Flash Data
1. Send setup packet with `cmd = 0x07` (READ_SPI) or `cmd = 0x0B` (WRITE). Read 64-byte response.
2. Send trigger packet with `cmd = 0x05` (TRIGGER), setting `address = 0`. No response read.
3. Stream data out to EP `0x01` (EP_DATA_OUT) in page chunks (e.g. 256 bytes).
4. Wait 100 ms, then poll status until device indicates completion.

#### 4. Erasing Flash
1. Send setup packet with `cmd = 0x07`. Read response.
2. Send erase packet with:
   - `packet[0] = 0x01`
   - `packet[1] = 0x02` (CMD_ERASE)
   - `packet[0x1A] = 0x80`, `packet[0x1B] = 0x00` (Chip Erase)
3. Poll status every 30-50 ms with `cmd = 0x0A` (CMD_STATUS) until `response[0] & 0x01 == 0`.

---

## 4. Chip Database Format (`EZP2023+.Dat`)

The database bundled with the programmer contains 878 chip definitions stored as flat binary records of 68 bytes each:

```c
struct ezp_chip_record {
    char     name[48];        // "Type,Manufacturer,Model\0" (GB18030 / ASCII)
    uint32_t chip_id;         // 24-bit JEDEC ID
    uint32_t size;            // Capacity in bytes
    uint16_t pagesize;        // Page size in bytes (e.g., 256)
    uint16_t proto_enum_cfg;  // Protocol code
    uint16_t timeout_retries; // Timeout retry count
    uint16_t delay;           // Timing parameter
    uint32_t flags;           // Capability flags (erase, 1.8V, etc.)
};
```

---

## 5. Linux Usage Guide

### Step 1: Install udev Rules
To allow your user account to communicate with the programmer without needing `sudo`:
```bash
sudo cp linux/99-ezp2023.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

### Step 2: Choose Your Tool

#### Option A: Standalone Python Utility (`linux/ezp2023.py`)
No third-party packages required (uses Python's standard `ctypes` to link to system `libusb-1.0`):

```bash
# Auto-detect connected chip and look up in EZP2023+.Dat
./linux/ezp2023.py detect

# Read entire flash to a file
./linux/ezp2023.py read bios_backup.bin

# Verify flash content against a file
./linux/ezp2023.py verify bios_backup.bin

# Erase chip
./linux/ezp2023.py erase

# Blank check (ensure all bytes are 0xFF)
./linux/ezp2023.py blankcheck

# Write file to flash (automatically verifies after writing)
./linux/ezp2023.py write new_bios.bin
```

#### Option B: Native C Binary (`linux/ezp2023`)
Compiled for maximum performance:
```bash
cd linux
make
./ezp2023 detect
./ezp2023 read backup.bin 16777216
./ezp2023 erase
./ezp2023 write new_bios.bin
```

#### Option C: Existing Open-Source Tools
Because the protocol is compatible with the EZP family:
- **[Scriba](https://github.com/themactep/scriba)**:
  ```bash
  scriba -P ezp2019 -i              # Identify chip
  scriba -P ezp2019 -R backup.bin   # Read with verification
  scriba -P ezp2019 -W firmware.bin # Flash chip
  ```
- **[IMSProg](https://github.com/bigbigmdm/imsprog)**: Full GUI flash programmer for Linux with native EZP and database support.
