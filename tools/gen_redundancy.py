# gen_redundancy.py — DUPLICATE-PURPOSE (redundancy) candidate detector.
#
# Goal: an ADVISORY "you may not need both of these" pull-list. Two independent signals,
# because same-purpose mods don't always collide on the same hooks:
#
#   1) HOOK OVERLAP — two mods that overwrite/append an unusually overlapping set of the
#      SAME functions, weighted toward DISTINCTIVE functions. Two mods both hooking
#      Vehicle.update means nothing (everyone does); two both hooking a rare foliage fn is
#      a strong "same job" tell. We weight each shared fn by idf = log(N / df).
#
#   2) NAME SIMILARITY — among SCRIPT mods only (mods that actually install hooks, so we
#      skip vehicle/map name collisions), two mods sharing >=2 meaningful name tokens
#      (CropDestructionOverhaul vs CropDestructionOutsideFields -> {crop, destruction}).
#
# A pair flagged by BOTH is highest confidence. Output: a console report + a Lua data file
# the Switchboard "Redundancy" view will read. This NEVER removes anything — the player
# reviews the list and pulls mods at their own discretion.
import os, re, math, zipfile, html
from collections import defaultdict

MODS_DIR = r"C:/Users/Administrator/Documents/My Games/FarmingSimulator2025/mods"
OUT_LUA  = r"B:/Farm Sim Mod Dev/FS25_ModMixer/FS25_ModMixer/scripts/mm_redundancy_generated.lua"

# Hook-call patterns (same family gen_targets.py keys on).
OW = re.compile(r"\b([A-Z]\w+)\.(\w+)\s*=\s*Utils\.overwrittenFunction|Utils\.overwrittenFunction\s*\(\s*([A-Z]\w+)\.(\w+)")
AP = re.compile(r"\b([A-Z]\w+)\.(\w+)\s*=\s*Utils\.(?:appended|prepended)Function|Utils\.(?:appended|prepended)Function\s*\(\s*([A-Z]\w+)\.(\w+)")

# Universal integration points: hooking the mission object / localisation / type managers
# is what EVERY utility mod does to plug in — sharing these says nothing about shared
# PURPOSE, so they don't count toward redundancy hook-overlap. (This was the #1 false
# positive: BuyUsedEquipment <> ShopSearch both hook FSBaseMission.onMinuteChanged, etc.)
HOOK_STOP_CLASS = {"FSBaseMission", "Mission00", "BaseMission", "Mission",
                   "FSCareerMissionInfo", "I18N", "TypeManager", "MessageCenter",
                   "InputBinding", "Player", "PlayerInputComponent", "g_currentMission",
                   # GUI framework: any mod that adds a settings checkbox/menu page hooks
                   # these — shared use means "both add UI", not "same purpose".
                   "FocusManager", "BinaryOptionElement", "MultiTextOptionElement",
                   "GuiElement", "ButtonElement", "TextInputElement", "InGameMenu",
                   "CheckedOptionElement", "GuiOverlay", "SmoothListElement"}

# Name-token stoplist: framing / authorship / versioning noise, not purpose.
STOP = set("""fs25 fs22 ls25 ls22 fs ls by edited mod mods pack addon addons the of and a an for
version v beta alpha final fix fixed update updated unpack unpacked converted convert edit
stevie tonysolis sazlamodding papa matze official unofficial new old test deluxe edition
multiplayer mp sp giants modhub free premium full lite plus pro""".split())

def tokens(modname):
    s = re.sub(r"\.zip$", "", modname)
    s = re.sub(r"^(FS25_|FS22_|LS25_|LS22_)", "", s)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", s)        # split CamelCase
    s = re.sub(r"[^A-Za-z0-9]+", " ", s)                  # underscores/punct -> space
    out = set()
    for t in s.lower().split():
        if t in STOP: continue
        if len(t) < 3: continue
        if t.isdigit(): continue
        if re.fullmatch(r"v?\d[\d.]*", t): continue       # v1, 1_6_2, ...
        out.add(t)
    return out

def base_name(mod):
    # Collapse a mod to its core identity, ignoring load-order brackets (000_, zzz_) and
    # companion-half / part markers (Hooks, Loader, trailing numbers). Two zips with the
    # SAME base are co-dependent parts of one mod (e.g. PerfPatchHooks + PerfPatch, or
    # ...UNZIPME1 + ...UNZIPME2), NOT redundancy — suppress those pairs.
    s = re.sub(r"\.zip$", "", mod)
    s = re.sub(r"^(FS25_|FS22_|LS25_|LS22_)", "", s, flags=re.I)
    s = re.sub(r"^(0+_|z+_)", "", s, flags=re.I)
    s = re.sub(r"[^A-Za-z0-9]", "", s).lower()
    s = re.sub(r"(hooks?|loader)$", "", s)
    s = re.sub(r"\d+$", "", s)
    return s

def moddesc_text(mod):
    # The human <description> (english) from a mod's modDesc.xml — the store/F1 purpose
    # text. This is the signal names can't give; we attach it so a person can judge.
    try:
        with zipfile.ZipFile(os.path.join(MODS_DIR, mod + ".zip")) as z:
            md = [n for n in z.namelist() if n.lower().endswith("moddesc.xml")]
            if not md: return ""
            x = z.read(md[0]).decode("utf-8", "ignore")
    except Exception:
        return ""
    m = re.search(r"<description>(.*?)</description>", x, re.S)
    if not m: return ""
    body = m.group(1)
    en = re.search(r"<en>(.*?)</en>", body, re.S)
    t = en.group(1) if en else body
    t = re.sub(r"<!\[CDATA\[|\]\]>", " ", t)
    t = re.sub(r"<[^>]+>", " ", t)
    t = html.unescape(t)
    return re.sub(r"\s+", " ", t).strip()

DESC_STOP = set("""the a an and or of to in for with on is are be this that mod script game your
you it as at by from will can also new more when if then so do does each any all not but""".split())
def desc_tokens(text):
    return {w for w in re.sub(r"[^A-Za-z]+", " ", text.lower()).split()
            if len(w) >= 4 and w not in DESC_STOP}

# ── scan every zip: name tokens for ALL, hook set for hookers, i3d flag to tell
#    pure-SCRIPT mods (the redundancy domain) from vehicles/maps/placeables ──────
mod_hooks   = {}   # mod -> set("Class.method")   (mods that install Utils hooks)
mod_tokens  = {}   # mod -> name-token set        (ALL zips, for the name signal)
mod_content = {}   # mod -> bool: has .i3d (3D content = vehicle/map/placeable)
zips = [f for f in os.listdir(MODS_DIR) if f.endswith(".zip")]
for fn in zips:
    mod = fn[:-4]
    mod_tokens[mod] = tokens(fn)
    has_i3d, blob = False, ""
    try:
        with zipfile.ZipFile(os.path.join(MODS_DIR, fn)) as z:
            names = z.namelist()
            has_i3d = any(n.lower().endswith(".i3d") for n in names)
            for e in names:
                if e.lower().endswith(".lua"):
                    try: blob += z.read(e).decode("utf-8", "ignore")
                    except: pass
    except: pass
    mod_content[mod] = has_i3d
    if "Function" in blob:                                  # installs Utils.*Function hooks
        hooks = set()
        for m in OW.finditer(blob): hooks.add((m.group(1) or m.group(3)) + "." + (m.group(2) or m.group(4)))
        for m in AP.finditer(blob): hooks.add((m.group(1) or m.group(3)) + "." + (m.group(2) or m.group(4)))
        if hooks: mod_hooks[mod] = hooks

N = len(mod_hooks)
# NAME signal domain = pure-script mods (no 3D content). This catches behaviour mods that
# install NO detectable hooks (e.g. CropDestructionOutsideFields) while excluding the
# vehicle/map version-dupes (a separate cleanup task) that flooded the name signal.
name_mods = sorted(m for m in mod_tokens if not mod_content.get(m, False))
print(f"scanned {len(zips)} zips -> {N} hooking mods; {len(name_mods)} pure-script mods (name signal)")

# ── function popularity -> idf weight ────────────────────────────────────────
df = defaultdict(int)
for hooks in mod_hooks.values():
    for f in hooks: df[f] += 1
def idf(f): return math.log((N + 1) / (df[f] + 1)) + 1.0   # rare fn -> high weight
DISTINCTIVE_DF = 15   # a fn hooked by <=15 mods is "distinctive" enough to mean something

cand = {}   # (a,b) -> dict(reason fields)

# ── signal 1: weighted hook overlap ──────────────────────────────────────────
# invert to function -> mods, only iterate pairs that actually co-hook something
fn_to_mods = defaultdict(list)
for mod, hooks in mod_hooks.items():
    for f in hooks: fn_to_mods[f].append(mod)
pair_shared = defaultdict(set)
for f, ms in fn_to_mods.items():
    if len(ms) < 2: continue
    for i in range(len(ms)):
        for j in range(i + 1, len(ms)):
            a, b = sorted((ms[i], ms[j]))
            pair_shared[(a, b)].add(f)

for (a, b), shared in pair_shared.items():
    distinctive = [f for f in shared
                   if df[f] <= DISTINCTIVE_DF and f.split(".", 1)[0] not in HOOK_STOP_CLASS]
    if len(distinctive) < 2: continue
    score = sum(idf(f) for f in distinctive)
    # overlap coefficient over the smaller footprint, to favour mods that are MOSTLY the same
    coeff = len(shared) / max(1, min(len(mod_hooks[a]), len(mod_hooks[b])))
    if score >= 8.0 or (len(distinctive) >= 3 and coeff >= 0.5):
        cand[(a, b)] = {"hook_score": round(score, 1), "coeff": round(coeff, 2),
                        "shared": sorted(distinctive, key=lambda f: -idf(f))[:8],
                        "name_tokens": []}

# ── signal 2: name-token similarity (pure-script mods, incl. non-hookers) ─────
for i in range(len(name_mods)):
    for j in range(i + 1, len(name_mods)):
        a, b = name_mods[i], name_mods[j]
        if base_name(a) == base_name(b): continue   # co-dependent parts of one mod, not dupes
        ta, tb = mod_tokens.get(a, set()), mod_tokens.get(b, set())
        shared_t = ta & tb
        if len(shared_t) < 2: continue
        ratio = len(shared_t) / max(1, min(len(ta), len(tb)))
        if ratio < 0.5: continue                            # must be MOSTLY the same words
        key = (a, b)
        rec = cand.get(key) or {"hook_score": 0.0, "coeff": 0.0, "shared": [], "name_tokens": []}
        rec["name_tokens"] = sorted(shared_t)
        cand[key] = rec

# ── enrich with modDesc descriptions: the purpose text that lets a HUMAN judge. We do
#    NOT auto-suppress on it (an algorithm guessing purpose is what produced the false
#    positives) — we attach it for the view to show, and use description overlap only to
#    RANK likely-same-purpose pairs above likely-different ones.
desc_cache = {}
def get_desc(mod):
    if mod not in desc_cache: desc_cache[mod] = moddesc_text(mod)
    return desc_cache[mod]
for (a, b), rec in cand.items():
    da, db = get_desc(a), get_desc(b)
    rec["desc_a"], rec["desc_b"] = da, db
    ta, tb = desc_tokens(da), desc_tokens(db)
    rec["desc_overlap"] = round(len(ta & tb) / max(1, min(len(ta), len(tb))), 2) if ta and tb else 0.0

# rank: BOTH-signal first; then name pairs whose DESCRIPTIONS also overlap (likely truly
# the same job) above name pairs whose descriptions diverge (likely a false positive).
def confidence(rec):
    both = rec["hook_score"] > 0 and rec["name_tokens"]
    return (2 if both else 1 if rec["name_tokens"] else 0, rec.get("desc_overlap", 0.0), rec["hook_score"])
ranked = sorted(cand.items(), key=lambda kv: confidence(kv[1]), reverse=True)

# ── console report ───────────────────────────────────────────────────────────
print(f"\n=== {len(ranked)} redundancy candidate pair(s) ===")
print("(advisory — review and pull at your discretion; nothing is changed)\n")
def tag(rec):
    # BOTH name + system overlap = high-confidence duplicate. Name-only = same purpose by
    # name. System-only = they touch the same functions, which may be redundancy OR a
    # conflict ModMixer already manages — flagged for review, not asserted as duplicate.
    if rec["hook_score"] > 0 and rec["name_tokens"]: return "DUPE? "
    if rec["name_tokens"]: return "NAME  "
    return "SYSTEM"
for (a, b), rec in ranked[:60]:
    print(f"[{tag(rec)}] {a}  <>  {b}")
    if rec["name_tokens"]:
        print(f"          name: {', '.join(rec['name_tokens'])}   desc-overlap {rec.get('desc_overlap', 0)}")
    if rec["hook_score"] > 0:
        print(f"          hooks(x{len(rec['shared'])}, score {rec['hook_score']}, overlap {rec['coeff']}): {', '.join(rec['shared'][:6])}")
    if rec.get("desc_a"): print(f"          A: {rec['desc_a'][:88]}")
    if rec.get("desc_b"): print(f"          B: {rec['desc_b'][:88]}")

# ── emit Lua data for the Switchboard 'Redundancy' view ──────────────────────
def luaq(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
L = ["-- mm_redundancy_generated.lua  (auto-generated by tools/gen_redundancy.py).",
     "-- ADVISORY duplicate-purpose candidates. The Switchboard 'Redundancy' view lists",
     "-- these so the player can mute one and pull it later. Never auto-removed.",
     "ModMixerRedundancy = {"]
for (a, b), rec in ranked:
    both = rec["hook_score"] > 0 and bool(rec["name_tokens"])
    conf = "high" if both else ("med" if rec["name_tokens"] else "low")
    shared = "{ " + ", ".join(luaq(f) for f in rec["shared"]) + " }"
    toks   = "{ " + ", ".join(luaq(t) for t in rec["name_tokens"]) + " }"
    L.append("    { a = %s, b = %s, confidence = %s, hookScore = %s, descOverlap = %s, "
             "sharedFns = %s, nameTokens = %s, descA = %s, descB = %s },"
             % (luaq(a), luaq(b), luaq(conf), rec["hook_score"], rec.get("desc_overlap", 0.0),
                shared, toks, luaq(rec.get("desc_a", "")[:300]), luaq(rec.get("desc_b", "")[:300])))
L.append("}")
open(OUT_LUA, "w", encoding="utf-8").write("\n".join(L) + "\n")
print(f"\nwrote {OUT_LUA}  ({len(ranked)} pairs)")
