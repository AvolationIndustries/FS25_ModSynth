#!/usr/bin/env python3
"""
Build the deployable ModMixer zip.

Codifies two hard-won lessons:
  1. FORWARD-SLASH entries. PowerShell/.NET ZipFile writes Windows backslash
     entry names ("gui\\X.lua"); the GIANTS engine only accepts forward slashes
     or every script silently fails to load. We force '/' on every arcname.
  2. THE 0_ PREFIX. The mod MUST ship as FS25_0_ModMixer.zip so it sorts before
     every other FS25_ mod (case-sensitive alphabetical) and loads first — that's
     what lets the hook interceptor capture the whole stack. Drop the prefix and
     it loads at "M" and only sees ~10% of mods.

Usage:
    python tools/build.py            # build FS25_0_ModMixer.zip in project root
    python tools/build.py --deploy   # also copy into the live FS25 mods folder
"""
import os
import sys
import shutil
import zipfile

HERE        = os.path.dirname(os.path.abspath(__file__))
PROJECT     = os.path.dirname(HERE)                       # ...\FS25_ModMixer
SRC         = os.path.join(PROJECT, "FS25_ModMixer")      # zip-root source folder
OUT_NAME    = "FS25_0_ModMixer.zip"                       # <-- the 0_ prefix is load-critical
OUT_PATH    = os.path.join(PROJECT, OUT_NAME)
MODS_DIR    = r"C:\Users\Administrator\Documents\My Games\FarmingSimulator2025\mods"

SKIP_DIRS   = {".git", "__pycache__"}
SKIP_FILES  = {".gitattributes", "Thumbs.db", ".DS_Store"}


def ensure_icon():
    """modDesc references icon_ModMixer.dds (cert naming). If only the old
    icon.dds exists, mirror it so the icon resolves in-game for testing. The
    proper 512x512 DXT1 icon replaces icon_ModMixer.dds later."""
    new = os.path.join(SRC, "icon_ModMixer.dds")
    old = os.path.join(SRC, "icon.dds")
    if not os.path.exists(new) and os.path.exists(old):
        shutil.copy2(old, new)
        print("  icon: mirrored icon.dds -> icon_ModMixer.dds (placeholder for testing)")


def build():
    if not os.path.isdir(SRC):
        sys.exit(f"ERROR: source folder not found: {SRC}")
    ensure_icon()

    if os.path.exists(OUT_PATH):
        os.remove(OUT_PATH)

    n = 0
    with zipfile.ZipFile(OUT_PATH, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(SRC):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for f in files:
                if f in SKIP_FILES:
                    continue
                full = os.path.join(root, f)
                rel  = os.path.relpath(full, SRC)
                arc  = rel.replace(os.sep, "/")    # <-- forward slashes, always
                z.write(full, arc)
                n += 1

    size_kb = os.path.getsize(OUT_PATH) / 1024
    print(f"Built {OUT_NAME}: {n} files, {size_kb:.0f} KB")
    print(f"  -> {OUT_PATH}")

    # sanity: no backslash entries
    with zipfile.ZipFile(OUT_PATH) as z:
        bad = [e for e in z.namelist() if "\\" in e]
        if bad:
            sys.exit(f"ERROR: {len(bad)} backslash entries leaked: {bad[:3]}")
        print(f"  verified: all {len(z.namelist())} entries use forward slashes")
    return OUT_PATH


def deploy(path):
    if not os.path.isdir(MODS_DIR):
        sys.exit(f"ERROR: mods folder not found: {MODS_DIR}")
    dest = os.path.join(MODS_DIR, OUT_NAME)
    # ATOMIC swap. A plain copy2 truncates + rewrites the destination in place,
    # which leaves a torn-zip window — and the game reads the GUI XML at MISSION
    # LOAD (not boot), so a deploy racing a savegame load blanks the Switchboard
    # ("Could not open gui-config SwitchboardFrame.xml", seen 2026-06-11). Write
    # a temp file beside it, then os.replace(): on Windows that's an atomic
    # MoveFileEx — readers get the old zip or the new zip, never a half-written one
    # (and if the file is locked it fails CLEANLY instead of tearing).
    tmp = dest + ".deploying"
    try:
        shutil.copy2(path, tmp)
        os.replace(tmp, dest)
    except PermissionError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        sys.exit("ERROR: zip is locked (game reading it right now?) — retry in a moment.")
    print(f"Deployed -> {dest}  (atomic)")


if __name__ == "__main__":
    out = build()
    if "--deploy" in sys.argv:
        deploy(out)
