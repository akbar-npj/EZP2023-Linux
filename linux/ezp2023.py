#!/usr/bin/env python3
"""
EZP2023+ / EZP2019 / EZP2019+ Linux Flash Programmer Utility
Reverse-engineered from Windows driver and EZP2023+.exe
Uses libusb-1.0 via ctypes (no third-party dependencies required).
"""

import sys
import os
import time
import struct
import argparse
import ctypes
from ctypes import byref, c_int, c_uint8, c_uint16, c_uint32, c_void_p, c_char_p, create_string_buffer

# USB Constants
EZP_VID = 0x1FC8
EZP_PIDS = [0x310B, 0x310C, 0x310D]

EP_DATA_OUT = 0x01
EP_CMD_OUT  = 0x02
EP_IN       = 0x82

PACKET_SIZE = 64
READ_CHUNK_SIZE = 256
USB_TIMEOUT_MS = 5000

# EZP Command Codes
CMD_ERASE   = 0x02
CMD_TRIGGER = 0x05
CMD_READ_EE = 0x05
CMD_READ    = 0x07
CMD_RESET   = 0x08
CMD_CONNECT = 0x09
CMD_STATUS  = 0x0A
CMD_WRITE   = 0x0B

# Protocols
PROTO_SPI       = 0x00
PROTO_QUAD_SPI  = 0x01
PROTO_I2C       = 0x02
PROTO_MICROWIRE = 0x03
PROTO_SPI_4BYTE = 0x06

class LibUSB:
    def __init__(self):
        try:
            self.lib = ctypes.CDLL("libusb-1.0.so.0")
        except OSError:
            try:
                self.lib = ctypes.CDLL("libusb-1.0.so")
            except OSError as e:
                raise RuntimeError("Could not find libusb-1.0. Install via: sudo apt install libusb-1.0-0 or sudo dnf install libusb1") from e

        self._setup_prototypes()
        self.ctx = c_void_p()
        ret = self.lib.libusb_init(byref(self.ctx))
        if ret != 0:
            raise RuntimeError(f"libusb_init failed with error {ret}")

    def _setup_prototypes(self):
        self.lib.libusb_init.argtypes = [ctypes.POINTER(c_void_p)]
        self.lib.libusb_init.restype = c_int

        self.lib.libusb_exit.argtypes = [c_void_p]
        self.lib.libusb_exit.restype = None

        self.lib.libusb_open_device_with_vid_pid.argtypes = [c_void_p, c_uint16, c_uint16]
        self.lib.libusb_open_device_with_vid_pid.restype = c_void_p

        self.lib.libusb_close.argtypes = [c_void_p]
        self.lib.libusb_close.restype = None

        self.lib.libusb_set_auto_detach_kernel_driver.argtypes = [c_void_p, c_int]
        self.lib.libusb_set_auto_detach_kernel_driver.restype = c_int

        self.lib.libusb_claim_interface.argtypes = [c_void_p, c_int]
        self.lib.libusb_claim_interface.restype = c_int

        self.lib.libusb_release_interface.argtypes = [c_void_p, c_int]
        self.lib.libusb_release_interface.restype = c_int

        self.lib.libusb_control_transfer.argtypes = [
            c_void_p, c_uint8, c_uint8, c_uint16, c_uint16,
            ctypes.POINTER(c_uint8), c_uint16, c_uint32
        ]
        self.lib.libusb_control_transfer.restype = c_int

        self.lib.libusb_bulk_transfer.argtypes = [
            c_void_p, c_uint8, ctypes.POINTER(c_uint8),
            c_int, ctypes.POINTER(c_int), c_uint32
        ]
        self.lib.libusb_bulk_transfer.restype = c_int

        self.lib.libusb_clear_halt.argtypes = [c_void_p, c_uint8]
        self.lib.libusb_clear_halt.restype = c_int

        self.lib.libusb_error_name.argtypes = [c_int]
        self.lib.libusb_error_name.restype = c_char_p

    def error_str(self, err_code):
        msg = self.lib.libusb_error_name(err_code)
        return msg.decode('utf-8', errors='replace') if msg else f"Error {err_code}"

    def close(self):
        if self.ctx:
            self.lib.libusb_exit(self.ctx)
            self.ctx = None


class EZP2023Device:
    def __init__(self, libusb_instance=None):
        self.usb = libusb_instance or LibUSB()
        self.handle = None
        self.matched_pid = None
        self.chip_info = None

    def open(self):
        for pid in EZP_PIDS:
            self.handle = self.usb.lib.libusb_open_device_with_vid_pid(self.usb.ctx, EZP_VID, pid)
            if self.handle:
                self.matched_pid = pid
                break

        if not self.handle:
            raise ConnectionError(
                f"EZP programmer not found (VID: {hex(EZP_VID)}, PIDs: {[hex(p) for p in EZP_PIDS]}).\n"
                "Please make sure device is connected and udev rules are installed."
            )

        # Enable auto detach of kernel drivers
        self.usb.lib.libusb_set_auto_detach_kernel_driver(self.handle, 1)

        # Handshake: The firmware expects string descriptor queries before bulk communications
        buf = (c_uint8 * 256)()
        self.usb.lib.libusb_control_transfer(
            self.handle, 0x80, 0x06, (0x03 << 8) | 0x01, 0x0409, buf, 256, 1000
        )
        self.usb.lib.libusb_control_transfer(
            self.handle, 0x80, 0x06, (0x03 << 8) | 0x02, 0x0409, buf, 256, 1000
        )

        ret = self.usb.lib.libusb_claim_interface(self.handle, 0)
        if ret != 0:
            self.usb.lib.libusb_close(self.handle)
            self.handle = None
            raise PermissionError(f"Failed to claim USB interface: {self.usb.error_str(ret)}. Check udev rules.")

    def close(self):
        if self.handle:
            try:
                self.reset()
            except Exception:
                pass
            self.usb.lib.libusb_release_interface(self.handle, 0)
            self.usb.lib.libusb_close(self.handle)
            self.handle = None

    def send_raw_command(self, cmd_packet, expect_response=True):
        if not self.handle:
            raise RuntimeError("Device not open")

        cmd_buf = (c_uint8 * PACKET_SIZE)(*cmd_packet)
        transferred = c_int()

        ret = self.usb.lib.libusb_bulk_transfer(
            self.handle, EP_CMD_OUT, cmd_buf, PACKET_SIZE, byref(transferred), USB_TIMEOUT_MS
        )
        if ret != 0 or transferred.value != PACKET_SIZE:
            self.usb.lib.libusb_clear_halt(self.handle, EP_CMD_OUT)
            raise IOError(f"Failed to send command to device: {self.usb.error_str(ret)}")

        if not expect_response:
            return None

        time.sleep(0.05)  # 50ms delay required by firmware

        resp_buf = (c_uint8 * PACKET_SIZE)()
        ret = self.usb.lib.libusb_bulk_transfer(
            self.handle, EP_IN, resp_buf, PACKET_SIZE, byref(transferred), USB_TIMEOUT_MS
        )
        if ret != 0 or transferred.value != PACKET_SIZE:
            self.usb.lib.libusb_clear_halt(self.handle, EP_IN)
            raise IOError(f"Failed to read response from device: {self.usb.error_str(ret)}")

        return bytes(resp_buf)

    def reset(self):
        packet = bytearray(PACKET_SIZE)
        packet[0] = 0x01
        packet[1] = CMD_RESET
        self.send_raw_command(packet, expect_response=False)

    def prepare_packet(self, cmd_id, size=0, pagesize=256, protocol=0, timeout=1000, chip_id=0, flags=0):
        packet = bytearray(PACKET_SIZE)
        packet[1] = cmd_id
        struct.pack_into("<H", packet, 2, protocol)
        struct.pack_into(">H", packet, 4, pagesize)
        struct.pack_into(">H", packet, 6, timeout)
        struct.pack_into(">I", packet, 8, size)
        struct.pack_into(">I", packet, 12, chip_id)
        packet[28] = (flags >> 24) & 0xFF
        return packet

    def probe(self):
        """Send CONNECT command twice to retrieve stable JEDEC ID."""
        pkt = self.prepare_packet(CMD_CONNECT)
        # First connect wakes lines
        self.send_raw_command(pkt, expect_response=True)
        time.sleep(0.05)
        # Second connect returns stable ID
        resp = self.send_raw_command(pkt, expect_response=True)
        mfr = resp[1]
        mem_type = resp[2]
        capacity = resp[3]
        jedec_id = (mfr << 16) | (mem_type << 8) | capacity
        return jedec_id, mfr, mem_type, capacity

    def poll_status(self, max_retries=1000, sleep_sec=0.05):
        pkt = bytearray(PACKET_SIZE)
        pkt[1] = CMD_STATUS
        polls = 0
        while polls < max_retries:
            polls += 1
            time.sleep(sleep_sec)
            resp = self.send_raw_command(pkt, expect_response=True)
            if resp and (resp[0] & 0x01) == 0:
                if polls > 1:
                    return True
        return False

    def trigger_transfer(self, address, read_mode=True):
        pkt = bytearray(PACKET_SIZE)
        pkt[1] = CMD_TRIGGER
        struct.pack_into(">I", pkt, 8, address)
        self.send_raw_command(pkt, expect_response=read_mode)

    def read_chip(self, total_size, pagesize=256, progress_cb=None):
        # Configure READ_SPI
        pkt = self.prepare_packet(CMD_READ, size=total_size, pagesize=pagesize)
        self.send_raw_command(pkt, expect_response=True)

        # Trigger from address 0
        self.trigger_transfer(0, read_mode=True)

        data = bytearray()
        chunk_buf = (c_uint8 * READ_CHUNK_SIZE)()
        transferred = c_int()

        while len(data) < total_size:
            req_size = min(READ_CHUNK_SIZE, total_size - len(data))
            # Always request full chunk to prevent endpoint buffer overflow
            ret = self.usb.lib.libusb_bulk_transfer(
                self.handle, EP_IN, chunk_buf, READ_CHUNK_SIZE, byref(transferred), USB_TIMEOUT_MS
            )
            if ret != 0:
                self.usb.lib.libusb_clear_halt(self.handle, EP_IN)
                raise IOError(f"Read error at offset {len(data)}: {self.usb.error_str(ret)}")

            data.extend(bytes(chunk_buf)[:req_size])
            if progress_cb:
                progress_cb(len(data), total_size)

        return bytes(data)

    def write_chip(self, data, pagesize=256, progress_cb=None):
        total_size = len(data)

        # Connect & configure READ_SPI
        pkt = self.prepare_packet(CMD_READ, size=total_size, pagesize=pagesize)
        self.send_raw_command(pkt, expect_response=True)

        # Trigger stream starting at address 0
        self.trigger_transfer(0, read_mode=False)

        offset = 0
        transferred = c_int()

        while offset < total_size:
            chunk = data[offset : offset + pagesize]
            chunk_buf = (c_uint8 * len(chunk))(*chunk)

            ret = self.usb.lib.libusb_bulk_transfer(
                self.handle, EP_DATA_OUT, chunk_buf, len(chunk), byref(transferred), USB_TIMEOUT_MS
            )
            if ret != 0 or transferred.value != len(chunk):
                self.usb.lib.libusb_clear_halt(self.handle, EP_DATA_OUT)
                raise IOError(f"Write error at offset {offset}: {self.usb.error_str(ret)}")

            offset += len(chunk)
            if progress_cb:
                progress_cb(offset, total_size)

        time.sleep(0.1)
        self.poll_status(max_retries=500, sleep_sec=0.02)

    def erase_chip(self):
        # Configure READ_SPI
        pkt = self.prepare_packet(CMD_READ)
        self.send_raw_command(pkt, expect_response=True)

        # Send Chip Erase packet
        erase_pkt = bytearray(PACKET_SIZE)
        erase_pkt[0] = 0x01
        erase_pkt[1] = CMD_ERASE
        erase_pkt[0x1A] = 0x80  # Full chip erase flag
        erase_pkt[0x1B] = 0x00

        self.send_raw_command(erase_pkt, expect_response=False)
        time.sleep(0.1)

        # Poll status until complete (chip erase can take up to 60s)
        if not self.poll_status(max_retries=1200, sleep_sec=0.05):
            raise TimeoutError("Chip erase timed out")


def print_progress(current, total):
    pct = (current / total) * 100.0 if total else 100.0
    bar_len = 40
    filled = int(bar_len * current // total) if total else bar_len
    bar = "=" * filled + "-" * (bar_len - filled)
    sys.stdout.write(f"\r[{bar}] {pct:5.1f}% ({current}/{total} bytes)")
    sys.stdout.flush()
    if current >= total:
        sys.stdout.write("\n")


def main():
    parser = argparse.ArgumentParser(description="EZP2023+ / EZP2019 Linux SPI Flash Programmer")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # detect
    subparsers.add_parser("detect", help="Probe and detect connected SPI chip")

    # read
    p_read = subparsers.add_parser("read", help="Read flash content to file")
    p_read.add_argument("filename", help="Output file path")
    p_read.add_argument("-s", "--size", type=int, help="Override size in bytes")

    # write
    p_write = subparsers.add_parser("write", help="Write flash content from file")
    p_write.add_argument("filename", help="Input file path to write")

    # erase
    subparsers.add_parser("erase", help="Erase entire flash chip")

    # blankcheck
    subparsers.add_parser("blankcheck", help="Verify that flash chip is completely erased (0xFF)")

    # verify
    p_verify = subparsers.add_parser("verify", help="Verify flash content against a file")
    p_verify.add_argument("filename", help="File to verify against")

    args = parser.parse_args()

    # Load database if present
    db = None
    db_path = os.path.join(os.path.dirname(__file__), "..", "EZP2023+ ver3.0", "EZP2023+.Dat")
    if os.path.exists(db_path):
        from ezp_db import ChipDatabase
        db = ChipDatabase(db_path)

    dev = EZP2023Device()
    try:
        dev.open()
        print(f"Connected to EZP programmer (PID: {hex(dev.matched_pid)})")

        jedec_id, mfr, mtype, cap = dev.probe()
        print(f"Detected JEDEC ID: 0x{jedec_id:06X} (Mfr: 0x{mfr:02X}, Type: 0x{mtype:02X}, Cap: 0x{cap:02X})")

        chip = db.find_by_id(jedec_id) if db else None
        if chip:
            print(f"Chip Identified: {chip.manufacturer} {chip.model} ({chip.chip_type}, Size: {chip.size // 1024} KB)")
            chip_size = chip.size
            pagesize = chip.pagesize
        else:
            print("Chip not found in database. Using standard fallback geometry.")
            # Calculate standard SPI NOR capacity: 2^(capacity_code)
            if 0x10 <= cap <= 0x1F:
                chip_size = 1 << cap
                print(f"Calculated capacity from JEDEC code: {chip_size // 1024} KB")
            else:
                chip_size = 16 * 1024 * 1024 # 16 MB default
            pagesize = 256

        if args.command == "detect":
            return

        elif args.command == "erase":
            print("Erasing chip... (this may take up to 60 seconds)")
            dev.erase_chip()
            print("Erase successful!")

        elif args.command == "blankcheck":
            print("Checking if chip is blank...")
            data = dev.read_chip(chip_size, pagesize, print_progress)
            non_ff = [i for i, b in enumerate(data) if b != 0xFF]
            if non_ff:
                print(f"Blank check FAILED! First non-blank byte at offset 0x{non_ff[0]:X}: 0x{data[non_ff[0]]:02X}")
                sys.exit(1)
            else:
                print("Blank check PASSED (all bytes are 0xFF)!")

        elif args.command == "read":
            size = args.size if args.size else chip_size
            print(f"Reading {size} bytes from flash...")
            data = dev.read_chip(size, pagesize, print_progress)
            with open(args.filename, "wb") as f:
                f.write(data)
            print(f"Saved {len(data)} bytes to {args.filename}")

        elif args.command == "write":
            with open(args.filename, "rb") as f:
                data = f.read()
            if len(data) > chip_size:
                print(f"Warning: File size ({len(data)} bytes) exceeds chip size ({chip_size} bytes). Truncating.")
                data = data[:chip_size]
            print(f"Writing {len(data)} bytes to flash...")
            dev.write_chip(data, pagesize, print_progress)
            print("Write complete! Verifying...")
            read_back = dev.read_chip(len(data), pagesize, print_progress)
            if read_back == data:
                print("Verification SUCCESSFUL!")
            else:
                print("Verification FAILED! Written data does not match.")
                sys.exit(1)

        elif args.command == "verify":
            with open(args.filename, "rb") as f:
                expected = f.read()
            print(f"Reading {len(expected)} bytes for verification...")
            actual = dev.read_chip(len(expected), pagesize, print_progress)
            if actual == expected:
                print("Verification PASSED: Data matches file exactly.")
            else:
                diffs = [i for i in range(len(expected)) if expected[i] != actual[i]]
                print(f"Verification FAILED: {len(diffs)} byte differences found. First at 0x{diffs[0]:X}.")
                sys.exit(1)

    finally:
        dev.close()

if __name__ == "__main__":
    try:
        main()
    except (ConnectionError, PermissionError, TimeoutError, IOError) as e:
        print(f"\n[!] Error: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nAborted by user.", file=sys.stderr)
        sys.exit(130)

