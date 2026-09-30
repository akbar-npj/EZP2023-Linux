#!/usr/bin/env python3
"""
EZP2023+ Chip Database Parser and Lookup Utility
Extracts chip definitions from EZP2023+.Dat (68-byte binary records).
"""

import struct
import sys
import os
import json

RECORD_SIZE = 68
RECORD_FORMAT = "<48sIIHHHHI"

class ChipRecord:
    def __init__(self, raw_data):
        (raw_name, self.chip_id, self.size, self.pagesize, 
         self.proto_enum_cfg, self.timeout_retries, 
         self.unknown_delay, self.flags) = struct.unpack(RECORD_FORMAT, raw_data)
        
        name_str = raw_name.decode("gb18030", errors="replace").split("\x00")[0]
        parts = name_str.split(",")
        if len(parts) == 3:
            self.chip_type = parts[0].strip()
            self.manufacturer = parts[1].strip()
            self.model = parts[2].strip()
        else:
            self.chip_type = "UNKNOWN"
            self.manufacturer = "UNKNOWN"
            self.model = name_str.strip()

    def to_dict(self):
        return {
            "type": self.chip_type,
            "manufacturer": self.manufacturer,
            "model": self.model,
            "chip_id": f"0x{self.chip_id:06X}",
            "size": self.size,
            "pagesize": self.pagesize,
            "proto": f"0x{self.proto_enum_cfg:04X}",
            "timeout": self.timeout_retries,
            "flags": f"0x{self.flags:08X}"
        }

    def __repr__(self):
        return f"<Chip {self.manufacturer} {self.model} (ID: 0x{self.chip_id:06X}, Size: {self.size} bytes)>"

class ChipDatabase:
    def __init__(self, dat_path):
        self.chips = []
        self.by_id = {}
        if not os.path.exists(dat_path):
            raise FileNotFoundError(f"Database file not found: {dat_path}")
        with open(dat_path, "rb") as f:
            data = f.read()
        num_records = len(data) // RECORD_SIZE
        for i in range(num_records):
            rec = ChipRecord(data[i * RECORD_SIZE : (i + 1) * RECORD_SIZE])
            self.chips.append(rec)
            # Index by JEDEC ID (only 24-bit part matters for SPI)
            jedec_id = rec.chip_id & 0xFFFFFF
            if jedec_id not in self.by_id:
                self.by_id[jedec_id] = rec

    def find_by_id(self, chip_id):
        return self.by_id.get(chip_id & 0xFFFFFF, None)

    def search(self, query):
        q = query.lower()
        return [c for c in self.chips if q in c.model.lower() or q in c.manufacturer.lower()]

if __name__ == "__main__":
    dat_file = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "EZP2023+ ver3.0", "EZP2023+.Dat")
    db = ChipDatabase(dat_file)
    print(f"Loaded {len(db.chips)} chips from {dat_file}")
    if len(sys.argv) > 2:
        q = sys.argv[2]
        matches = db.search(q)
        print(f"Search results for '{q}' ({len(matches)} matches):")
        for m in matches[:10]:
            print(f"  {m.chip_type} | {m.manufacturer:12} | {m.model:20} | ID: 0x{m.chip_id:06X} | Size: {m.size // 1024} KB")
