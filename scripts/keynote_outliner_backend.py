#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from zipfile import ZipFile

# Ensure the project root is importable when this script is launched directly.
REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from keynote_parser.codec import IWAFile
from keynote_parser.file_utils import file_reader


ID_SUFFIX_RE = re.compile(r"-(\d+)\.[^./]+$")
PARAGRAPH_TABLE_KEYS = (
    "tableParaStyle",
    "tableParaStarts",
    "tableParaData",
    "tableParaBidi",
)
SINGLE_RUN_TABLE_KEYS = ("tableCharStyle", "tableLanguage", "tableListStyle")


class BackendError(RuntimeError):
    pass


@dataclass
class SlideRecord:
    index: int
    slide_node_id: str
    slide_id: str
    slide_filename: str
    note_archive_id: str | None
    note_storage_id: str | None
    note_text: str
    thumbnail_data_id: str | None
    thumbnail_filename: str | None
    slide_dict: dict[str, Any] | None
    note_storage_object: dict[str, Any] | None


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def file_fingerprint(path: str) -> dict[str, Any]:
    hasher = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            hasher.update(chunk)
    stat = os.stat(path)
    return {
        "url": str(Path(path).resolve()),
        "sha256": hasher.hexdigest(),
        "mtime": float(stat.st_mtime),
        "size": int(stat.st_size),
    }


def load_bundle_entries(input_path: str) -> dict[str, bytes]:
    if not input_path.endswith(".key"):
        raise BackendError("Only .key bundle input is supported.")
    entries: dict[str, bytes] = {}
    for filename, handle in file_reader(input_path, progress=False):
        entries[filename] = handle.read()
    return entries


def write_bundle_entries(output_path: str, entries: dict[str, bytes]) -> None:
    output = Path(output_path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".tmp", dir=str(output.parent)
    )
    os.close(fd)
    try:
        with ZipFile(temp_path, "w") as archive:
            for filename in sorted(entries.keys()):
                archive.writestr(filename, entries[filename])
        os.replace(temp_path, output)
    finally:
        if os.path.exists(temp_path):
            os.remove(temp_path)


def decode_iwa(entries: dict[str, bytes], filename: str) -> dict[str, Any]:
    if filename not in entries:
        raise BackendError(f"Missing required file in bundle: {filename}")
    try:
        return IWAFile.from_buffer(entries[filename], filename).to_dict()
    except Exception as exc:
        raise BackendError(
            "Failed to decode iWork archive data. Ensure protobuf generated files exist "
            "under keynote_parser/versions/v14_4/generated and that dependencies are installed."
        ) from exc


def encode_iwa(iwa_dict: dict[str, Any]) -> bytes:
    try:
        return IWAFile.from_dict(iwa_dict).to_buffer()
    except Exception as exc:
        raise BackendError("Failed to encode modified iWork archive data.") from exc


def build_archive_lookup(
    iwa_dict: dict[str, Any],
) -> tuple[dict[str, dict[str, Any]], dict[str, list[tuple[str, dict[str, Any]]]]]:
    by_id: dict[str, dict[str, Any]] = {}
    by_type: dict[str, list[tuple[str, dict[str, Any]]]] = {}
    chunks = iwa_dict.get("chunks", [])
    for chunk in chunks:
        for archive in chunk.get("archives", []):
            archive_id = str(archive.get("header", {}).get("identifier", ""))
            objects = archive.get("objects") or []
            if archive_id and objects:
                by_id[archive_id] = archive
            for obj in objects:
                pbtype = obj.get("_pbtype")
                if pbtype:
                    by_type.setdefault(pbtype, []).append((archive_id, obj))
    return by_id, by_type


def get_first_object(archive: dict[str, Any]) -> dict[str, Any]:
    objects = archive.get("objects") or []
    if not objects:
        raise BackendError("Malformed archive: missing objects array.")
    first = objects[0]
    if not isinstance(first, dict):
        raise BackendError("Malformed archive: object is not a mapping.")
    return first


def build_data_id_map(entries: dict[str, bytes]) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for filename in entries.keys():
        if not filename.startswith("Data/"):
            continue
        match = ID_SUFFIX_RE.search(filename)
        if not match:
            continue
        data_id = match.group(1)
        mapping.setdefault(data_id, filename)
    return mapping


def find_show_archive(by_type: dict[str, list[tuple[str, dict[str, Any]]]]) -> dict[str, Any]:
    candidates = by_type.get("KN.ShowArchive")
    if not candidates:
        raise BackendError("Could not find KN.ShowArchive in Index/Document.iwa.")
    return candidates[0][1]


def collect_slide_records(
    entries: dict[str, bytes],
    include_mutable_refs: bool = False,
) -> list[SlideRecord]:
    document = decode_iwa(entries, "Index/Document.iwa")
    document_by_id, document_by_type = build_archive_lookup(document)
    show = find_show_archive(document_by_type)
    slide_node_refs = show.get("slideTree", {}).get("slides", [])
    if not isinstance(slide_node_refs, list):
        raise BackendError("Malformed show slide tree in Index/Document.iwa.")

    data_id_map = build_data_id_map(entries)
    rows: list[SlideRecord] = []
    for index, ref in enumerate(slide_node_refs, start=1):
        slide_node_id = str(ref.get("identifier", ""))
        if not slide_node_id:
            continue
        if slide_node_id not in document_by_id:
            continue
        node_obj = get_first_object(document_by_id[slide_node_id])
        slide_id = str(node_obj.get("slide", {}).get("identifier", ""))
        if not slide_id:
            continue
        thumb_id = None
        thumbs = node_obj.get("thumbnails") or []
        if isinstance(thumbs, list) and thumbs:
            thumb_id_value = thumbs[0].get("identifier")
            if thumb_id_value is not None:
                thumb_id = str(thumb_id_value)

        slide_filename = f"Index/Slide-{slide_id}.iwa"
        if slide_filename not in entries:
            # Skip template/unsupported slides without source archive.
            continue

        slide_dict = decode_iwa(entries, slide_filename)
        slide_by_id, slide_by_type = build_archive_lookup(slide_dict)
        slide_candidates = slide_by_type.get("KN.SlideArchive")
        if not slide_candidates:
            continue
        slide_obj = slide_candidates[0][1]
        note_archive_id = None
        note_storage_id = None
        note_text = ""
        note_storage_obj = None

        note_ref = slide_obj.get("note", {}).get("identifier")
        if note_ref is not None:
            note_archive_id = str(note_ref)
            note_archive = slide_by_id.get(note_archive_id)
            if note_archive:
                note_obj = get_first_object(note_archive)
                storage_ref = note_obj.get("containedStorage", {}).get("identifier")
                if storage_ref is not None:
                    note_storage_id = str(storage_ref)
                    storage_archive = slide_by_id.get(note_storage_id)
                    if storage_archive:
                        note_storage_obj = get_first_object(storage_archive)
                        text_list = note_storage_obj.get("text")
                        if isinstance(text_list, list) and text_list:
                            note_text = str(text_list[0])

        rows.append(
            SlideRecord(
                index=index,
                slide_node_id=slide_node_id,
                slide_id=slide_id,
                slide_filename=slide_filename,
                note_archive_id=note_archive_id,
                note_storage_id=note_storage_id,
                note_text=note_text,
                thumbnail_data_id=thumb_id,
                thumbnail_filename=data_id_map.get(thumb_id) if thumb_id else None,
                slide_dict=slide_dict if include_mutable_refs else None,
                note_storage_object=note_storage_obj if include_mutable_refs else None,
            )
        )
    return rows


def utf16_paragraph_offsets(text: str) -> tuple[list[int], int]:
    offsets = [0]
    utf16_index = 0
    for char in text:
        utf16_index += 2 if ord(char) > 0xFFFF else 1
        if char == "\n":
            offsets.append(utf16_index)
    return offsets, utf16_index


def clone_payload(entry: dict[str, Any]) -> dict[str, Any]:
    payload = copy.deepcopy(entry)
    payload.pop("characterIndex", None)
    return payload


def normalize_entries_to_offsets(
    storage: dict[str, Any], key: str, offsets: list[int], fallback_payload: dict[str, Any]
) -> None:
    table = storage.get(key)
    template_payload = fallback_payload
    if isinstance(table, dict):
        entries = table.get("entries")
        if isinstance(entries, list) and entries:
            first = entries[0]
            if isinstance(first, dict):
                template_payload = clone_payload(first)
    new_entries = []
    for offset in offsets:
        entry: dict[str, Any] = {"characterIndex": int(offset)}
        for payload_key, payload_value in template_payload.items():
            entry[payload_key] = copy.deepcopy(payload_value)
        new_entries.append(entry)
    storage[key] = {"entries": new_entries}


def clamp_table_indices(storage: dict[str, Any], max_index: int) -> None:
    for key, value in list(storage.items()):
        if key in PARAGRAPH_TABLE_KEYS:
            continue
        if key == "tableDictation":
            # Dictation segments become invalid as soon as edited text diverges.
            storage.pop(key, None)
            continue
        if not isinstance(value, dict):
            continue
        entries = value.get("entries")
        if not isinstance(entries, list) or not entries:
            continue
        if key in SINGLE_RUN_TABLE_KEYS:
            first = copy.deepcopy(entries[0]) if isinstance(entries[0], dict) else {}
            first["characterIndex"] = 0
            value["entries"] = [first]
            continue
        normalized_entries = []
        for raw in entries:
            if not isinstance(raw, dict):
                continue
            entry = copy.deepcopy(raw)
            index = int(entry.get("characterIndex", 0))
            index = max(0, min(index, max_index))
            entry["characterIndex"] = index
            normalized_entries.append(entry)
        if not normalized_entries:
            continue
        normalized_entries.sort(key=lambda item: int(item.get("characterIndex", 0)))
        if int(normalized_entries[0].get("characterIndex", 0)) != 0:
            baseline = copy.deepcopy(normalized_entries[0])
            baseline["characterIndex"] = 0
            normalized_entries.insert(0, baseline)
        value["entries"] = normalized_entries


def normalize_note_storage(storage: dict[str, Any], new_text: str) -> None:
    storage["text"] = [new_text]
    offsets, max_index = utf16_paragraph_offsets(new_text)
    para_payload_defaults = {"first": 0, "second": 0}

    normalize_entries_to_offsets(storage, "tableParaStyle", offsets, {})
    normalize_entries_to_offsets(storage, "tableParaStarts", offsets, para_payload_defaults)
    normalize_entries_to_offsets(storage, "tableParaData", offsets, para_payload_defaults)
    normalize_entries_to_offsets(storage, "tableParaBidi", offsets, para_payload_defaults)
    clamp_table_indices(storage, max_index)


def fingerprints_match(base: dict[str, Any], current: dict[str, Any]) -> bool:
    return (
        str(base.get("sha256", "")) == str(current.get("sha256", ""))
        and int(base.get("size", -1)) == int(current.get("size", -2))
    )


def extract_thumbnails(
    records: list[SlideRecord],
    entries: dict[str, bytes],
    cache_dir: str,
    file_hash: str,
) -> dict[str, str]:
    if not cache_dir:
        return {}
    root = Path(cache_dir).resolve() / file_hash
    root.mkdir(parents=True, exist_ok=True)
    output: dict[str, str] = {}
    for record in records:
        data_filename = record.thumbnail_filename
        if not data_filename or data_filename not in entries:
            continue
        extension = Path(data_filename).suffix or ".jpg"
        thumb_filename = f"thumb-{record.slide_node_id}{extension}"
        thumb_path = root / thumb_filename
        with open(thumb_path, "wb") as f:
            f.write(entries[data_filename])
        output[record.slide_node_id] = str(thumb_path)
    return output


def load_command(input_path: str, cache_dir: str) -> dict[str, Any]:
    entries = load_bundle_entries(input_path)
    fingerprint = file_fingerprint(input_path)
    records = collect_slide_records(entries, include_mutable_refs=False)
    thumbnail_paths = extract_thumbnails(
        records, entries, cache_dir=cache_dir, file_hash=fingerprint["sha256"]
    )
    slides = []
    for row in records:
        slides.append(
            {
                "index": row.index,
                "slideNodeId": row.slide_node_id,
                "slideId": row.slide_id,
                "noteArchiveId": row.note_archive_id,
                "noteStorageId": row.note_storage_id,
                "noteText": row.note_text,
                "thumbnailPath": thumbnail_paths.get(row.slide_node_id),
            }
        )
    return {"file": fingerprint, "slides": slides}


def load_state(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def find_state_row_map(state: dict[str, Any]) -> dict[str, dict[str, Any]]:
    rows = state.get("rows")
    if not isinstance(rows, list):
        raise BackendError("state-json is missing rows list.")
    mapping: dict[str, dict[str, Any]] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        slide_id = str(row.get("slideId", ""))
        if not slide_id:
            continue
        mapping[slide_id] = row
    return mapping


def build_conflicts(
    records_by_slide: dict[str, SlideRecord],
    state_rows: dict[str, dict[str, Any]],
    reason: str,
) -> list[dict[str, Any]]:
    conflicts = []
    for slide_id, state_row in state_rows.items():
        record = records_by_slide.get(slide_id)
        if not record:
            continue
        base = str(state_row.get("baseText", ""))
        local = str(state_row.get("editedText", ""))
        remote = record.note_text
        if local != base and remote != base and local != remote:
            conflicts.append(
                {
                    "slideId": slide_id,
                    "index": record.index,
                    "reason": reason,
                    "baseText": base,
                    "localText": local,
                    "remoteText": remote,
                }
            )
    return conflicts


def save_command(
    input_path: str,
    output_path: str,
    state_json_path: str,
    mode: str,
) -> dict[str, Any]:
    if mode not in {"strict", "merge", "overwrite"}:
        raise BackendError(f"Unsupported save mode: {mode}")

    entries = load_bundle_entries(input_path)
    state = load_state(state_json_path)
    state_rows = find_state_row_map(state)
    base_fingerprint = state.get("baseFile")
    if not isinstance(base_fingerprint, dict):
        raise BackendError("state-json is missing baseFile object.")

    current_fingerprint = file_fingerprint(input_path)
    records = collect_slide_records(entries, include_mutable_refs=True)
    records_by_slide = {record.slide_id: record for record in records}

    fingerprint_changed = not fingerprints_match(base_fingerprint, current_fingerprint)
    if mode == "strict" and fingerprint_changed:
        conflicts = build_conflicts(
            records_by_slide, state_rows, reason="external-and-local-changed"
        )
        return {
            "status": "conflict",
            "message": "The source Keynote file changed since it was loaded.",
            "file": current_fingerprint,
            "conflicts": conflicts,
        }

    unresolved_conflicts: list[dict[str, Any]] = []
    changed_rows = 0
    modified_slide_filenames: set[str] = set()
    for slide_id, state_row in state_rows.items():
        record = records_by_slide.get(slide_id)
        if not record:
            continue
        if not record.note_storage_object:
            continue
        base = str(state_row.get("baseText", ""))
        local = str(state_row.get("editedText", ""))
        remote = record.note_text
        target = remote

        if mode == "overwrite":
            target = local
        elif mode == "merge":
            if local == base:
                target = remote
            elif remote == base:
                target = local
            elif local == remote:
                target = remote
            else:
                unresolved_conflicts.append(
                    {
                        "slideId": slide_id,
                        "index": record.index,
                        "reason": "merge-required",
                        "baseText": base,
                        "localText": local,
                        "remoteText": remote,
                    }
                )
                continue
        else:
            target = local

        if target != remote:
            normalize_note_storage(record.note_storage_object, target)
            record.note_text = target
            changed_rows += 1
            modified_slide_filenames.add(record.slide_filename)

    if unresolved_conflicts:
        return {
            "status": "conflict",
            "message": "Automatic merge could not resolve one or more slide notes.",
            "file": current_fingerprint,
            "conflicts": unresolved_conflicts,
        }

    for record in records:
        if record.slide_filename in modified_slide_filenames and record.slide_dict:
            entries[record.slide_filename] = encode_iwa(record.slide_dict)

    output_resolved = str(Path(output_path).resolve())
    input_resolved = str(Path(input_path).resolve())
    should_write = output_resolved != input_resolved or changed_rows > 0
    if should_write:
        write_bundle_entries(output_path, entries)
        saved_fingerprint = file_fingerprint(output_path)
    else:
        saved_fingerprint = current_fingerprint

    return {
        "status": "saved",
        "file": saved_fingerprint,
        "savedRows": changed_rows,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Keynote Outliner backend.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    load_parser = subparsers.add_parser("load", help="Load deck notes/thumbnails.")
    load_parser.add_argument("--input", required=True, help="Path to .key file")
    load_parser.add_argument("--cache-dir", required=True, help="Thumbnail cache directory")

    save_parser = subparsers.add_parser("save", help="Save edited deck notes.")
    save_parser.add_argument("--input", required=True, help="Source .key file")
    save_parser.add_argument("--output", required=True, help="Output .key file")
    save_parser.add_argument(
        "--state-json", required=True, help="Path to save-state JSON file"
    )
    save_parser.add_argument(
        "--mode",
        required=True,
        choices=["strict", "merge", "overwrite"],
        help="Save conflict mode",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.command == "load":
            payload = load_command(args.input, args.cache_dir)
        elif args.command == "save":
            payload = save_command(args.input, args.output, args.state_json, args.mode)
        else:
            raise BackendError(f"Unknown command: {args.command}")
        emit(payload)
        return 0
    except Exception as exc:  # pragma: no cover - CLI entry handling
        emit(
            {
                "status": "error",
                "error": str(exc),
            }
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
