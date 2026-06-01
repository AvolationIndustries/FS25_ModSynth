# FS25 ModSynth

> Mods silently break each other. ModSynth tells you what's fighting what — and fixes what it safely can.

Farming Simulator 25 mods patch the game by wrapping its Lua functions. When two mods wrap the **same** function, the one that loads last usually wins — and the other mod's work disappears with no error, no crash, and no explanation. A HUD overlay that never shows. A price tweak that does nothing. An economy mod quietly overridden by another.

**ModSynth** analyses every hook in your mod stack at startup, reports exactly what conflicts with what (and whether it matters), warns you about genuinely incompatible mods, and — where it is safe and provably correct — repairs the hook chain automatically.

---

## What it does

- **Conflict report every launch.** A severity-rated, plain-English report is written to `modSynth.log` (next to your game log). CRITICAL / HIGH / MEDIUM / INFO, with an explanation of each.
- **Catches the conflicts that matter.** Broken overwrites that discard another mod's work, load-order-sensitive chains, and mods that replace the same system entirely.
- **On-screen warning** for truly incompatible mod pairs (e.g. two animal overhauls, two "build anywhere" mods) so you know to remove one.
- **Safe automatic repairs.** Where a fix is mathematically correct it is applied at runtime — repairing broken hook chains and suppressing known third-party log spam (e.g. a duplicate-registration bug that floods the log with hundreds of errors).
- **Quiet by default.** Harmless chains are summarised, not shouted. No configuration, no gameplay changes, zero runtime cost after map load. Multiplayer-safe.

## New in 1.1

1.0 matched your mods against a hand-written catalogue of known conflicts — so anything not on that list was invisible.

1.1 adds **generic, scan-based detection**. ModSynth now ships a conflict database generated from a full static scan of hundreds of script mods. At load it cross-references that database against your install and reports **every** conflict present — including brand-new mod combinations no one has documented. Anything it detects but hasn't hand-verified is flagged `[SCAN] uncatalogued` so it never slips through silently. The in-game log is capped (full detail always in `modSynth.log`), and the hand-verified catalogue grew from 40 to **57** entries.

## How it works

ModSynth ships as **two mods** (this is required, not cosmetic):

| Mod | Loads | Role |
|-----|-------|------|
| `FS25_000_ModSynthHooks` | first (`000_`) | Patches `Utils.overwrittenFunction` / `appendedFunction` so every hook any mod installs is recorded in a registry. Must run before any other mod hooks anything. |
| `FS25_zzz_ModSynth` | last (`zzz_`) | Reads the registry, runs the conflict analysis + catalogue, applies safe repairs, and writes the report. Loads last so it sees every other mod. |

`FS25_zzz_ModSynth` declares `FS25_000_ModSynthHooks` as a dependency, so installing the main mod pulls in the hooks mod automatically.

The 1.1 conflict database (`scripts/ms_catalogue_generated.lua`) is produced offline by the included `tools/scan_all_hooks.py`, which reads **every** `.lua` in **every** mod and classifies each multi-hook function (true stomp vs. safe chain) using source-level analysis — colon/dot method resolution, super-call detection, append/prepend/manual-chain handling. The mod consumes that dataset at runtime; the heavy analysis stays offline.

## Installation

1. Subscribe/download both `FS25_zzz_ModSynth` and `FS25_000_ModSynthHooks` (the second is pulled automatically as a dependency on ModHub).
2. Launch the game. After the map loads, open `modSynth.log` (in your FS25 profile folder, next to `log.txt`) for the full report. *(If file writing is restricted in your environment, the same report falls back into `log.txt` itself — nothing is lost.)*
3. Act on anything marked CRITICAL or HIGH; the on-screen warning will tell you if you have two flatly incompatible mods.

## Regenerating the conflict dataset (advanced)

The scanner is included at `tools/scan_all_hooks.py` (set the `MODS_FOLDER` and `OUT_DIR` paths at the top of the file for your system). The shipped dataset comes from a broad script-mod corpus; to regenerate it from your own install or a different corpus:

```bash
python tools/scan_all_hooks.py                       # scans the mods folder, re-emits ms_catalogue_generated.lua
python tools/scan_all_hooks.py --emit-only           # re-emit from the last scan without rescanning
```

Then rebuild the `FS25_zzz_ModSynth` zip. Conflicts not yet hand-verified will appear as `uncatalogued` — verify at source and add a catalogue entry to give them an authoritative verdict.

## Known limitations

- **Best-effort name matching.** Catalogue entries identify mods by filename. A conflict whose entry was generated against a version-suffixed download name (e.g. `FS25_Courseplay_V8_1_0_3`) may not match a user running a differently-named build. Most mods use stable names and match fine.
- **Dataset freshness.** Scan-based detection only knows what was scanned. Re-run the scanner when the mod ecosystem moves.
- **Detection, not auto-fix, for most conflicts.** ModSynth repairs only the cases that are provably safe. Everything else it explains — the decision stays yours.

## Changelog

**1.1.0.0**
- Added generic scan-based conflict detection (offline registry-walker → bundled `ModSynthScan` dataset).
- Bundled a 280+ conflict database generated from a broad script-mod scan.
- In-game log capped with overflow summary; full detail always in `modSynth.log`.
- Hand-verified catalogue expanded 40 → 57 entries.
- Hardened logging: guarded against a restricted `io` library (the mod can never fail to load over file access), with automatic fallback to the game log so the report is never lost.

**1.0.0.0**
- Initial release: registry-based hook tracking, 40-entry hand-verified conflict catalogue, safe runtime repairs, incompatible-pair on-screen warnings, multiplayer support.

## Links & support

- **GitHub:** https://github.com/AvolationIndustries/FS25_ModSynth
- **Discord:** https://discord.gg/G2AvqwVJ

Found a conflict ModSynth got wrong, or a combination it should know about? Open an issue or drop it in the Discord.

---

*By Avolation Industries.*
