#!/usr/bin/env python3
"""Fetch the 26.2 OGG objects from Mojang's pinned official asset index.

Objects are verified before cache reuse and after download. Successful writes
are atomic and never replace an existing path. Re-running the command resumes
from the verified cache. --max-objects supports a small network smoke test.

Full fetch, then metadata-only archive rebuild (paths can be changed):
  python3 patcher/release-inputs/fetch_audio_objects.py \
    --objects audio-cache/objects --save-index audio-cache/indexes/32.json \
    --output audio-cache/fetch-receipt
  python3 patcher/release-inputs/epk_rebuild.py \
    --index audio-cache/indexes/32.json --objects audio-cache/objects \
    --output audio-cache/epk-rebuild
"""

from __future__ import annotations

import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from threading import Lock
import time
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener


INDEX_SHA1 = "981aab8147520cdc1f0d4a84f46c161929021fee"
INDEX_URL = f"https://piston-meta.mojang.com/v1/packages/{INDEX_SHA1}/32.json"
OBJECT_ORIGIN = "https://resources.download.minecraft.net"
INDEX_MAX_BYTES = 2_000_000
OBJECT_MAX_BYTES = 12 * 1024 * 1024
EXPECTED_OGG_COUNT = 4871
SHA1_RE = re.compile(r"[0-9a-f]{40}\Z")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        raise ValueError(f"official asset URL redirected: HTTP {code}")


OPENER = build_opener(NoRedirect)


class RateLimiter:
    def __init__(self, per_second: float):
        self.interval = 1.0 / per_second
        self.next_start = 0.0
        self.lock = Lock()

    def wait(self, deadline: float) -> None:
        with self.lock:
            now = time.monotonic()
            start = max(now, self.next_start)
            self.next_start = start + self.interval
        if start >= deadline:
            raise TimeoutError("run deadline reached before network request")
        if start > now:
            time.sleep(start - now)


def reject_symlinks(path: Path) -> None:
    for item in (path.absolute(), *path.absolute().parents):
        if item.is_symlink():
            raise ValueError(f"symlink in path: {item}")


def checked_directory(path: Path) -> Path:
    path = path.absolute()
    reject_symlinks(path)
    path.mkdir(parents=True, exist_ok=True)
    reject_symlinks(path)
    if not path.is_dir():
        raise ValueError(f"not a directory: {path}")
    return path


def read_bounded(path: Path, limit: int) -> bytes:
    reject_symlinks(path)
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"file exceeds size limit: {path}")
    return data


def fetch_index() -> bytes:
    request = Request(INDEX_URL, headers={"Accept-Encoding": "identity",
                                          "User-Agent": "eaglercraft-26.2-u1-audio-fetch/1"})
    with OPENER.open(request, timeout=30) as response:
        if response.status != 200 or response.geturl() != INDEX_URL:
            raise ValueError(f"official index request failed: HTTP {response.status}")
        data = response.read(INDEX_MAX_BYTES + 1)
    if len(data) > INDEX_MAX_BYTES:
        raise ValueError("official index exceeds size limit")
    return data


def load_index(path: Path | None) -> tuple[bytes, list[dict]]:
    raw = read_bounded(path, INDEX_MAX_BYTES) if path is not None else fetch_index()
    actual = hashlib.sha1(raw).hexdigest()
    if actual != INDEX_SHA1:
        raise ValueError(f"official index SHA-1 mismatch: {actual}")
    document = json.loads(raw)
    objects = document.get("objects")
    if not isinstance(objects, dict):
        raise ValueError("official index lacks objects map")
    entries = []
    for name, entry in objects.items():
        if not (name.startswith("minecraft/sounds/") and name.endswith(".ogg")):
            continue
        if not isinstance(entry, dict) or set(entry) != {"hash", "size"}:
            raise ValueError(f"invalid official index entry: {name}")
        sha1, size = entry["hash"], entry["size"]
        if not isinstance(sha1, str) or not SHA1_RE.fullmatch(sha1):
            raise ValueError(f"invalid object SHA-1 in index: {name}")
        if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= OBJECT_MAX_BYTES:
            raise ValueError(f"invalid object size in index: {name}")
        entries.append({"name": name, "sha1": sha1, "size": size})
    entries.sort(key=lambda item: item["name"])
    if len(entries) != EXPECTED_OGG_COUNT or len({item["sha1"] for item in entries}) != len(entries):
        raise ValueError(f"official OGG set is not the expected {EXPECTED_OGG_COUNT} unique objects")
    return raw, entries


def save_verified_index(path: Path, data: bytes) -> str:
    """Retain a pinned index with an atomic, no-overwrite promotion."""
    if hashlib.sha1(data).hexdigest() != INDEX_SHA1:
        raise ValueError("refusing to save unverified official index")
    path = path.absolute()
    reject_symlinks(path)
    checked_directory(path.parent)
    if path.exists():
        existing = read_bounded(path, INDEX_MAX_BYTES)
        if hashlib.sha1(existing).hexdigest() != INDEX_SHA1 or existing != data:
            raise ValueError(f"existing index is invalid; preserved without overwrite: {path}")
        return "verified-existing"
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".index-", dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, path)
            return "saved"
        except FileExistsError:
            existing = read_bounded(path, INDEX_MAX_BYTES)
            if hashlib.sha1(existing).hexdigest() != INDEX_SHA1 or existing != data:
                raise ValueError(f"index appeared but failed verification: {path}")
            return "verified-race"
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def object_path(root: Path, entry: dict) -> Path:
    sha1 = entry["sha1"]
    return root / sha1[:2] / sha1


def cached_valid(path: Path, entry: dict) -> bool:
    reject_symlinks(path)
    if not path.exists():
        return False
    if not path.is_file():
        raise ValueError(f"cache object path is not a regular file: {path}")
    data = read_bounded(path, entry["size"])
    if len(data) != entry["size"] or hashlib.sha1(data).hexdigest() != entry["sha1"]:
        raise ValueError(f"existing cache object is invalid; preserved without overwrite: {path}")
    return True


def fetch_one(entry: dict, root: Path, limiter: RateLimiter, deadline: float) -> dict:
    path = object_path(root, entry)
    if cached_valid(path, entry):
        return {**entry, "status": "cached"}
    checked_directory(path.parent)
    url = f"{OBJECT_ORIGIN}/{entry['sha1'][:2]}/{entry['sha1']}"
    last_error = None
    for attempt in range(1, 4):
        temporary = None
        try:
            limiter.wait(deadline)
            request = Request(url, headers={"Accept-Encoding": "identity",
                                            "User-Agent": "eaglercraft-26.2-u1-audio-fetch/1"})
            with OPENER.open(request, timeout=30) as response:
                if response.status != 200 or response.geturl() != url:
                    raise ValueError(f"object request failed: HTTP {response.status}")
                header_size = response.headers.get("Content-Length")
                if header_size is not None and int(header_size) != entry["size"]:
                    raise ValueError("official object Content-Length mismatch")
                with tempfile.NamedTemporaryFile(prefix=".fetch-", dir=path.parent, delete=False) as stream:
                    temporary = Path(stream.name)
                    total = 0
                    sha1 = hashlib.sha1()
                    while True:
                        if time.monotonic() >= deadline:
                            raise TimeoutError("run deadline reached during download")
                        chunk = response.read(min(65536, entry["size"] + 1 - total))
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > entry["size"]:
                            raise ValueError("official object exceeds declared size")
                        sha1.update(chunk)
                        stream.write(chunk)
                    stream.flush()
                    os.fsync(stream.fileno())
            if total != entry["size"] or sha1.hexdigest() != entry["sha1"]:
                raise ValueError("downloaded object size/SHA-1 mismatch")
            try:
                os.link(temporary, path)
                status = "downloaded"
            except FileExistsError:
                if not cached_valid(path, entry):
                    raise ValueError("object appeared but failed verification")
                status = "cached-race"
            return {**entry, "status": status, "url": url, "attempts": attempt}
        except (HTTPError, URLError, OSError, ValueError, TimeoutError) as error:
            last_error = error
            if isinstance(error, (ValueError, TimeoutError)) or (isinstance(error, HTTPError) and error.code < 500 and error.code != 429):
                break
            if time.monotonic() >= deadline:
                break
            time.sleep(min(2 ** (attempt - 1), max(0, deadline - time.monotonic())))
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    return {**entry, "status": "failed", "url": url, "attempts": attempt,
            "error": str(last_error)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--objects", type=Path, required=True, help="explicit object cache directory")
    parser.add_argument("--output", type=Path, required=True, help="receipt directory")
    parser.add_argument("--index", type=Path, help="verified cached index; omit to download it over HTTPS")
    parser.add_argument("--save-index", type=Path,
                        help="retain the verified index for the EPK rebuilder; never overwrite existing data")
    parser.add_argument("--offline", action="store_true", help="verify cached objects without network")
    parser.add_argument("--max-objects", type=int, default=0, help="first N paths for a bounded smoke test")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--requests-per-second", type=float, default=2.0)
    parser.add_argument("--max-seconds", type=int, default=3600)
    args = parser.parse_args()
    started = time.monotonic()
    receipt = {"status": "precheck-failed", "started_unix": int(time.time())}
    try:
        if args.offline and args.index is None:
            raise ValueError("--offline requires a cached --index")
        if args.max_objects < 0 or not 1 <= args.workers <= 8 or not 0 < args.requests_per_second <= 8:
            raise ValueError("invalid object/concurrency/rate limit")
        if args.max_seconds <= 0:
            raise ValueError("--max-seconds must be positive")
        output = checked_directory(args.output)
        root = checked_directory(args.objects)
        index_bytes, all_entries = load_index(args.index)
        index_save_status = save_verified_index(args.save_index, index_bytes) if args.save_index else None
        selected = all_entries[:args.max_objects] if args.max_objects else all_entries
        receipt.update({"status": "running", "index_sha1": INDEX_SHA1,
                        "index_source": str(args.index.resolve()) if args.index else INDEX_URL,
                        "saved_index": str(args.save_index.absolute()) if args.save_index else None,
                        "index_save_status": index_save_status,
                        "object_source": OBJECT_ORIGIN,
                        "objects_root": str(root), "total_indexed_ogg": len(all_entries),
                        "selected_objects": len(selected), "offline": args.offline,
                        "workers": 0 if args.offline else args.workers,
                        "requests_per_second": 0 if args.offline else args.requests_per_second})
        deadline = started + args.max_seconds
        journal = output / "objects.jsonl"
        counts = {"cached": 0, "downloaded": 0, "cached-race": 0, "failed": 0, "missing": 0}
        errors = []
        pending = []
        with journal.open("w", encoding="utf-8") as log:
            def record(row: dict) -> None:
                counts[row["status"]] += 1
                if row["status"] in ("failed", "missing"):
                    errors.append({key: row.get(key) for key in ("name", "sha1", "error")})
                log.write(json.dumps(row, sort_keys=True) + "\n")
                log.flush()

            for entry in selected:
                try:
                    if cached_valid(object_path(root, entry), entry):
                        record({**entry, "status": "cached"})
                    elif args.offline:
                        record({**entry, "status": "missing", "error": "not present in verified cache"})
                    else:
                        pending.append(entry)
                except (OSError, ValueError) as error:
                    record({**entry, "status": "failed", "error": str(error)})
            if pending:
                limiter = RateLimiter(args.requests_per_second)
                with ThreadPoolExecutor(max_workers=args.workers) as pool:
                    iterator = iter(pending)
                    active = set()
                    while True:
                        while len(active) < args.workers * 2 and time.monotonic() < deadline:
                            try:
                                entry = next(iterator)
                            except StopIteration:
                                break
                            active.add(pool.submit(fetch_one, entry, root, limiter, deadline))
                        if not active:
                            break
                        done, active = wait(active, timeout=max(0, deadline - time.monotonic()),
                                            return_when=FIRST_COMPLETED)
                        for future in done:
                            record(future.result())
                        if time.monotonic() >= deadline:
                            for future in active:
                                future.cancel()
                            break
                    for future in active:
                        if future.done() and not future.cancelled():
                            record(future.result())
        completed = sum(counts.values())
        receipt.update({"counts": counts, "processed_objects": completed,
                        "remaining_objects": len(selected) - completed,
                        "failure_examples": errors[:20], "failure_count": len(errors)})
        deadline_failure = any("deadline" in (error.get("error") or "") for error in errors)
        if deadline_failure or (completed != len(selected) and time.monotonic() >= deadline):
            receipt["status"] = "time-limit"
        elif counts["failed"] or counts["missing"]:
            receipt["status"] = "incomplete"
        elif completed != len(selected):
            receipt["status"] = "time-limit"
        else:
            receipt["status"] = "complete" if len(selected) == len(all_entries) else "partial-subset"
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError, URLError, HTTPError) as error:
        receipt["error"] = str(error)
    receipt["elapsed_seconds"] = round(time.monotonic() - started, 3)
    output = args.output.absolute()
    if output.is_dir():
        (output / "final.json").write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print(json.dumps(receipt, sort_keys=True))
    return 0 if receipt["status"] in ("complete", "partial-subset") else 2


if __name__ == "__main__":
    sys.exit(main())
