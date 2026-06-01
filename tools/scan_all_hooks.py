#!/usr/bin/env python3
r"""
scan_all_hooks.py - comprehensive FS25 mod hook scanner / conflict database.

Improvements over find_global_scripts.py (the category-filtered scanner):
  * Reads EVERY .lua in each mod, not just <extraSourceFiles>+source()-reachable
    files. Closes the blind spot that hid FarmKit's NXFarmKitChain.lua
    (<specializations> file) and the "6 mods missed entirely" cases.
  * Scans ALL installed mods in the real mods folder regardless of category
    (the old catalogue only scanned the Scripts-and-Tools reference subset, so
    a physics mod marketed as a "field planner" was invisible).
  * Detects Utils.prependedFunction (was missing).
  * Detects manual direct-assignment hook chains (local orig = C.m; C.m = function...).
  * Emits hook_database.json (function -> hookers) + conflict_matrix.csv +
    conflict_summary.txt. Outputs to FS25\modsynth_db\ (OUT of mods\ to keep the
    in-game mod search clean).

Usage:
  python scan_all_hooks.py                 # full scan of all installed mods
  python scan_all_hooks.py FarmKit DDP     # validation: only zips matching these substrings
"""
import os, re, csv, json, sys, zipfile
import xml.etree.ElementTree as ET
from datetime import datetime
from collections import defaultdict

MODS_FOLDER = r"C:\Users\Administrator\Documents\My Games\FarmingSimulator2025\mods"
OUT_DIR     = r"C:\Users\Administrator\Documents\My Games\FarmingSimulator2025\modsynth_db"

# ---- Lua comment stripping (covers --[[ ]], --[=[ ]=], line comments) ----
_BLOCK = re.compile(r'--\[=*\[.*?\]=*\]', re.DOTALL)
_LINE  = re.compile(r'--[^\n]*')
def strip_comments(s):
    return _LINE.sub('', _BLOCK.sub('', s))

# ---- hook detection patterns ----
OVERWRITE_FULL = re.compile(
    r'([\w.]+)\s*=\s*Utils\.overwrittenFunction\s*\(\s*[\w.]+\s*,\s*(function\b|[\w.]+)')
APPENDED  = re.compile(r'([\w.]+)\s*=\s*Utils\.appendedFunction\s*\(')
PREPENDED = re.compile(r'([\w.]+)\s*=\s*Utils\.prependedFunction\s*\(')
ACTIONEVT = re.compile(r':registerActionEvent\s*\(')
# manual chain: a captured original (local orig = Class.method) + a reassignment
LOCAL_CAP     = re.compile(r'=\s*([A-Z][\w]*(?:\.[\w]+)+)\b')
DIRECT_ASSIGN = re.compile(r'\b([A-Z][\w]*(?:\.[\w]+)+)\s*=\s*function\b')

# original-function parameter aliases seen across FS25 mods (superFunc is the Giants
# convention; the rest are real variants found in the wild).
_SUPER_ALIASES = ("superfunc", "originalfunction", "origfunc", "overwrittenfunc")

def _first_params(text):
    m = re.search(r'\(([^)]*)\)', text)
    return [p.strip() for p in m.group(1).split(',') if p.strip()] if m else []

def overwrite_calls_super(src, impl_ref, reg_end):
    """
    Accurate: does the overwrite impl actually CALL the original?

    Handles the cases that fooled the token-presence check:
      * colon defs  function C:m(superFunc, ...)  -> self implicit, super = 1st param
      * dot/inline  function C.m(self, superFunc) -> super = 2nd param (skip self)
      * alias param names (superFunc/originalFunction/origFunc/overwrittenFunc)
      * varargs passthrough function C:m(...) -> conservatively treated as chained
      * declared-but-never-called super param  -> correctly flagged as a stomp
    Conservative (assume chained) only when the impl/def cannot be located at all,
    to avoid manufacturing false CRITICALs.
    """
    if impl_ref == 'function':                         # inline anonymous: (self, superFunc, ...)
        params = _first_params(src[reg_end:reg_end + 200])
        colon, body = False, src[reg_end:reg_end + 6000]
    else:                                              # named impl: resolve its def precisely
        ref = impl_ref
        last = re.escape(ref.split('.')[-1].split(':')[-1])
        if '.' in ref or ':' in ref:                   # qualified ref: Class.method / Class:method
            qual = re.escape(re.split(r'[.:]', ref)[0])
            cands = [r'function\s+' + qual + r'[.:]' + last + r'\s*\(([^)]*)\)',
                     re.escape(ref) + r'\s*=\s*function\s*\(([^)]*)\)']
        else:                                          # bare ref: prefer the local function, not a
            cands = [r'local\s+function\s+' + last + r'\s*\(([^)]*)\)',   # same-named Class:method
                     r'\bfunction\s+' + last + r'\s*\(([^)]*)\)',
                     r'\b' + last + r'\s*=\s*function\s*\(([^)]*)\)']
        cands.append(r'function\s+[\w.]*[.:]' + last + r'\s*\(([^)]*)\)')  # suffix fallback (last)
        m = None
        for c in cands:
            m = re.search(c, src)
            if m:
                break
        if not m:
            return True                                # def not locatable -> assume chained
        colon = ':' in src[m.start():m.start() + 200].split('(')[0]
        params = [p.strip() for p in (m.group(1) or '').split(',') if p.strip()]
        body = src[m.end():m.end() + 6000]
    if params and params[0] == '...':
        return True                                    # varargs passthrough
    sp = next((p for p in params if p.lower() in _SUPER_ALIASES), None)
    if sp is None:
        idx = 0 if colon else 1                        # colon: self implicit; else skip self
        sp = params[idx] if len(params) > idx else None
    if not sp or sp == '...':
        return True
    return bool(re.search(r'\b' + re.escape(sp) + r'\s*\(', body))   # is it actually CALLED?

# ---- call-frequency risk (by function name) ----
FREQ_HIGH = ["update", "draw", "onupdate", "ondraw", "updatetick", "onupdatetick"]
FREQ_MED  = ["onminutechanged", "onhourchanged", "ondaychanged", "registeractionevents",
             "onreadupdatestream", "onwriteupdatestream", "onreadstream", "onwritestream",
             "processarea", "onendworkareaprocessing", "onstartworkareaprocessing",
             "processbalerarea", "processcultivatorarea", "processsprayerarea",
             "processsowingmachinearea", "handledischargeraycast", "collisiontestcallback",
             "serverupdate"]  # serverUpdate already caught by 'update'; explicit for clarity
FREQ_LOW  = ["loadmapfinished", "loadmap", "loadmission", "onstartmission", "initialize",
             "onload", "savesavegame", "savetoxmlfile", "loadfromxml", "validatetypes",
             "finalizetypes", "delete", "onframeopen", "sendinitialclientstate",
             "registeractionevent", "finalize"]
def freq_risk(fn):
    f = fn.lower()
    for m in FREQ_HIGH:
        if m in f: return "HIGH"
    for m in FREQ_MED:
        if m in f: return "MEDIUM"
    for m in FREQ_LOW:
        if m in f: return "LOW"
    return "UNKNOWN"

def is_local_target(t):
    """Lowercase-first dotted target = local variable method, not a global class hook."""
    return '.' in t and t.split('.')[0][0].islower()

def analyse(src):
    """Return list of (pattern, target, calls_super) for one mod's combined Lua."""
    src = strip_comments(src)
    hits, seen = [], set()
    def add(p, t, cs=None):
        if is_local_target(t): return
        k = (p, t)
        if k in seen: return
        seen.add(k); hits.append((p, t, cs))
    for m in OVERWRITE_FULL.finditer(src):
        cs = overwrite_calls_super(src, m.group(2), m.end())
        add("overwritten" if cs else "broken_overwrite", m.group(1), cs)
    for t in APPENDED.findall(src):  add("appended", t, True)
    for t in PREPENDED.findall(src): add("prepended", t, True)
    if ACTIONEVT.search(src):
        hits.append(("actionEvent", "registerActionEvent", None))
    caps = set(LOCAL_CAP.findall(src))
    for m in DIRECT_ASSIGN.finditer(src):
        tgt = m.group(1)
        if tgt in caps:           # original was captured -> manual hook chain
            add("direct_assign", tgt, True)
    return hits

def read_all_lua_zip(zf):
    """Concatenate EVERY .lua in the zip (cross-file impl resolution + no blind spots)."""
    parts = []
    for n in zf.namelist():
        if n.lower().endswith(".lua"):
            try:
                parts.append(zf.open(n).read().decode("utf-8", "replace"))
            except Exception:
                pass
    return "\n".join(parts)

def read_all_lua_folder(path):
    parts = []
    for root, dirs, files in os.walk(path):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in files:
            if f.lower().endswith(".lua"):
                try:
                    with open(os.path.join(root, f), "r", encoding="utf-8", errors="replace") as fh:
                        parts.append(fh.read())
                except Exception:
                    pass
    return "\n".join(parts)

def mod_title(moddesc_bytes):
    try:
        b = moddesc_bytes[3:] if moddesc_bytes.startswith(b'\xef\xbb\xbf') else moddesc_bytes
        root = ET.fromstring(b)
        t = root.find("title")
        if t is not None:
            en = t.find("en")
            if en is not None and en.text: return en.text.strip()
            for c in t:
                if c.text and c.text.strip(): return c.text.strip()
    except Exception:
        pass
    return ""

def scan_one(path):
    """Return (name, title, hits) or None. Handles zip files and extracted folders."""
    name = os.path.basename(path)
    try:
        if os.path.isdir(path):
            md = os.path.join(path, "modDesc.xml")
            if not os.path.isfile(md): return None
            title = mod_title(open(md, "rb").read())
            lua = read_all_lua_folder(path)
        else:
            with zipfile.ZipFile(path, "r") as zf:
                if "modDesc.xml" not in zf.namelist(): return None
                title = mod_title(zf.read("modDesc.xml"))
                lua = read_all_lua_zip(zf)
        if not lua.strip(): return None
        hits = analyse(lua)
        return (name, title, hits) if hits else None
    except zipfile.BadZipFile:
        print(f"  [WARN] bad zip: {name}")
    except Exception as e:
        print(f"  [WARN] {name}: {e}")
    return None

# ---- conflict classification (severity model from conflict_matrix.py) ----
SEV_ORDER = {"STOMP":0,"LOAD_ORDER":1,"HOT_CHAIN":2,"WARM_CHAIN":3,"SELF_MIXED":4,"CHAIN":5,"SAFE_CHAIN":6}
SEV_LABEL = {
    "STOMP":      "CRITICAL  - broken overwrite: impl does NOT call superFunc",
    "LOAD_ORDER": "HIGH      - safe overwrite + appenders (load-order dependent)",
    "HOT_CHAIN":  "MEDIUM    - 3+ chainers on HIGH-freq function (per-frame compounding)",
    "WARM_CHAIN": "MEDIUM    - 3+ chainers on MEDIUM-freq function",
    "SELF_MIXED": "LOW       - one mod both overwrites and appends same fn",
    "CHAIN":      "INFO      - 2+ chainers (safe chain, behavioral compounding possible)",
    "SAFE_CHAIN": "INFO      - multiple safe overwrites, all call superFunc",
}
FREQ_ORDER = {"HIGH":0,"MEDIUM":1,"LOW":2,"UNKNOWN":3}
CHAINERS = ("appended", "prepended", "direct_assign")

def classify(fn, entries):
    mods = {e["mod"] for e in entries}
    if len(mods) < 2: return None
    broken  = {e["mod"] for e in entries if e["pattern"] == "broken_overwrite"}
    safe_ow = {e["mod"] for e in entries if e["pattern"] == "overwritten"}
    chain   = {e["mod"] for e in entries if e["pattern"] in CHAINERS}
    all_ow  = broken | safe_ow
    worst   = min((e["freq"] for e in entries), key=lambda f: FREQ_ORDER.get(f,3))
    if broken:
        d = f"{len(broken)} broken overwriter(s): {', '.join(sorted(broken))}"
        if safe_ow: d += f"  (+{len(safe_ow)} safe ow)"
        if chain:   d += f"  (+{len(chain)} chainers)"
        return "STOMP", worst, d
    if all_ow and chain:
        return "LOAD_ORDER", worst, f"Overwriter(s): {', '.join(sorted(all_ow))} | Chainers: {', '.join(sorted(chain))}"
    if all_ow & chain:
        return "SELF_MIXED", worst, f"Self-mixed: {', '.join(sorted(all_ow & chain))}"
    if len(safe_ow) >= 2 and not chain:
        return "SAFE_CHAIN", worst, f"{len(safe_ow)} safe overwrites: {', '.join(sorted(safe_ow))}"
    n = len(mods)
    if n >= 3 and worst == "HIGH":   return "HOT_CHAIN", worst, f"{n} chainers on HIGH-freq fn"
    if n >= 3 and worst == "MEDIUM": return "WARM_CHAIN", worst, f"{n} chainers on MEDIUM-freq fn"
    return "CHAIN", worst, f"{n} chainers"

def emit_ms_catalogue(dest):
    """Emit the scan as a Lua dataset ModSynth loads (the offline registry-walker output).
    Only CRITICAL/HIGH/MEDIUM conflicts are emitted as entries; INFO chains are summarised
    in meta (ModSynth already reports those generically). Mod names are deduped across the
    zip-vs-extracted-folder double-install case."""
    with open(os.path.join(OUT_DIR, "hook_database.json"), encoding="utf-8") as f:
        db = json.load(f)
    SEVMAP = {"STOMP": "CRITICAL", "LOAD_ORDER": "HIGH", "HOT_CHAIN": "MEDIUM",
              "WARM_CHAIN": "MEDIUM", "CHAIN": "INFO", "SAFE_CHAIN": "INFO"}
    SEVO = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "INFO": 3}
    entries, info_count = [], 0
    for fn, v in db["functions"].items():
        norm = []
        for h in v["hookers"]:
            m = h["mod"]
            m = m[:-4] if m.lower().endswith(".zip") else m   # dedupe zip vs folder of same mod
            norm.append({"mod": m, "pattern": h["pattern"], "freq": h["freq"]})
        c = classify(fn, norm)
        if not c:
            continue
        ctype, freq, detail = c
        sev = SEVMAP.get(ctype, "INFO")
        if sev == "INFO":
            info_count += 1
            continue                                          # INFO chains summarised in meta
        entries.append((fn, sev, ctype, freq, sorted({h["mod"] for h in norm}), detail))
    entries.sort(key=lambda e: (SEVO[e[1]], e[0]))

    def q(s):
        return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'
    L = ["-- AUTO-GENERATED by scan_all_hooks.py --emit-only. Do NOT hand-edit.",
         "-- Offline hook-conflict scan, consumed by ModSynth as the registry-walker dataset.",
         "-- Regenerate after mod changes: python scan_all_hooks.py (re-emits automatically).",
         "ModSynthScan = {",
         "  meta = { generated = %s, scanned = %d, withHooks = %d, functions = %d, actionable = %d, infoChains = %d },"
         % (q(db["scanned_at"]), db["total_scanned"], db["total_with_hooks"],
            len(db["functions"]), len(entries), info_count),
         "  entries = {"]
    for fn, sev, ctype, freq, mods, detail in entries:
        modlua = "{ " + ", ".join(q(m) for m in mods) + " }"
        L.append("    { fn = %s, sev = %s, ctype = %s, freq = %s, mods = %s, detail = %s },"
                 % (q(fn), q(sev), q(ctype), q(freq), modlua, q(detail)))
    L += ["  },", "}", ""]
    with open(dest, "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    print("emitted %d actionable entries (+%d INFO chains) -> %s" % (len(entries), info_count, dest))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    if "--emit-only" in sys.argv:
        emit_ms_catalogue(os.path.join(OUT_DIR, "ms_catalogue_generated.lua"))
        return
    filters = [a.lower() for a in sys.argv[1:]]
    entries = sorted(os.listdir(MODS_FOLDER))
    if filters:
        entries = [e for e in entries if any(f in e.lower() for f in filters)]

    db = defaultdict(lambda: {"freq": "UNKNOWN", "hookers": []})
    scanned = with_hooks = 0
    for i, entry in enumerate(entries):
        full = os.path.join(MODS_FOLDER, entry)
        if not (entry.lower().endswith(".zip") or os.path.isdir(full)):
            continue
        scanned += 1
        if not filters and scanned % 250 == 0:
            print(f"  ...scanned {scanned}")
        res = scan_one(full)
        if not res:
            continue
        name, title, hits = res
        with_hooks += 1
        for pattern, fn, cs in hits:
            if pattern == "actionEvent":
                continue
            rec = db[fn]
            rec["freq"] = freq_risk(fn)
            rec["hookers"].append({"mod": name, "title": title,
                                   "pattern": pattern, "calls_super": cs,
                                   "freq": rec["freq"]})
        if filters:
            print(f"  [FOUND] {name}: " +
                  ", ".join(f"{p}->{fn}" for p, fn, _ in hits if p != "actionEvent"))

    # ---- master database ----
    db_out = {
        "scanned_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "mods_folder": MODS_FOLDER,
        "total_scanned": scanned,
        "total_with_hooks": with_hooks,
        "functions": {fn: v for fn, v in sorted(db.items())},
    }
    with open(os.path.join(OUT_DIR, "hook_database.json"), "w", encoding="utf-8") as f:
        json.dump(db_out, f, indent=1)

    # ---- conflicts ----
    conflicts = []
    for fn, v in db.items():
        c = classify(fn, v["hookers"])
        if c:
            ctype, freq, detail = c
            mods = sorted({h["mod"] for h in v["hookers"]})
            conflicts.append({"fn": fn, "type": ctype, "freq": freq,
                              "n": len(mods), "mods": mods, "detail": detail})
    conflicts.sort(key=lambda c: (SEV_ORDER.get(c["type"],9), FREQ_ORDER.get(c["freq"],3), c["fn"]))

    with open(os.path.join(OUT_DIR, "conflict_matrix.csv"), "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["Function", "Conflict Type", "Call Frequency", "Mods Involved", "Mod List", "Detail"])
        for c in conflicts:
            w.writerow([c["fn"], c["type"], c["freq"], c["n"], " | ".join(c["mods"]), c["detail"]])

    counts = defaultdict(int)
    for c in conflicts:
        counts[c["type"]] += 1
    with open(os.path.join(OUT_DIR, "conflict_summary.txt"), "w", encoding="utf-8") as f:
        W = 74
        f.write("=" * W + "\nFS25 COMPREHENSIVE HOOK CONFLICT REPORT\n")
        f.write(f"scanned {scanned} mods, {with_hooks} with hooks, {db_out['scanned_at']}\n" + "=" * W + "\n\n")
        f.write(f"Total conflicting functions: {len(conflicts)}\n\n")
        for t in SEV_ORDER:
            if counts.get(t): f.write(f"  {counts[t]:4d}  {SEV_LABEL[t]}\n")
        f.write("\n")
        for t in SEV_ORDER:
            grp = [c for c in conflicts if c["type"] == t]
            if not grp: continue
            f.write("=" * W + f"\n{SEV_LABEL[t]}\n" + "=" * W + "\n\n")
            for c in grp:
                f.write(f"  {c['fn']}   [{c['freq']}]\n    {c['detail']}\n")
                for m in c["mods"]:
                    f.write(f"      -> {m}\n")
                f.write("\n")

    print(f"\nScanned {scanned} mods ({with_hooks} with hooks).")
    print(f"Functions hooked: {len(db)}   |   Conflicting functions: {len(conflicts)}")
    for t in SEV_ORDER:
        if counts.get(t): print(f"  {t:<11} {counts[t]:4d}")
    emit_ms_catalogue(os.path.join(OUT_DIR, "ms_catalogue_generated.lua"))
    print(f"\nOutputs -> {OUT_DIR}")

if __name__ == "__main__":
    main()
