#!/usr/bin/env python3
"""Configure Swift Photon servers from GitHub Actions secrets."""
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def configure(output):
    groups = []
    for env in ["PHOTON_PUN_APP_IDS", "PHOTON_VOICE_APP_IDS"]:
        servers = []
        ids = set()
        for line in os.environ.get(env, "").splitlines():
            if not line.strip():
                continue
            name, separator, value = line.partition(":")
            name, app_id = name.strip(), value.strip().lower()
            if not separator or not name or any(ord(char) < 32 or ord(char) == 127 for char in name):
                raise ValueError(f"{env}: expected Name server : GUID, one per line")
            if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", app_id):
                raise ValueError(f"{env}: invalid UUID")
            if app_id in ids:
                raise ValueError(f"{env}: duplicate AppId")
            ids.add(app_id)
            servers.append((name, app_id))
        groups.append(servers)
    if not groups[0]:
        raise ValueError("PHOTON_PUN_APP_IDS: at least one server is required")
    if {value for _, value in groups[0]} & {value for _, value in groups[1]}:
        raise ValueError("PUN and Voice AppIds must be distinct")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for _, app_id in groups[0] + groups[1]:
            print(f"::add-mask::{app_id}")
    source = "enum PhotonServers {\n"
    for field, servers in zip(["all", "voiceServers"], groups):
        rows = ",\n".join(f'        ({json.dumps(name, ensure_ascii=False)}, "{value}")' for name, value in servers)
        array = f"[\n{rows}\n    ]" if rows else "[]"
        source += f"    static let {field}: [(name: String, appID: String)] = {array}\n"
    source += "}\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    if not output.exists() or output.read_text() != source:
        output.write_text(source)


if __name__ == "__main__":
    try:
        configure(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "OnlineFixManager/Models/PhotonServers.swift")
    except (ValueError, OSError):
        print("Photon configuration failed: use Name server : GUID per line; PUN is required, UUIDs must be valid, unique and distinct between PUN/Voice.", file=sys.stderr)
        sys.exit(1)
