import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
script = Path(__file__).resolve().parents[1] / "scripts/update-steam-signatures.py"
spec = importlib.util.spec_from_file_location("signatures", script)
signatures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signatures)


def rejected(operation):
    try:
        operation()
    except (ValueError, struct.error):
        return
    raise AssertionError("Invalid input accepted")


fixed = bytes.fromhex("F8 5F BC A9 F6 57 01 A9 F4 4F 02 A9 FD 7B 03 A9")
old = fixed + bytes.fromhex("13 D8 DA 97 C9 61 00 D0")
new = fixed + bytes.fromhex("0B D8 DA 97 AA BB CC D0")
pattern = signatures.portable_pattern(old.hex(" "))
assert pattern.endswith("?? ?? ?? ?? ?? ?? ?? ??")
assert signatures.unique_match(new, pattern) == 0
rejected(lambda: signatures.unique_match(new + new, pattern))
rejected(lambda: signatures.unique_match(b"\0" + new, pattern))
rejected(lambda: signatures.unique_match(bytes(len(new)), pattern))
for invalid in ("?? " * 16, "GG " * 16, "00 01", "00" * 16):
    rejected(lambda: signatures.portable_pattern(invalid))
assert signatures.portable_pattern(pattern) == pattern

# A minimal ARM64 Mach-O section, both thin and universal.
header = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 6, 1, 152, 0, 0)
segment = struct.pack("<II16sQQQQIIII", 0x19, 152, b"__TEXT", 0, 0x1000, 0, 184 + len(new), 7, 5, 1, 0)
section = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", 0x8000, len(new), 184, 2, 0, 0, 0, 0, 0, 0)
thin = header + segment + section + new
fat = struct.pack(">7I", 0xcafebabe, 1, 0x100000c, 0, 28, len(thin), 2) + thin
assert signatures.text_section(thin) == (new, 0x8000)
assert signatures.text_section(fat) == (new, 0x8000)
for invalid in (b"", thin[:100], thin[:-1], fat[:-1], b"MZ" + thin[2:]):
    rejected(lambda: signatures.text_section(invalid))

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    client = root / "steamclient.dylib"
    client.write_bytes(fat)
    package = root / "package"
    package.mkdir()
    legacy = package / "steam_client_osx.manifest"
    legacy.write_text('"version" "1791918634"')
    os.utime(legacy, ns=(1, 1))
    current = package / "steam_client_signed-2_osx.manifest"
    current.write_text('"version" "1792618285"')
    assert signatures.client_build(client) == 1792618285
    reference = root / "reference.json"
    reference.write_text(json.dumps(dict(schema_version=3, profile_version=1, arch="arm64", platform="macos",
                                         signatures=[dict(name="target", aob_hex=old.hex(" "), match_offset=0)])))
    output = root / "profile.json"
    command = [sys.executable, str(script), "--client", str(client), "--reference", str(reference), "--output", str(output)]
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    generated = json.loads(output.read_text())
    assert generated["steam_build"] == 1792618285
    assert generated["signatures"][0]["aob_hex"] == pattern
    before = output.read_bytes()
    assert subprocess.run(command, capture_output=True).returncode != 0
    assert output.read_bytes() == before
    current.write_text('"version" "invalid"')
    rejected(lambda: signatures.client_build(client))
    current.write_text('"version" "1792618285"')
    client.write_bytes(header + segment + section + bytes(len(new)))
    missing = root / "missing.json"
    command[-1] = str(missing)
    assert subprocess.run(command, capture_output=True).returncode != 0
    assert not missing.exists()

print("Steam signature checks passed.")
