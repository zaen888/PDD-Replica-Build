#!/usr/bin/env python3
"""Portable static sanity checks; this does not compile Objective-C or validate runtime hooks."""
from pathlib import Path
import plistlib, re, sys
root = Path(__file__).resolve().parent
src = (root / "Tweak.xm").read_text(encoding="utf-8")
makefile = (root / "Makefile").read_text(encoding="utf-8")
control = (root / "control").read_text(encoding="utf-8")
checks = {
    "Logos JSONSerialization hook exists": "%hook NSJSONSerialization" in src and "JSONObjectWithData:" in src,
    "original parser is called": "id parsed = %orig;" in src,
    "capture is gated by enabled state": "PDDCaptureEnabled()" in src,
    "goods ID is filename-sanitized": "PDDSafeGoodsID" in src and "allowed.invertedSet" in src,
    "per-call NSData snapshot exists": "NSData *snapshot = [data copy];" in src,
    "atomic file write exists": "NSDataWritingAtomic" in src,
    "capture queue is serial": "dispatch_queue_create(\"com.local.pddreplica.capture\", DISPATCH_QUEUE_SERIAL)" in src,
    "ZIP uses CRC32 and central directory": "crc32(" in src and "0x02014b50" in src and "0x06054b50" in src,
    "ZIP export is backgrounded": "dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)" in src,
    "export ZIP name is collision-resistant": "NSUUID.UUID.UUIDString" in src,
    "Theos links zlib": "PDDReplicaShell_LIBRARIES = z" in makefile,
    "package metadata is v0.4": "Version: 0.4.0" in control,
}
# Theos filter plists commonly use OpenStep syntax, not XML/binary plist syntax.
filter_text = (root / "PDDReplicaShell.plist").read_text(encoding="utf-8")
checks["filter plist targets Pinduoduo bundle"] = (
    "Filter" in filter_text and "Bundles" in filter_text and
    "com.xunmeng.pinduoduo" in filter_text
)
failed = False
for label, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'}  {label}")
    failed |= not ok
print(f"\n{sum(checks.values())}/{len(checks)} static checks passed.")
print("NOTE: static checks do not prove Theos compilation, injection, or correct product capture on a device.")
sys.exit(1 if failed else 0)
