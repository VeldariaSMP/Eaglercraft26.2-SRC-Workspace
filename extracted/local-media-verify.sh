#!/usr/bin/env bash
set -euo pipefail

exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path, PurePosixPath


EXPECTED_OVERLAY = "2ba7e3376891c64f8bf57f3687e05b8dbe1971a75475b6825449e5e5f96d71f3"
OVERLAY_REL = "inputs/resource-overlay-normal.zip"
SOUNDS_REL = "inputs/sounds.epk"
SOUNDS_PIN_REL = "inputs/sounds.epk.sha256"
MUSIC_REL = "inputs/music.epk"
MUSIC_PIN_REL = "inputs/music.epk.sha256"
RESOURCES_REL = "inputs/resources"
GUI_REL = "eaglercraft-26.2-u1-patcher-gui.jar"
HEX = re.compile(r"^[0-9a-f]{64}$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_file(root: Path, relative: str) -> Path:
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"required regular file is missing: {relative}")
    return path


def read_overlay_external_records(overlay: Path) -> tuple[dict[str, dict[str, object]], str]:
    try:
        with zipfile.ZipFile(overlay) as archive:
            bad_member = archive.testzip()
            if bad_member is not None:
                raise ValueError(f"overlay ZIP CRC failure: {bad_member}")
            bundle = json.loads(archive.read("bundle.json"))
            operations = json.loads(archive.read("operations.json"))
            final_manifest = json.loads(archive.read("final-manifest.json"))
    except (OSError, zipfile.BadZipFile, KeyError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read overlay manifest: {exc}") from exc

    if bundle.get("release_status") != "local-test-only":
        raise ValueError("overlay is not marked local-test-only")
    final_records = {
        item.get("path"): item
        for item in final_manifest.get("records", [])
        if isinstance(item, dict)
    }
    external: dict[str, dict[str, object]] = {}
    for operation in operations.get("operations", []):
        if not isinstance(operation, dict):
            continue
        detail = operation.get("external")
        path = operation.get("path")
        if isinstance(detail, dict) and detail.get("required") is True:
            record = final_records.get(path)
            if not isinstance(path, str) or not isinstance(record, dict):
                raise ValueError("overlay external operation has no final-manifest record")
            if detail.get("sha256") != record.get("sha256") or detail.get("size") != record.get("size"):
                raise ValueError(f"external operation disagrees with final manifest: {path}")
            external[path] = {"sha256": record["sha256"], "size": record["size"]}
    if len(external) != 6:
        raise ValueError(f"overlay must define exactly six external files, found {len(external)}")
    return external, str(bundle.get("official_jar_sha256", ""))


def check_checksum_file(root: Path) -> dict[str, str]:
    sums_path = require_file(root, "SHA256SUMS")
    result: dict[str, str] = {}
    for line_number, line in enumerate(sums_path.read_text(encoding="utf-8").splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\r\n]+)", line)
        if not match:
            raise ValueError(f"invalid SHA256SUMS line {line_number}")
        expected, raw_relative = match.groups()
        relative = PurePosixPath(raw_relative)
        if relative.is_absolute() or any(part in ("", ".", "..") for part in relative.parts):
            raise ValueError(f"unsafe SHA256SUMS path on line {line_number}: {raw_relative}")
        normalized = relative.as_posix()
        if normalized in result:
            raise ValueError(f"duplicate SHA256SUMS entry: {normalized}")
        path = root.joinpath(*relative.parts)
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"SHA256SUMS target is missing or not a regular file: {normalized}")
        actual = sha256(path)
        if actual != expected:
            raise ValueError(f"SHA256SUMS mismatch for {normalized}: expected {expected}, got {actual}")
        result[normalized] = expected
    if not result:
        raise ValueError("SHA256SUMS is empty")
    return result


def verify(root: Path) -> dict[str, object]:
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise ValueError("kit path is not a directory")

    overlay = require_file(root, OVERLAY_REL)
    sounds = require_file(root, SOUNDS_REL)
    sounds_pin = require_file(root, SOUNDS_PIN_REL)
    music = require_file(root, MUSIC_REL)
    music_pin = require_file(root, MUSIC_PIN_REL)
    gui_launcher = require_file(root, GUI_REL)
    overlay_sha = sha256(overlay)
    if overlay_sha != EXPECTED_OVERLAY:
        raise ValueError(f"overlay SHA-256 mismatch: expected {EXPECTED_OVERLAY}, got {overlay_sha}")

    pin_text = sounds_pin.read_text(encoding="ascii").strip()
    if not HEX.fullmatch(pin_text):
        raise ValueError(f"{SOUNDS_PIN_REL} must contain one lowercase SHA-256")
    sounds_sha = sha256(sounds)
    if sounds_sha != pin_text:
        raise ValueError(f"sounds EPK SHA-256 mismatch: pin says {pin_text}, got {sounds_sha}")
    music_pin_text = music_pin.read_text(encoding="ascii").strip()
    if not HEX.fullmatch(music_pin_text):
        raise ValueError(f"{MUSIC_PIN_REL} must contain one lowercase SHA-256")
    music_sha = sha256(music)
    if music_sha != music_pin_text:
        raise ValueError(f"music EPK SHA-256 mismatch: pin says {music_pin_text}, got {music_sha}")

    external, official_jar_sha = read_overlay_external_records(overlay)
    resource_root = root / RESOURCES_REL
    if resource_root.is_symlink() or not resource_root.is_dir():
        raise ValueError(f"required resource directory is missing or not real: {RESOURCES_REL}")
    actual_paths: set[str] = set()
    for path in resource_root.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"symlink in external resource tree: {path.relative_to(root).as_posix()}")
        if path.is_file():
            actual_paths.add(path.relative_to(resource_root).as_posix())
    if actual_paths != set(external):
        missing = sorted(set(external) - actual_paths)
        extra = sorted(actual_paths - set(external))
        raise ValueError(f"external resource layout mismatch (missing={missing}, extra={extra})")

    external_receipts = []
    for relative, identity in sorted(external.items()):
        path = require_file(resource_root, relative)
        actual = sha256(path)
        if actual != identity["sha256"]:
            raise ValueError(f"external resource SHA-256 mismatch: {relative} (expected {identity['sha256']}, got {actual})")
        if path.stat().st_size != identity["size"]:
            raise ValueError(f"external resource size mismatch: {relative}")
        external_receipts.append({"path": f"{RESOURCES_REL}/{relative}", **identity})

    sums = check_checksum_file(root)
    required_sum_paths = {GUI_REL, OVERLAY_REL, SOUNDS_REL, SOUNDS_PIN_REL, MUSIC_REL, MUSIC_PIN_REL}
    required_sum_paths.update(f"{RESOURCES_REL}/{path}" for path in external)
    missing_sums = sorted(required_sum_paths - set(sums))
    if missing_sums:
        raise ValueError(f"SHA256SUMS omits required local media: {missing_sums}")

    # The package may contain patcher and Vineflower JARs, but no game JAR or mod profile inputs.
    names = [path.relative_to(root).as_posix() for path in root.rglob("*")]
    if any(path.is_symlink() for path in root.rglob("*")):
        raise ValueError("kit contains a symlink")
    root_zip_names = {Path(name).name for name in names if Path(name).parent == Path(".") and name.endswith(".zip")}
    if root_zip_names != {"source-patch-bundle.zip", "project-skeleton-v5-teavm-runtime-verified.zip"}:
        raise ValueError("kit root archives do not match the Normal source and project-skeleton inputs")
    if any(re.search(r"(?:minecraft|client).*26\.2.*\.jar$|(?:minecraft|client).*\.jar$", name, re.I) for name in names):
        raise ValueError("official Minecraft client JAR must not be distributed in this kit")
    if official_jar_sha and HEX.fullmatch(official_jar_sha):
        for path in root.rglob("*"):
            if path.is_file() and sha256(path) == official_jar_sha:
                raise ValueError(f"official Minecraft client bytes are present: {path.relative_to(root).as_posix()}")

    packaged_files = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path.relative_to(root).as_posix() != "SHA256SUMS"
    }
    unlisted = sorted(packaged_files - set(sums))
    if unlisted:
        raise ValueError(f"SHA256SUMS omits packaged files: {unlisted}")

    # This root-level GUI and adjacent inputs/ layout are the paths the
    # desktop GUI scans when launched from the kit.
    for relative in (GUI_REL, OVERLAY_REL, SOUNDS_REL, SOUNDS_PIN_REL, MUSIC_REL, MUSIC_PIN_REL):
        require_file(root, relative)
    return {
        "gate": "eaglercraft-26.2-local-media-kit-verification-v1",
        "status": "pass",
        "kit_directory": str(root),
        "gui_discovery_layout": "inputs/ plus inputs/resources/",
        "gui_launcher": {"path": GUI_REL, "sha256": sha256(gui_launcher)},
        "overlay": {"path": OVERLAY_REL, "sha256": overlay_sha},
        "sounds": {"path": SOUNDS_REL, "sha256": sounds_sha, "pin_path": SOUNDS_PIN_REL},
        "music": {"path": MUSIC_REL, "sha256": music_sha, "pin_path": MUSIC_PIN_REL},
        "external_resources": external_receipts,
        "sha256sums_entries_verified": len(sums),
        "distribution_boundary": {
            "content_profiles": "Normal only",
            "official_minecraft_client_jar": "excluded",
            "scope": "local-only kit integrity check; not a build, runtime, or release acceptance",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify the local-only Eaglercraft patcher media kit.")
    parser.add_argument("kit_dir", type=Path, help="packaged kit directory")
    parser.add_argument("--receipt", type=Path, help="write one machine-readable JSON receipt here")
    args = parser.parse_args()
    try:
        receipt = verify(args.kit_dir)
        status = 0
    except Exception as exc:
        receipt = {
            "gate": "eaglercraft-26.2-local-media-kit-verification-v1",
            "status": "fail",
            "kit_directory": str(args.kit_dir.absolute()),
            "error": str(exc),
        }
        status = 1
        print(f"ERROR: {exc}", file=sys.stderr)

    rendered = json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n"
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(rendered, encoding="utf-8")
    if status == 0:
        print("PASS: local media hashes, GUI discovery layout, SHA256SUMS, and no-official-client-JAR boundary")
    print(rendered, end="")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
PY
