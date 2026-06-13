# ModMixer v1.4 — Menu De-Clutter (spec)

Status: PROPOSED (post-launch). Owner: ModMixer. Risk: low (UI-only). Author trigger:
the 2026-06-13 sidequest — double-ESC in every menu + UpgradeYourFactory's UPGRADE button
displaced by ProductionStorageControl's SPAWN GOODS on the Productions page.

---

## 1. Why

FS25 menu footers have a **fixed number of physical button slots**. When several mods add
buttons to the same page, the surplus is silently dropped and two distinct bugs appear:

- **Redundant buttons** — two mods register the *same* action (e.g. two `MENU_BACK`), so the
  footer shows a duplicate (the "ESC ESC" Avo sees in every menu). Pure waste of a slot.
- **Overflow** — too many *distinct* buttons for the slots, so a real one vanishes with no
  warning (UpgradeYourFactory's UPGRADE, appended last, falls off when SPAWN GOODS is present).

Both are exactly the cross-mod friction ModMixer exists to resolve — but in the menu layer,
which the current build only *reorders/vetoes*, never *cleans up*.

## 2. Root cause (engine receipt)

- `TabbedMenu:assignMenuButtonInfo(menuButtonInfo)` — `gui/base/TabbedMenu.lua:326`. It lays
  buttons out with `for i, button in ipairs(self.menuButton)` (line 329) and pulls
  `menuButtonInfo[i]` per **physical slot**. Any entry past `#self.menuButton` is never drawn.
- A frame's `updateMenuButtons` builds `self.menuButtonInfo`; each mod `Utils.appendedFunction`s
  it and `table.insert`s its own button. Append order = insert order = slot index. The mod that
  loads last lands at the highest index → first to overflow. (UpgradeYourFactory > Production-
  StorageControl alphabetically, so UPGRADE overflows.)
- `assignMenuButtonInfo` is the **single chokepoint**: it runs once at display time, AFTER every
  mod's append has finished, for EVERY page (stock + modded). One wrap covers all menus.

## 3. The feature — two parts

### A. Auto-fold redundant buttons  (the headline — "fold away the ESC")
Collapse footer entries that are genuinely the same button, freeing the slot. This removes the
second ESC AND, on the Productions page, frees the slot so SPAWN GOODS *and* UPGRADE both fit —
no reorder needed.

**Fold policy (conservative by default):**
- Fold when entries are an EXACT duplicate: same `inputAction` AND same display `text` AND same
  `callback` (or both fall through to the action's default callback). Keep the first; drop the rest.
- "Exit family" option (setting, default ON): also fold a 2nd+ `MENU_BACK`/`MENU_CANCEL`/`MENU_ACCEPT`
  even if text differs — they're functionally one button in the footer. This is what kills a
  MENU_BACK + MENU_CANCEL "ESC ESC" pair that the exact-match rule would miss.
- NEVER fold two DIFFERENT actions that merely share a key — that's a keybind conflict (part B /
  the parked keybind detector), not redundancy. Surface it, don't silently hide it.

### B. Surface footer overflow  (make it explicit)
When `#menuButtonInfo > #self.menuButton`, the page is overflowing. ModMixer already tracks
`InGameMenuProductionFrame.updateMenuButtons` (and siblings) as curated UI targets, so:
- **Review tab advisory:** "Productions footer: 7 buttons, 5 slots — 2 hidden: UPGRADE
  (UpgradeYourFactory), … . Reorder or veto on the Advanced 'Update Menu Buttons' row to choose."
- **Attribute each button to its mod** via the batch-4 FENV fingerprint: `getfenv(button.callback)`
  → owning mod env → name. So the advisory can say *which mod's* button vanished, not just "one".
- The fix levers already exist (Advanced → Update Menu Buttons → reorder/veto). Part B just makes
  the problem legible instead of invisible.

## 4. Technical design

- **Hook:** overwrite `TabbedMenu.assignMenuButtonInfo` (ModMixer loads first). Wrapper:
  `function(self, info, ...) local cleaned, report = declutter(self, info); ModMixer.recordFooter(self, report); return super(self, cleaned, ...) end`.
  Pass a NEW deduped list to super; never mutate the frame's stored `menuButtonInfo` (so the next
  rebuild is unaffected).
- **declutter(self, info):**
  - `slots = #self.menuButton` (the physical cap, read live from the menu).
  - Walk `info` in order; key each entry `k = inputAction .. "|" .. (text or "") .. "|" .. tostring(callback)`;
    plus the exit-family rule. Skip exact/duplicate keys. Build `out`.
  - `report = { page = self.currentPageName or class, slots = slots, total = #info, kept = #out,
    folded = #info-#out, overflow = max(0, #out-slots), hidden = {names of entries at index>slots
    via fenvMod(callback)} }`.
  - Return `out, report`.
- **Attribution:** reuse `fenvMod()` from ModMixerHooks (already exported on `Utils.__ms_*`) to map
  `button.callback`'s defining env → mod name. Falls back to "(unknown)".
- **Cost:** runs only on menu button refresh (open / selection change), never per-frame. Negligible.

## 5. Safety & risks

- UI-only, fully `pcall`-guarded; on any error, fall back to the original `info` untouched.
- Conservative fold can only remove a button that is **identical** to one already kept → no unique
  action is ever lost. The exit-family rule is the one judgement call → gate it behind a setting.
- Applies to ModMixer's own Switchboard footer too (harmless — no dups there).
- Honors `MODMIXER_SAFE_MODE.txt` (skip declutter in safe mode, like vetoes/reorders).
- Default-ON for exact-duplicate fold (safe); overflow surfacing is advisory-only.

## 6. UI surfacing

- **Live tab toggle:** "Menu de-clutter" (fold redundant footer buttons) — ON default. Second toggle
  "Fold duplicate exit buttons (ESC)" — ON default. Instant (next menu open reflects it).
- **Review tab:** per-page overflow advisories with named hidden buttons (part B).
- **Advanced:** the existing `Update Menu Buttons` row (reorder/veto) is the manual lever for
  genuine overflow — cross-reference it from the Review advisory.

## 7. Testing plan

1. In-game A/B: open Contracts → second ESC folds to one with feature ON, returns with it OFF.
2. Productions page on a pallet-spawner factory → with declutter ON + a freed slot, SPAWN GOODS
   AND UPGRADE both show (the end-to-end win).
3. Confirm stock single-action footers are untouched (no legit button dropped).
4. lupa battery + `TabbedMenu` wrap compiles; GIANTS TestRunner PASS; deploy via build.py.

## 8. Phasing

- **v1.4 P1:** exact-duplicate + exit-family fold (kills the double-ESC, frees slots). Ship.
- **v1.4 P2:** overflow surfacing in Review with fenv-named hidden buttons.
- **Future:** merge with the parked keybind-conflict detector — same-key/different-action is the
  case declutter must NOT fold, and the keybind detector is where the user resolves it.

## 9. Open questions

- Exit-family membership: is ESC ever two genuinely-different actions a user needs both of? (Assume
  no; gate behind the setting.)
- Per-menu slot counts vary by page layout — read `#self.menuButton` live (done) rather than assume.
- Interaction with a user reorder on `updateMenuButtons`: declutter runs AFTER, at assign time, so a
  reorder picks the order and declutter trims dups within it — they compose cleanly.
