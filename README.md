# FS25 ModMixer

> Mods silently break each other. ModMixer shows you what's fighting what — and gives you the switchboard to settle it.

Farming Simulator 25 mods patch the game by wrapping its Lua functions. When two mods wrap the **same** function, the one that loads last usually wins — and the other mod's work disappears with no error, no crash, and no explanation. A HUD that never shows. A price tweak that does nothing. Wheel physics quietly overridden by another mod.

**ModMixer** records every hook in your mod stack as it installs, reports exactly what conflicts with what (and whether it matters), and gives you an in-game control panel — the **Switchboard** — to rank, reorder, mute, park and diagnose your mods.

---

## The Switchboard

Open the in-game menu and look for the ModMixer icon. Seven tabs:

| Tab | What it's for |
|-----|---------------|
| **Simple** | Rank your mods — a higher mod wins its conflicts everywhere. All most setups ever need. |
| **Live** | Instant settings your mods expose (toggles & sliders). Applied immediately, no restart. |
| **Category** | The same ranking, one area at a time: wheels, HUD, economy, weather… |
| **Advanced** | Every contested function with its full hook chain — who runs first, who overrides whom (`[ow!]` = positioned to stomp). Move mods within a chain, or pick a winner to mute a stomp. |
| **Review** | Worth a look: likely duplicate mods, known incompatible pairs, HUD overlaps — each with evidence. Dismiss what you've judged; restore any time. |
| **Performance** | Live per-mod cost (ms/frame) against your fps budget, sortable. Park a heavy mod to reclaim its per-frame work without uninstalling it. |
| **Vehicle** | Live diagnostics of the machine you're in: damage, wear, engine temperature/RPM, speed, mass, per-wheel grip (spot a veer). |

Every row has a plain-English explanation in the help box. On top of that you still get the classic boot report (`ModMixer.log`, next to your game log) and an on-screen warning when two flatly incompatible mods are installed.

## Installation

1. Drop `FS25_0_ModMixer.zip` into your mods folder.
2. **Do not rename the zip.** The `0_` prefix makes ModMixer load before your other mods — that's how it sees every hook they install.
3. Launch the game, enable ModMixer for your savegame, and open the Switchboard from the in-game menu.

Your settings (rankings, reorders, dismissals) persist in `modSettings/FS25_ModMixer/switchboard.xml`.

## Built safe

ModMixer can change load behaviour, so it's engineered to never cost you a save:

- **Restart-gated levers.** Structural changes (reorder, mute) apply on the next restart — nothing is rewired mid-session.
- **Load-critical locks.** Functions involved in loading and saving (farm creation, savegame read/write…) can never be vetoed; the UI locks them.
- **Boot watchdog.** If a launch doesn't complete, the next one automatically starts in safe mode with all levers off — your game always loads. If you see ModMixer report safe mode after a crash, that's the watchdog doing its job: fix or remove whatever crashed, and play on.
- **Manual kill switch.** Create an empty file `MODMIXER_SAFE_MODE.txt` in `modSettings/FS25_ModMixer/` to force safe mode on the next launch (your config is kept).

## Multiplayer

ModMixer loads and reports per client. The Switchboard's levers (reorder, mute, park) are designed for singleplayer.

## Power users

- **Opt-in performance probes:** create `MODMIXER_HOOKPROBE.txt` in `modSettings/FS25_ModMixer/` and restart to enable per-hook and per-spec timing (console: `mmLoad`, `mmCost`, `mmHookCost` — commands are case-sensitive). Zero overhead when the file is absent.
- **Datasets:** the bundled conflict/hookmap data is generated offline by the scripts in `tools/` from a large script-mod corpus; the live interceptor keeps detection current for mods the dataset has never seen.

## Known limitations

- Hooks installed late (from inside a mod's load/update callbacks) can show as `(unknown — maybe: …)`. They're visible and counted, but a hook without a name can't be vetoed, reordered around, or ranked — ModMixer refuses those levers loudly instead of guessing. An attribution upgrade is planned.
- A few HUD classes (e.g. the top info bar) load after mods hook them, so those overlaps are advisory — ModMixer flags them but can't attribute or mute a HUD draw.
- Park reaches mods built as event listeners (most script mods); specialization-based mods can't be parked yet.
- UI text is English for now; localisation is planned.

## Changelog

**1.3.0.0**
- The **Switchboard**: seven-tab in-game control panel (Simple / Live / Category / Advanced / Review / Performance / Vehicle).
- Conflict levers: global and per-category mod ranking, per-conflict reorder and make-winner — all restart-gated.
- Review hub: likely duplicates, known incompatibles, HUD overlaps (live-sourced, self-updating).
- Performance tier: live per-mod ms/frame vs your fps budget, sortable columns, Park (hibernate).
- Vehicle tab: live machine diagnostics down to per-wheel grip.
- Safety net: boot watchdog with automatic safe-mode recovery, load-critical hook locks, manual kill switch.
- Plain-English help for every catalogued function.

**1.2.0.0**
- Single mod — no companion preloader required. (Project renamed from ModSynth.)

**1.1.0.0**
- Generic scan-based conflict detection (bundled dataset + live interceptor); hand-verified catalogue expanded; hardened logging with game-log fallback.

**1.0.0.0**
- Initial release: registry-based hook tracking, hand-verified conflict catalogue, safe runtime repairs, incompatible-pair warnings.

## Links & support

- **GitHub:** https://github.com/AvolationIndustries/FS25_ModMixer
Found a conflict ModMixer got wrong, or a pair it should know about? Open an issue on GitHub.

---

*By Avolation Industries.*
