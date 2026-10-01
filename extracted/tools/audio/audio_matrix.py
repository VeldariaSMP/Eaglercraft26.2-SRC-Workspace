#!/usr/bin/env python3
"""Bounded, resumable comparison of pinned audio EPK members with official assets.

The journal contains one result per member. Repeating the command skips completed
members after validating the same EPK, index, and FFmpeg identities. No source
asset or EPK is modified. A final JSON receipt is written even on timeout.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import zlib


ROOT = Path(__file__).resolve().parents[2]
INPUTS = ROOT / "output/local-media-patcher-kit-20260929-r22-normal/inputs"
PINS = {
    "sounds": "94bc8bfcf4132c52c6d5f61f3f92e50532a6fad1f5bc901ee25a462db8ba4fc6",
    "music": "f01cdaf62a9686438998b11ffed5407a1b890e14960c63f71b57401d02216a4e",
}
INDEX_SHA1 = "981aab8147520cdc1f0d4a84f46c161929021fee"


def digest(data: bytes, algorithm: str = "sha256") -> str:
    return hashlib.new(algorithm, data).hexdigest()


def parse_epk(path: Path, expected_sha: str):
    raw = path.read_bytes()
    actual_sha = digest(raw)
    if actual_sha != expected_sha:
        raise ValueError(f"EPK SHA-256 mismatch: {path}: {actual_sha}")
    if not raw.startswith(b"EAGPKG$$") or not raw.endswith(b":::YEE:>"):
        raise ValueError(f"invalid EPK envelope: {path}")
    offset = 8
    size = raw[offset]
    offset += 1
    version = raw[offset:offset + size]
    offset += size
    size = raw[offset]
    offset += 1 + size
    comment_size = int.from_bytes(raw[offset:offset + 2], "big")
    offset += 2 + comment_size + 8
    declared = int.from_bytes(raw[offset:offset + 4], "big")
    offset += 4
    compression = raw[offset:offset + 1]
    offset += 1
    if version != b"ver2.0" or compression not in (b"G", b"0"):
        raise ValueError(f"unsupported EPK version/compression: {version!r}/{compression!r}")
    records = gzip.decompress(raw[offset:-8]) if compression == b"G" else raw[offset:-8]
    cursor = 0
    count = 0
    members = []
    ended = False
    while cursor + 4 <= len(records):
        tag = records[cursor:cursor + 4]
        cursor += 4
        if tag == b"END$":
            ended = True
            break
        if tag not in (b"HEAD", b"FILE"):
            raise ValueError(f"unknown EPK tag {tag!r} at {cursor - 4}")
        name_size = records[cursor]
        cursor += 1
        name = records[cursor:cursor + name_size].decode("utf-8")
        cursor += name_size
        data_size = int.from_bytes(records[cursor:cursor + 4], "big")
        cursor += 4
        if tag == b"FILE":
            crc = int.from_bytes(records[cursor:cursor + 4], "big")
            cursor += 4
            data = records[cursor:cursor + data_size - 5]
            cursor += data_size - 5
            if (zlib.crc32(data) & 0xffffffff) != crc:
                raise ValueError(f"EPK member CRC mismatch: {name}")
            if records[cursor:cursor + 1] != b":":
                raise ValueError(f"EPK member terminator mismatch: {name}")
            cursor += 1
            members.append((name, data))
        else:
            cursor += data_size
        if records[cursor:cursor + 1] != b">":
            raise ValueError(f"EPK record terminator mismatch: {name}")
        cursor += 1
        count += 1
    if not ended or cursor != len(records) or count != declared:
        raise ValueError(f"EPK record count/framing mismatch: {path}: {count}/{declared}")
    return members


def normalized_ogg(data: bytes) -> tuple[bytes, int]:
    mutable = bytearray(data)
    pos = 0
    pages = 0
    while pos < len(mutable):
        if mutable[pos:pos + 4] != b"OggS" or pos + 27 > len(mutable):
            raise ValueError(f"invalid Ogg page at offset {pos}")
        segments = mutable[pos + 26]
        header_end = pos + 27 + segments
        if header_end > len(mutable):
            raise ValueError("truncated Ogg segment table")
        end = header_end + sum(mutable[pos + 27:header_end])
        if end > len(mutable):
            raise ValueError("truncated Ogg page data")
        mutable[pos + 14:pos + 18] = b"\0" * 4
        mutable[pos + 22:pos + 26] = b"\0" * 4
        pos = end
        pages += 1
    return bytes(mutable), pages


def summary(rows: dict[str, dict], expected: int) -> dict:
    counts = {}
    exceptions = []
    for key, row in sorted(rows.items()):
        status = row["status"]
        counts[status] = counts.get(status, 0) + 1
        if status not in ("exact", "transcode-normalized-match"):
            exceptions.append({"member": key, **row})
    return {"expected_members": expected, "processed_members": len(rows),
            "remaining_members": expected - len(rows), "counts": counts,
            "exceptions": exceptions}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sounds", type=Path, default=INPUTS / "sounds.epk")
    parser.add_argument("--music", type=Path, default=INPUTS / "music.epk")
    parser.add_argument("--index", type=Path, default=ROOT / "assets/indexes/32.json")
    parser.add_argument("--objects", type=Path, default=ROOT / "assets/objects")
    parser.add_argument("--output", type=Path, default=ROOT / "output/audio-matrix-20260929")
    parser.add_argument("--max-seconds", type=int, default=1200)
    parser.add_argument("--retry-mismatches", action="store_true",
                        help="recheck prior mismatches after changing a class recipe")
    args = parser.parse_args()
    started = time.monotonic()
    deadline = started + args.max_seconds
    args.output.mkdir(parents=True, exist_ok=True)
    final_path = args.output / "final.json"
    journal = args.output / "members.jsonl"
    meta_path = args.output / "identity.json"
    receipt = {"status": "precheck-failed", "inputs": {}, "elapsed_seconds": 0}
    try:
        index_bytes = args.index.read_bytes()
        if digest(index_bytes, "sha1") != INDEX_SHA1:
            raise ValueError("official asset index SHA-1 mismatch")
        indexed = json.loads(index_bytes)["objects"]
        epks = {name: parse_epk(getattr(args, name), pin) for name, pin in PINS.items()}
        ffmpeg = subprocess.run(["ffmpeg", "-version"], capture_output=True, text=True,
                                check=True, timeout=10).stdout.splitlines()[0]
        if not ffmpeg.startswith("ffmpeg version 6.1.1"):
            raise ValueError(f"expected FFmpeg 6.1.1, found {ffmpeg}")
        identity = {"epk_sha256": PINS, "index_sha1": INDEX_SHA1,
                    "ffmpeg": ffmpeg, "objects": str(args.objects.resolve())}
        if meta_path.exists():
            if json.loads(meta_path.read_text()) != identity:
                raise ValueError("output journal belongs to different inputs/toolchain")
        else:
            if journal.exists():
                raise ValueError("journal has no identity file")
            meta_path.write_text(json.dumps(identity, sort_keys=True, indent=2) + "\n")
        rows = {}
        prior_attempts = 0
        if journal.exists():
            for line in journal.read_text().splitlines():
                row = json.loads(line)
                key = row.pop("member")
                rows[key] = row
                prior_attempts += 1
        expected = sum(map(len, epks.values()))
        receipt["inputs"] = identity
        receipt["archive_members"] = {key: len(value) for key, value in epks.items()}
        all_keys = {f"{group}/{name}" for group, members in epks.items() for name, _ in members}
        if len(all_keys) != expected or not set(rows).issubset(all_keys):
            raise ValueError("duplicate EPK member or unexpected journal row")
        indexed_ogg = {f"assets/{name}" for name in indexed
                       if name.startswith("minecraft/sounds/") and name.endswith(".ogg")}
        epk_ogg = {name for members in epks.values() for name, _ in members}
        if epk_ogg != indexed_ogg:
            raise ValueError(f"EPK/index audio coverage mismatch: {len(epk_ogg)} vs {len(indexed_ogg)}")
        receipt["index_ogg_count"] = len(indexed_ogg)
        receipt["full_index_coverage"] = True
        with journal.open("a") as output, tempfile.TemporaryDirectory(prefix="transcode-", dir=args.output) as temp_name:
            temp = Path(temp_name)
            for group, members in epks.items():
                for name, epk_data in members:
                    key = f"{group}/{name}"
                    if key in rows and not (args.retry_mismatches and rows[key]["status"] == "transcode-mismatch"):
                        continue
                    if time.monotonic() >= deadline:
                        break
                    row = {"epk_size": len(epk_data), "epk_sha256": digest(epk_data)}
                    try:
                        if not name.startswith("assets/"):
                            raise ValueError("EPK member path lacks assets/ prefix")
                        object_name = name.removeprefix("assets/")
                        entry = indexed.get(object_name)
                        if entry is None:
                            raise ValueError("member absent from official index")
                        sha1 = entry["hash"]
                        path = args.objects / sha1[:2] / sha1
                        official = path.read_bytes()
                        if len(official) != entry["size"] or digest(official, "sha1") != sha1:
                            raise ValueError("official object size/SHA-1 mismatch")
                        row.update({"official_sha1": sha1, "official_size": len(official)})
                        if official == epk_data:
                            row["status"] = "exact"
                        else:
                            source = temp / "source.ogg"
                            target = temp / "converted.ogg"
                            source.write_bytes(official)
                            if group == "sounds":
                                settings = ["-c:a", "libvorbis", "-ar", "22050", "-ac", "1", "-q:a", "0"]
                            else:
                                bitrate = "16k" if name.startswith("assets/minecraft/sounds/records/") else "12k"
                                settings = ["-c:a", "libopus", "-ac", "1", "-b:a", bitrate]
                            row["ffmpeg_settings"] = settings
                            command = ["ffmpeg", "-v", "error", "-y", "-i", str(source),
                                       *settings, str(target)]
                            remaining = max(1, min(120, int(deadline - time.monotonic())))
                            run = subprocess.run(command, capture_output=True, timeout=remaining)
                            if run.returncode:
                                row.update(status="ffmpeg-failed", error=run.stderr.decode(errors="replace")[-500:])
                            else:
                                generated = target.read_bytes()
                                target.unlink()
                                normalized_target, target_pages = normalized_ogg(generated)
                                normalized_epk, epk_pages = normalized_ogg(epk_data)
                                row.update({"generated_size": len(generated),
                                            "generated_pages": target_pages, "epk_pages": epk_pages,
                                            "generated_normalized_sha256": digest(normalized_target),
                                            "epk_normalized_sha256": digest(normalized_epk)})
                                row["status"] = ("transcode-normalized-match"
                                                 if normalized_target == normalized_epk
                                                 else "transcode-mismatch")
                    except subprocess.TimeoutExpired:
                        row.update(status="ffmpeg-timeout", error="per-member deadline reached")
                    except (OSError, ValueError, KeyError) as error:
                        row.update(status="error", error=str(error))
                    rows[key] = row
                    output.write(json.dumps({"member": key, **row}, sort_keys=True) + "\n")
                    output.flush()
                if time.monotonic() >= deadline:
                    break
        receipt.update(summary(rows, expected))
        with journal.open() as attempts:
            receipt["journal_attempts"] = sum(1 for _ in attempts)
        receipt["prior_attempts"] = prior_attempts
        receipt["status"] = "complete" if len(rows) == expected else "time-limit"
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        receipt["error"] = str(error)
    receipt["elapsed_seconds"] = round(time.monotonic() - started, 3)
    final_path.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print(json.dumps({key: receipt.get(key) for key in
                      ("status", "expected_members", "processed_members", "remaining_members", "counts", "error")},
                     sort_keys=True))
    return 0 if receipt["status"] == "complete" else 2


if __name__ == "__main__":
    sys.exit(main())
