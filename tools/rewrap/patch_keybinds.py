#!/usr/bin/env python3
"""Rebind Casualties: Unknown keybinds for trackpad users (no mouse).

WHY: the tutorial needs a right-click *drag* (open the trash bag, drag the item into your
hand). `PlayerCamera::HandleDragging` starts the drag on `Input.GetKeyDown(bind)` and DROPS
it on `Input.GetKeyUp(bind)` — the whole drag hangs off ONE bind. With the default
`iteminteract = Mouse1` you must hold a two-finger click steady while moving the cursor with
the same fingers, which a trackpad cannot do reliably: the release lands in the wrong place
and the item never stays in the slot. Rebind `iteminteract` to a held keyboard key (Option =
LeftAlt) and it all works: hold the key, move the pointer with one finger, release to drop.

⚠️ THE BIND STORE MOVED IN 7.0 — this cost real debugging time. The 5.1 demo kept binds in
`keybinds.json` (`{"binds": {"iteminteract": "Mouse1"}}`, KeyCode *names*). 7.0 folded them
into the Settings system: `settings.json`, a flat list of `{"name":…, "value":…}` where a
keybind's value is the KeyCode's *integer* (Mouse1 = 324, LeftAlt = 308). There is NO
keybinds.json in the 7.0 assembly at all — an old one is silently IGNORED, the game falls back
to defaults, and your rebind looks like it "did nothing". This script handles both stores and
prints which it found.

7.0 also has an in-game rebinding UI (SettingKeybind / `keybindnotset`), so Settings →
Controls should work too; this stays useful for scripting a fresh install.

Both stores live in Unity's persistentDataPath = ~/Library/Application Support/<BUNDLE ID>,
so the id chosen by tools/port.sh decides the directory. Auto-detected below.

Usage:
    patch_keybinds.py                          # show current binds (and which store)
    patch_keybinds.py iteminteract LeftAlt     # rebind (the trackpad fix)
    patch_keybinds.py --restore                # restore the pre-patch backup
    patch_keybinds.py --dir <path>             # force a persistentDataPath
"""
import json
import pathlib
import shutil
import subprocess
import sys

SUPPORT = pathlib.Path.home() / "Library/Application Support"
CANDIDATES = ["com.orsoniks.casualtiesunknown.metal",   # tools/port.sh default
              "com.DefaultCompany.2DProject"]           # inherited donor id (the 5.1 port)

# Unity KeyCode -> int. Letters/digits are ASCII; the rest are the enum's own values.
KEYCODES = {
    **{chr(c): c for c in range(ord("a"), ord("z") + 1)},
    **{chr(c).upper(): c for c in range(ord("a"), ord("z") + 1)},
    **{f"Alpha{i}": 48 + i for i in range(10)},
    "Space": 32, "Tab": 9, "Escape": 27, "Return": 13, "Backspace": 8, "Delete": 127,
    "BackQuote": 96, "Minus": 45, "Equals": 61, "Comma": 44, "Period": 46, "Slash": 47,
    "LeftShift": 304, "RightShift": 303, "LeftControl": 306, "RightControl": 305,
    "LeftAlt": 308, "RightAlt": 307, "LeftCommand": 310, "RightCommand": 309,
    "UpArrow": 273, "DownArrow": 274, "RightArrow": 275, "LeftArrow": 276,
    **{f"Mouse{i}": 323 + i for i in range(7)},
    **{f"F{i}": 281 + i for i in range(1, 13)},
}
BY_VALUE = {v: k for k, v in KEYCODES.items()
            if not (k.islower() and len(k) == 1)}   # prefer 'E' over 'e' when printing


def running():
    return subprocess.run(["pgrep", "-f", "CasualtiesUnknown"],
                          capture_output=True).returncode == 0


def find_store(forced=None):
    """-> (path, kind) where kind is 'settings' (7.0) or 'keybinds' (5.1)."""
    dirs = [pathlib.Path(forced)] if forced else [SUPPORT / c for c in CANDIDATES]
    for d in dirs:
        if (d / "settings.json").exists():
            return d / "settings.json", "settings"
    for d in dirs:
        if (d / "keybinds.json").exists():
            return d / "keybinds.json", "keybinds"
    sys.exit("no settings.json / keybinds.json found in:\n  "
             + "\n  ".join(str(d) for d in dirs)
             + "\nLaunch the game once — it writes its settings on first run.")


def show(path, kind):
    print(f"bind store: {path}  [{kind}]")
    data = json.loads(path.read_text())
    if kind == "settings":
        for e in data:
            v = e.get("value")
            if isinstance(v, int) and not isinstance(v, bool) and v in BY_VALUE:
                print(f"  {e['name']:<18} {BY_VALUE[v]:<12} ({v})")
    else:
        for k, v in data["binds"].items():
            print(f"  {k:<18} {v}")


def main():
    argv = sys.argv[1:]
    forced = None
    if "--dir" in argv:
        i = argv.index("--dir")
        forced = argv[i + 1]
        del argv[i:i + 2]

    path, kind = find_store(forced)
    backup = path.with_suffix(".json.bak-mouse1")

    if "--restore" in argv:
        if not backup.exists():
            sys.exit(f"no backup at {backup}")
        if running():
            sys.exit("quit the game first — it rewrites its settings on exit.")
        shutil.copy(backup, path)
        print(f"restored {path.name} from {backup.name}")
        return

    args = [a for a in argv if not a.startswith("--")]
    if not args:
        show(path, kind)
        return
    if len(args) % 2:
        sys.exit("expected pairs: <action> <KeyCode> [<action> <KeyCode> ...]")
    if running():
        sys.exit("quit the game first — it rewrites its settings on exit and would "
                 "overwrite this edit.")

    if not backup.exists():
        shutil.copy(path, backup)
        print(f"backed up original -> {backup.name}")

    data = json.loads(path.read_text())
    for action, key in zip(args[::2], args[1::2]):
        if kind == "settings":
            if key not in KEYCODES and not key.isdigit():
                sys.exit(f"unknown KeyCode {key!r} (7.0 stores ints; pass a name I know, "
                         "or the raw integer)")
            val = int(key) if key.isdigit() else KEYCODES[key]
            hit = [e for e in data if e.get("name") == action]
            if not hit:
                sys.exit(f"no setting named {action!r} in {path.name}")
            old = hit[0]["value"]
            hit[0]["value"] = val
            print(f"  {action}: {BY_VALUE.get(old, old)} ({old}) -> {key} ({val})")
        else:
            binds = data["binds"]
            if action not in binds:
                sys.exit(f"unknown action {action!r}; known: {', '.join(binds)}")
            print(f"  {action}: {binds[action]} -> {key}")
            binds[action] = key

    path.write_text(json.dumps(data, indent=1))
    print(f"written -> {path}")


if __name__ == "__main__":
    main()
