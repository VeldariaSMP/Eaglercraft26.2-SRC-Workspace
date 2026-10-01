#!/usr/bin/env python3
"""Rebuild pinned audio EPKs from official indexed objects and pinned metadata.

The default path reads no original EPK. The optional --from-epks audit mode
reads source EPKs only for framing metadata, hashes, and Ogg stream serials.
Audio payloads written to candidates always come from the official asset
objects, directly or through FFmpeg. Source EPK payloads are never copied.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import zlib

from audio_matrix import INDEX_SHA1, PINS, normalized_ogg


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_INPUTS = ROOT / "output/local-media-patcher-kit-20260929-r22-normal/inputs"
DEFAULT_INDEX = ROOT / "assets/indexes/32.json"
DEFAULT_OBJECTS = ROOT / "assets/objects"
DEFAULT_OUTPUT = ROOT / "output/epk-rebuild-20260930"
DEFAULT_METADATA = Path(__file__).with_name("audio-epk-metadata-26.2.json")
METADATA_FORMAT = "eagler-26.2-audio-epk-metadata-v1"
METADATA_SHA256 = "69cc6cfeccf235d71ffb307aa9150c784690c48f510be3036dd42f7e3050ce98"
EPK_END = b":::YEE:>"
MEMBER_COUNTS = {"sounds": 4779, "music": 92}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def ogg_metadata(data: bytes) -> dict:
    """Summarize Ogg page serials without retaining its audio bytes."""
    pos = 0
    serials: list[str] = []
    pages = 0
    while pos < len(data):
        if data[pos:pos + 4] != b"OggS" or pos + 27 > len(data):
            raise ValueError(f"invalid Ogg page at byte {pos}")
        segment_count = data[pos + 26]
        table_end = pos + 27 + segment_count
        if table_end > len(data):
            raise ValueError("truncated Ogg segment table")
        page_end = table_end + sum(data[pos + 27:table_end])
        if page_end > len(data):
            raise ValueError("truncated Ogg page body")
        serial = data[pos + 14:pos + 18].hex()
        if not serials or serials[-1] != serial:
            serials.append(serial)
        pos = page_end
        pages += 1
    if not pages:
        raise ValueError("empty Ogg member")
    return {"pages": pages, "serials": serials}


def ogg_crc(page: bytearray) -> int:
    crc = 0
    for value in page:
        crc ^= value << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


def set_ogg_serial_and_crc(data: bytes, serial_hex: list[str]) -> bytes:
    """Apply pinned serial IDs and recompute Ogg's non-zlib page CRCs."""
    out = bytearray(data)
    pos = 0
    page_no = 0
    serial_index = 0
    active_serial = None
    while pos < len(out):
        if out[pos:pos + 4] != b"OggS" or pos + 27 > len(out):
            raise ValueError(f"invalid regenerated Ogg page at byte {pos}")
        if page_no == 0 or out[pos + 5] & 0x02:
            if serial_index >= len(serial_hex):
                raise ValueError("more logical streams than pinned serial metadata")
            active_serial = bytes.fromhex(serial_hex[serial_index])
            serial_index += 1
        out[pos + 14:pos + 18] = active_serial
        out[pos + 22:pos + 26] = b"\0" * 4
        segment_count = out[pos + 26]
        table_end = pos + 27 + segment_count
        if table_end > len(out):
            raise ValueError("truncated regenerated Ogg segment table")
        page_end = table_end + sum(out[pos + 27:table_end])
        if page_end > len(out):
            raise ValueError("truncated regenerated Ogg page body")
        out[pos + 22:pos + 26] = ogg_crc(out[pos:page_end]).to_bytes(4, "little")
        pos = page_end
        page_no += 1
    if serial_index != len(serial_hex):
        raise ValueError("fewer logical streams than pinned serial metadata")
    return bytes(out)


def read_epk_metadata(path: Path, expected_sha: str) -> dict:
    raw = path.read_bytes()
    actual_sha = sha256(raw)
    if actual_sha != expected_sha:
        raise ValueError(f"pinned input SHA-256 mismatch for {path}: {actual_sha}")
    if not raw.startswith(b"EAGPKG$$") or not raw.endswith(EPK_END):
        raise ValueError(f"invalid EPK envelope: {path}")
    offset = 8
    version_len = raw[offset]
    offset += 1
    version = raw[offset:offset + version_len]
    offset += version_len
    pack_len = raw[offset]
    offset += 1
    pack_name = raw[offset:offset + pack_len]
    offset += pack_len
    comment_len = int.from_bytes(raw[offset:offset + 2], "big")
    offset += 2
    comment = raw[offset:offset + comment_len]
    offset += comment_len + 8
    declared_records = int.from_bytes(raw[offset:offset + 4], "big")
    offset += 4
    compression = raw[offset:offset + 1]
    offset += 1
    header_prefix = raw[:offset]
    if version != b"ver2.0" or compression not in (b"G", b"0"):
        raise ValueError(f"unsupported EPK version/compression: {version!r}/{compression!r}")
    records = gzip.decompress(raw[offset:-len(EPK_END)]) if compression == b"G" else raw[offset:-len(EPK_END)]
    records_sha = sha256(records)
    cursor = 0
    rows = []
    ended = False
    while cursor + 4 <= len(records):
        tag = records[cursor:cursor + 4]
        cursor += 4
        if tag == b"END$":
            ended = True
            break
        if tag not in (b"HEAD", b"FILE"):
            raise ValueError(f"unknown EPK record {tag!r} at {cursor - 4}")
        name_len = records[cursor]
        cursor += 1
        name = records[cursor:cursor + name_len].decode("utf-8")
        cursor += name_len
        size = int.from_bytes(records[cursor:cursor + 4], "big")
        cursor += 4
        if tag == b"HEAD":
            payload = records[cursor:cursor + size]
            cursor += size
            rows.append({"tag": "HEAD", "name": name, "head_hex": payload.hex(), "size": size})
        else:
            crc = int.from_bytes(records[cursor:cursor + 4], "big")
            cursor += 4
            payload_size = size - 5
            if payload_size < 0:
                raise ValueError(f"invalid EPK FILE size for {name}")
            payload = records[cursor:cursor + payload_size]
            cursor += payload_size
            if records[cursor:cursor + 1] != b":":
                raise ValueError(f"EPK FILE terminator mismatch for {name}")
            cursor += 1
            if (zlib.crc32(payload) & 0xFFFFFFFF) != crc:
                raise ValueError(f"pinned EPK member CRC mismatch for {name}")
            normalized, _ = normalized_ogg(payload)
            rows.append({"tag": "FILE", "name": name, "size": len(payload),
                         "sha256": sha256(payload), "normalized_sha256": sha256(normalized),
                         "serials": ogg_metadata(payload)["serials"]})
        if records[cursor:cursor + 1] != b">":
            raise ValueError(f"EPK record terminator mismatch for {name}")
        cursor += 1
    if not ended or cursor != len(records) or len(rows) != declared_records:
        raise ValueError(f"EPK record framing/count mismatch for {path}")
    return {"archive_sha256": actual_sha, "version": version.decode(),
            "pack_name": pack_name.decode(), "comment": comment.decode(errors="replace"),
            "compression": compression.decode(), "header_prefix_hex": header_prefix.hex(), "records_sha256": records_sha,
            "declared_records": declared_records, "rows": rows}


def load_pinned_metadata(path: Path) -> dict:
    raw = path.read_bytes()
    if sha256(raw) != METADATA_SHA256:
        raise ValueError(f"audio metadata SHA-256 mismatch: {sha256(raw)}")
    document = json.loads(raw)
    if document.get("format") != METADATA_FORMAT or set(document) != {"format", "groups"}:
        raise ValueError("audio metadata format mismatch")
    groups = document["groups"]
    if not isinstance(groups, dict) or set(groups) != set(PINS):
        raise ValueError("audio metadata group set mismatch")
    for group, metadata in groups.items():
        if metadata.get("archive_sha256") != PINS[group] or metadata.get("version") != "ver2.0":
            raise ValueError(f"audio metadata archive identity mismatch: {group}")
        if metadata.get("compression") != ("G" if group == "sounds" else "0"):
            raise ValueError(f"audio metadata compression mismatch: {group}")
        header = bytes.fromhex(metadata["header_prefix_hex"])
        if not header.startswith(b"EAGPKG$$") or header[-1:] != metadata["compression"].encode():
            raise ValueError(f"audio metadata header mismatch: {group}")
        rows = metadata.get("rows")
        if not isinstance(rows, list) or len(rows) != metadata.get("declared_records"):
            raise ValueError(f"audio metadata record count mismatch: {group}")
        names = set()
        files = 0
        for row in rows:
            name = row["name"]
            if row["tag"] == "HEAD":
                head = bytes.fromhex(row["head_hex"])
                if len(head) != row["size"] or len(head) > 4096:
                    raise ValueError(f"audio metadata HEAD size mismatch: {group}/{name}")
            elif row["tag"] == "FILE":
                if not name.startswith("assets/minecraft/sounds/") or not name.endswith(".ogg") or name in names:
                    raise ValueError(f"audio metadata member path invalid/duplicate: {group}/{name}")
                if row["size"] <= 0 or len(row["sha256"]) != 64 or len(row["normalized_sha256"]) != 64:
                    raise ValueError(f"audio metadata member identity invalid: {group}/{name}")
                if not row["serials"] or any(len(bytes.fromhex(serial)) != 4 for serial in row["serials"]):
                    raise ValueError(f"audio metadata Ogg serial invalid: {group}/{name}")
                names.add(name)
                files += 1
            else:
                raise ValueError(f"audio metadata record tag invalid: {group}/{name}")
        if files != MEMBER_COUNTS[group]:
            raise ValueError(f"audio metadata member count mismatch: {group}: {files}")
    return groups


def frame_records(rows: list[dict], audio: dict[str, bytes]) -> bytes:
    parts = []
    for row in rows:
        tag = row["tag"].encode("ascii")
        name = row["name"].encode("utf-8")
        if row["tag"] == "HEAD":
            payload = bytes.fromhex(row["head_hex"])
            size = len(payload)
            record = tag + bytes([len(name)]) + name + size.to_bytes(4, "big") + payload + b">"
        else:
            payload = audio[row["name"]]
            size = len(payload) + 5
            record = (tag + bytes([len(name)]) + name + size.to_bytes(4, "big")
                      + (zlib.crc32(payload) & 0xFFFFFFFF).to_bytes(4, "big")
                      + payload + b":>")
        parts.append(record)
    parts.append(b"END$")
    return b"".join(parts)


def transcode(source: Path, target: Path, group: str, name: str) -> list[str]:
    if group == "sounds":
        settings = ["-c:a", "libvorbis", "-ar", "22050", "-ac", "1", "-q:a", "0"]
    else:
        bitrate = "16k" if name.startswith("assets/minecraft/sounds/records/") else "12k"
        settings = ["-c:a", "libopus", "-ac", "1", "-b:a", bitrate]
    run = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(source), *settings, str(target)],
                         capture_output=True, timeout=120)
    if run.returncode:
        raise RuntimeError(run.stderr.decode(errors="replace")[-500:])
    return settings


def rebuild_group(group: str, metadata: dict, index: dict, objects: Path,
                  out_dir: Path, deadline: float) -> dict:
    audio_rows = [row for row in metadata["rows"] if row["tag"] == "FILE"]
    generated: dict[str, bytes] = {}
    counts: dict[str, int] = {}
    recipe_counts: dict[str, int] = {}
    rows_log = out_dir / f"{group}-members.jsonl"
    with tempfile.TemporaryDirectory(prefix=f"{group}-transcode-", dir=out_dir) as temp_name:
        temp = Path(temp_name)
        with rows_log.open("w", encoding="utf-8") as log:
            for i, row in enumerate(audio_rows, 1):
                if time.monotonic() >= deadline:
                    break
                name = row["name"]
                if not name.startswith("assets/"):
                    raise ValueError(f"unexpected EPK path {name}")
                object_key = name.removeprefix("assets/")
                entry = index.get(object_key)
                if entry is None:
                    raise ValueError(f"missing official index entry: {object_key}")
                object_sha1 = entry["hash"]
                source = objects / object_sha1[:2] / object_sha1
                official = source.read_bytes()
                if len(official) != entry["size"] or hashlib.sha1(official).hexdigest() != object_sha1:
                    raise ValueError(f"official object failed SHA-1/size verification: {object_key}")
                if sha256(official) == row["sha256"]:
                    candidate = official
                    status = "official-object-exact"
                    settings = []
                else:
                    target = temp / "candidate.ogg"
                    settings = transcode(source, target, group, name)
                    candidate = target.read_bytes()
                    target.unlink()
                    normalized, _ = normalized_ogg(candidate)
                    status = ("transcode-normalized-match" if sha256(normalized) == row["normalized_sha256"]
                              else "transcode-mismatch")
                candidate = set_ogg_serial_and_crc(candidate, row["serials"])
                if sha256(candidate) != row["sha256"]:
                    raise ValueError(f"reconstructed member differs from pinned identity: {name}")
                counts[status] = counts.get(status, 0) + 1
                if settings:
                    recipe_key = " ".join(settings)
                    recipe_counts[recipe_key] = recipe_counts.get(recipe_key, 0) + 1
                generated[name] = candidate
                log.write(json.dumps({"member": name, "status": status,
                                      "official_sha1": object_sha1, "official_size": len(official),
                                      "output_size": len(candidate), "output_sha256": sha256(candidate),
                                      "expected_sha256": row["sha256"],
                                      "expected_normalized_sha256": row["normalized_sha256"],
                                      "output_normalized_sha256": sha256(normalized_ogg(candidate)[0]),
                                      "serials": row["serials"], "ffmpeg_settings": settings},
                                     sort_keys=True) + "\n")
                if i % 250 == 0:
                    log.flush()
    processed = len(generated)
    result = {"group": group, "expected_members": len(audio_rows), "processed_members": processed,
              "remaining_members": len(audio_rows) - processed, "member_status_counts": counts,
              "recipes": recipe_counts}
    if processed != len(audio_rows):
        result["status"] = "time-limit"
        return result
    record_stream = frame_records(metadata["rows"], generated)
    header = bytes.fromhex(metadata["header_prefix_hex"])
    compressed_records = (gzip.compress(record_stream, compresslevel=9, mtime=0)
                          if metadata["compression"] == "G" else record_stream)
    candidate_archive = header + compressed_records + EPK_END
    candidate_path = out_dir / f"{group}.epk"
    candidate_path.write_bytes(candidate_archive)
    result.update({"status": "exact" if sha256(candidate_archive) == metadata["archive_sha256"] else "mismatch",
                   "expected_archive_sha256": metadata["archive_sha256"],
                   "candidate_archive_sha256": sha256(candidate_archive),
                   "candidate_size": len(candidate_archive),
                   "expected_size": None,
                   "expected_records_sha256": metadata["records_sha256"],
                   "candidate_records_sha256": sha256(record_stream),
                   "records_exact": sha256(record_stream) == metadata["records_sha256"],
                   "candidate_path": str(candidate_path)})
    result["expected_size"] = len(candidate_archive) if result["status"] == "exact" else None
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sounds", type=Path, default=DEFAULT_INPUTS / "sounds.epk")
    parser.add_argument("--music", type=Path, default=DEFAULT_INPUTS / "music.epk")
    parser.add_argument("--index", type=Path, default=DEFAULT_INDEX)
    parser.add_argument("--objects", type=Path, default=DEFAULT_OBJECTS)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--groups", choices=("sounds", "music", "both"), default="both")
    parser.add_argument("--max-seconds", type=int, default=1800)
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA,
                        help="pinned metadata JSON; default mode reads no source EPK")
    parser.add_argument("--from-epks", action="store_true",
                        help="audit source EPKs instead of loading the pinned metadata JSON")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    deadline = started + args.max_seconds
    receipt = {"status": "precheck-failed", "started_unix": int(time.time()), "groups": {}}
    try:
        index_bytes = args.index.read_bytes()
        index_sha1 = hashlib.sha1(index_bytes).hexdigest()
        if index_sha1 != INDEX_SHA1:
            raise ValueError(f"official asset index SHA-1 mismatch: {index_sha1}")
        index = json.loads(index_bytes)["objects"]
        ffmpeg = subprocess.run(["ffmpeg", "-version"], capture_output=True, text=True,
                                check=True, timeout=10).stdout.splitlines()[0]
        if not ffmpeg.startswith("ffmpeg version 6.1.1"):
            raise ValueError(f"audio_matrix.py recipe expects FFmpeg 6.1.1, found {ffmpeg}")
        requested = ("sounds", "music") if args.groups == "both" else (args.groups,)
        if args.from_epks:
            metadata = {group: read_epk_metadata(getattr(args, group), PINS[group]) for group in requested}
        else:
            pinned = load_pinned_metadata(args.metadata)
            metadata = {group: pinned[group] for group in requested}
        # Save compact metadata only: no member audio payload bytes are emitted.
        (args.output / "pinned-metadata.json").write_text(json.dumps({
            group: {key: value for key, value in data.items() if key != "rows"}
            | {"rows": [{key: value for key, value in row.items() if key != "head_hex"}
                       | ({"head_hex": row["head_hex"]} if row["tag"] == "HEAD" else {})
                       for row in data["rows"]]}
            for group, data in metadata.items()}, sort_keys=True, indent=2) + "\n")
        receipt.update({"status": "running", "index_sha1": index_sha1, "ffmpeg": ffmpeg,
                        "official_objects_root": str(args.objects.resolve()),
                        "pinned_epk_sha256": {group: PINS[group] for group in requested},
                        "metadata_mode": "source-epk-audit" if args.from_epks else "pinned-metadata-only",
                        "metadata_sha256": None if args.from_epks else METADATA_SHA256,
                        "method": "official object bytes or FFmpeg recipe; metadata supplies framing, hashes, and Ogg serials"})
        for group in requested:
            receipt["groups"][group] = rebuild_group(group, metadata[group], index, args.objects,
                                                      args.output, deadline)
            if receipt["groups"][group]["status"] == "time-limit":
                break
        if any(row.get("status") == "time-limit" for row in receipt["groups"].values()):
            receipt["status"] = "time-limit"
        elif all(row.get("status") == "exact" for row in receipt["groups"].values()) and len(receipt["groups"]) == len(requested):
            receipt["status"] = "exact"
        else:
            receipt["status"] = "complete-with-mismatch"
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        receipt["error"] = str(error)
    receipt["elapsed_seconds"] = round(time.monotonic() - started, 3)
    (args.output / "final.json").write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"status": receipt["status"], "groups": receipt["groups"],
                      "error": receipt.get("error"), "elapsed_seconds": receipt["elapsed_seconds"]},
                     sort_keys=True))
    return 0 if receipt["status"] == "exact" else 2


if __name__ == "__main__":
    raise SystemExit(main())
