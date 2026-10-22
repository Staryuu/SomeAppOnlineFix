#!/usr/bin/env python3
"""Carry forward ARM64 Steam signatures when only relative addresses change."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ROOT / "signatures/macos.arm64"
CLIENT = Path.home() / "Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"
VARIANTS = ("steam_client_signed-2_osx", "steam_client_signed_osx", "steam_client_osx")


def client_build(client):
    manifests = [client.parent / "package" / f"{name}.manifest" for name in VARIANTS]
    manifests = [path for path in manifests if path.exists()]
    if not manifests:
        raise ValueError("No Steam build manifest beside the client")
    manifest = max(manifests, key=lambda path: path.stat().st_mtime_ns)
    raw = manifest.read_bytes()
    if not 0 < len(raw) <= 1024 * 1024 or b"\0" in raw:
        raise ValueError(f"Invalid manifest: {manifest}")
    versions = re.findall(rb'"version"\s*"([^"]*)"', raw)
    if len(versions) != 1 or not re.fullmatch(rb"[1-9][0-9]{0,9}", versions[0]) or int(versions[0]) > 0xffffffff:
        raise ValueError(f"Invalid Steam build: {manifest}")
    return int(versions[0])


def text_section(data):
    """Return the ARM64 __TEXT,__text bytes and preferred virtual address."""
    if data[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        wide = data[:4] == b"\xca\xfe\xba\xbf"
        count = struct.unpack_from(">I", data, 4)[0]
        stride = 32 if wide else 20
        if not 0 < count <= (len(data) - 8) // stride:
            raise ValueError("Invalid universal Mach-O header")
        slices = []
        for index in range(count):
            offset = 8 + index * stride
            cpu = struct.unpack_from(">I", data, offset)[0]
            start, size = struct.unpack_from(">QQ" if wide else ">II", data, offset + 8)
            if start > len(data) or size > len(data) - start:
                raise ValueError("Mach-O slice outside file")
            if cpu == 0x0100000c:
                slices.append(data[start:start + size])
        if len(slices) != 1:
            raise ValueError("Expected exactly one ARM64 slice")
        data = slices[0]
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe" or struct.unpack_from("<I", data, 4)[0] != 0x0100000c:
        raise ValueError("Expected an ARM64 Mach-O file")
    count, size = struct.unpack_from("<II", data, 16)
    offset, end = 32, 32 + size
    if end > len(data):
        raise ValueError("Truncated Mach-O load commands")
    sections = []
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Truncated load command")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > end:
            raise ValueError("Invalid load command size")
        if command == 0x19:
            if size < 72:
                raise ValueError("Truncated segment")
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            if nsects > (size - 72) // 80:
                raise ValueError("Truncated section table")
            for index in range(nsects):
                section = offset + 72 + index * 80
                name, segment, address, length, start = struct.unpack_from("<16s16sQQI", data, section)
                if name.rstrip(b"\0") == b"__text" and segment.rstrip(b"\0") == b"__TEXT":
                    if not length or start > len(data) or length > len(data) - start or address % 4:
                        raise ValueError("Invalid code section")
                    sections.append((data[start:start + length], address))
        offset += size
    if len(sections) != 1:
        raise ValueError("Expected exactly one __TEXT,__text section")
    return sections[0]


def portable_pattern(pattern):
    tokens = pattern.split()
    if not tokens or len(tokens) > 4096 or len(tokens) % 4 or any(not re.fullmatch(r"[0-9a-fA-F]{2}|\?\?", token) for token in tokens):
        raise ValueError("Expected aligned hex bytes or ?? (maximum 4096 bytes)")
    for offset in range(0, len(tokens), 4):
        instruction = tokens[offset:offset + 4]
        if "??" in instruction:
            continue
        word = int.from_bytes(bytes.fromhex(" ".join(instruction)), "little")
        # B/BL and ADR/ADRP encode addresses that move between builds.
        if word & 0x7c000000 == 0x14000000 or word & 0x9f000000 in (0x10000000, 0x90000000):
            tokens[offset:offset + 4] = ["??"] * 4
    if sum(token != "??" for token in tokens) < 16:
        raise ValueError("Too few fixed bytes after masking relative addresses")
    return " ".join(tokens).upper()


def unique_match(code, pattern):
    expression = b"".join(b"." if token == "??" else re.escape(bytes.fromhex(token)) for token in pattern.split())
    # Lookahead includes overlapping matches; runtime accepts only 4-byte alignment.
    hits = (hit.start() for hit in re.finditer(b"(?=" + expression + b")", code, re.DOTALL) if hit.start() % 4 == 0)
    first = next(hits, None)
    if first is None or next(hits, None) is not None:
        raise ValueError("Signature is missing or ambiguous; manual analysis required")
    return first


def update(profile, code, address, build):
    if profile.get("arch") != "arm64" or profile.get("platform") != "macos" or profile.get("schema_version") != 3:
        raise ValueError("Expected a schema 3 macOS ARM64 reference profile")
    signatures = profile.get("signatures")
    if not isinstance(signatures, list) or not signatures:
        raise ValueError("Reference profile has no signatures")
    result = dict(profile)
    result.update(steam_build=build, steam_build_date=datetime.fromtimestamp(build, timezone.utc).date().isoformat(),
                  profile_version=profile["profile_version"] + 1, signatures=[])
    names, targets = set(), set()
    for entry in signatures:
        name = entry["name"]
        if not isinstance(name, str) or not name or name in names:
            raise ValueError("Invalid or duplicate target name")
        pattern = portable_pattern(entry["aob_hex"])
        try:
            hit = unique_match(code, pattern)
        except ValueError as error:
            raise ValueError(f"{name}: {error}") from error
        adjustment = entry.get("match_offset", 0)
        if type(adjustment) is not int or adjustment < 0 or adjustment > hit or adjustment % 4:
            raise ValueError(f"{name}: invalid match_offset")
        target = hit - adjustment
        if target in targets:
            raise ValueError(f"{name}: duplicate target address")
        names.add(name)
        targets.add(target)
        result["signatures"].append(dict(entry, aob_hex=pattern))
        print(f"  {name}: 0x{address + target:x} (unique)")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog="Cannot recover functions after structural/ABI changes. Validate gameplay separately.")
    parser.add_argument("--client", type=Path, default=CLIENT, help="Steam steamclient.dylib (universal or ARM64)")
    parser.add_argument("--reference", type=Path, help="Known compatible JSON profile; default: highest bundled build")
    parser.add_argument("--output", type=Path, help="New JSON path; default: signatures/macos.arm64/<build>.json")
    args = parser.parse_args()
    try:
        reference = args.reference or max(PROFILES.glob("[0-9]*.json"), key=lambda path: int(path.stem))
        raw = args.client.read_bytes()
        build = client_build(args.client)
        code, address = text_section(raw)
        print(f"Steam build {build}; reference: {reference.name}")
        print(f"Client SHA256: {hashlib.sha256(raw).hexdigest()}")
        result = update(json.loads(reference.read_text()), code, address, build)
        output = args.output or PROFILES / f"{build}.json"
        # Never replace an existing profile, including the reference, on a rerun.
        with output.open("x") as file:
            file.write(json.dumps(result, indent=2) + "\n")
        print(f"Saved {output}")
        return 0
    except (OSError, ValueError, KeyError, TypeError, struct.error) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
