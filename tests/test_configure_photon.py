import importlib.util
import os
from pathlib import Path
import tempfile
import sys
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("photon", Path(__file__).resolve().parents[1] / "scripts/configure-photon.py")
photon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(photon)
pun = "12345678-1234-4321-abcd-123456789abc"
voice = "87654321-4321-4321-abcd-cba987654321"
second = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    output = root / "out/PhotonServers.swift"
    output.parent.mkdir()
    with patch.dict(os.environ, {}, clear=True):
        output.write_text("preserve existing source")
        try:
            photon.configure(output)
        except ValueError:
            pass
        else:
            raise AssertionError("Missing PUN secret accepted")
        assert output.read_text() == "preserve existing source"
        name = 'Server "One" \\(test) 🌟'
        with patch.dict(os.environ, {"PHOTON_PUN_APP_IDS": f"{name} : {pun.upper()}\nServer Two : {second}", "PHOTON_VOICE_APP_IDS": f"Voice One : {voice}"}):
            photon.configure(output)
            assert f'({photon.json.dumps(name, ensure_ascii=False)}, "{pun}")' in output.read_text()
            assert f'("Server Two", "{second}")' in output.read_text()
            assert f'("Voice One", "{voice}")' in output.read_text()
        for puns, voices in [("bad", ""), (f"One : {pun}\nTwo : {pun.upper()}", ""), (f"One : {pun}", f"Voice : {pun}"), ("", f"Voice : {voice}"), (f" : {pun}", ""), (f"One : {pun}, Two : {second}", ""), (f"Bad\tName : {pun}", "")]:
            before = output.read_text()
            with patch.dict(os.environ, {"PHOTON_PUN_APP_IDS": puns, "PHOTON_VOICE_APP_IDS": voices}):
                try:
                    photon.configure(output)
                except ValueError:
                    pass
                else:
                    raise AssertionError("Invalid Photon settings accepted")
            assert output.read_text() == before
        with patch.dict(os.environ, {"PHOTON_PUN_APP_IDS": f"\nOne : {pun}\n", "PHOTON_VOICE_APP_IDS": ""}):
            photon.configure(output)
            assert "static let voiceServers: [(name: String, appID: String)] = []" in output.read_text()
print("Photon configuration checks passed.")
