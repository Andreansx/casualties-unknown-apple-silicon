#!/usr/bin/env python3
"""Rebind Casualties: Unknown keybinds for trackpad users (no mouse).

The game has no in-game rebinding UI: KeyBinds (Assembly-CSharp) exposes only
GetBind/LoadBindsFromFile/GenerateDefaultBinds, and the pre-run screen's
"open binds file / reload / reset" buttons (PreRunScript) are the intended UX.
Binds live in a JSON file at Application.persistentDataPath/keybinds.json, whose
values are KeyCode enum NAMES (parsed via Enum.Parse) -- so any KeyCode name works.

Why this matters on a MacBook: the tutorial requires right-click *drag*
("(RIGHT CLICK) me and drag me onto yourself"). Even with macOS Secondary Click
enabled, you cannot hold a two-finger click while moving the cursor with the same
fingers, so RMB-drag is unusable on a trackpad. Rebinding 'iteminteract' from
Mouse1 to a held keyboard key makes every right-click interaction work.

Note the persistentDataPath here is com.DefaultCompany.2DProject -- the transplant
inherits the DONOR Mac build's bundle id (EmptyMac.app), not Orsoniks/CasualtiesUnknown.

Usage:
    patch_keybinds.py                 # show current binds
    patch_keybinds.py iteminteract E  # rebind (default fix: iteminteract -> E)
    patch_keybinds.py --restore       # restore the pre-patch backup
"""
import json
import pathlib
import shutil
import sys

BIND_FILE = (pathlib.Path.home() / "Library/Application Support"
             / "com.DefaultCompany.2DProject" / "keybinds.json")
BACKUP = BIND_FILE.with_suffix(".json.bak-mouse1")


def main():
    if not BIND_FILE.exists():
        sys.exit(f"no bind file at {BIND_FILE}\n"
                 "run the game once -- KeyBinds.GenerateDefaultBinds writes it on first launch.")

    if "--restore" in sys.argv:
        if not BACKUP.exists():
            sys.exit(f"no backup at {BACKUP}")
        shutil.copy(BACKUP, BIND_FILE)
        print(f"restored {BIND_FILE} from {BACKUP.name}")
        return

    data = json.loads(BIND_FILE.read_text())
    binds = data["binds"]

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        for k, v in binds.items():
            print(f"  {k:18} {v}")
        return

    if len(args) % 2:
        sys.exit("expected pairs: <action> <KeyCode> [<action> <KeyCode> ...]")

    if not BACKUP.exists():
        shutil.copy(BIND_FILE, BACKUP)
        print(f"backed up original -> {BACKUP.name}")

    for action, key in zip(args[::2], args[1::2]):
        if action not in binds:
            sys.exit(f"unknown action {action!r}; known: {', '.join(binds)}")
        print(f"  {action}: {binds[action]} -> {key}")
        binds[action] = key

    BIND_FILE.write_text(json.dumps(data, indent=2))
    print("written. restart the game (binds are cached in a static after first GetBind).")


if __name__ == "__main__":
    main()
