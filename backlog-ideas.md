# Death Replay — future improvements backlog

Items explicitly out of scope for v1, captured here so they don't get lost. Pick from this list when planning v1.1 / v2.

Each entry: **what**, **why deferred from v1**, **rough work needed**.

---

## 1. Attacker name on each damage event ("Killed by: Grimnir (Slayer)")
- **Why deferred:** `WORLD_OBJ_COMBAT_EVENT(objectID, amount, combatEvent, abilityID)` only carries the defender's id, not the attacker's. Approach A (pure event-driven) was picked over the hybrid that scrapes the combat text log for attacker names.
- **Work needed:**
  - Investigate whether `WORLD_OBJ_COMBAT_EVENT` exposes a hidden 5th arg or whether another event (e.g. an `OBJ_ATTACKED_BY_*`-style event) carries the attacker.
  - Fallback: add the hybrid path — hook `TextLogGetUpdateEventId("Combat")` and correlate by (damage amount + timestamp ± 100ms) to extract attacker name from formatted log lines. Reference: Deathblow2/Deathblow2.lua's combat log handling.
  - SavedVariables shape already has room — just add `attacker` field to event entries; old captures render with `attacker = nil` as "unknown".

## 2. Misses / mitigations (PARRY / BLOCK / DISRUPT / EVADE / IMMUNE / ABSORB)
- **Why deferred:** Noisy in a typical scenario — would dominate the timeline and distract from the killing-blow story. Mockup didn't show them.
- **Work needed:**
  - Map remaining `GameData.CombatEvent.*` constants (wsct/wsct.lua:66-96 already enumerates them).
  - Extend the `kind` enum: `MISS_PARRY`, `MISS_BLOCK`, etc.
  - Add a third filter checkbox in the GUI ("mitigations") — default OFF so they don't dominate.
  - Storage cost: roughly doubles event count per death. Bump `MAX_EVENTS_BUFFERED` if needed.

## 3. Outgoing damage (what you dealt before dying)
- **Why deferred:** Out of scope for "why I died" question. Adds another dimension to the UI.
- **Work needed:** Filter `WORLD_OBJ_COMBAT_EVENT` to events where the *attacker* is the player. Needs the same self-id resolution as item #1 but from the other side.

## 4. Incoming heals
- **Why deferred:** Healing is its own combat-event flavor and the user explicitly chose "Damage + buff/debuff changes" scope. Would let you see "healer ghosted me for 4s before death".
- **Work needed:**
  - Verify which `GameData.CombatEvent.*` constants are healing (likely a `HEAL` / `ABILITY_HEAL` enum).
  - Extend `kind` enum: `HEAL_IN`.
  - Add a fourth filter checkbox ("heals").

## 5. Healer detection ("who healed me when")
- **Why deferred:** Depends on item #4 plus attacker/source name on heal events (same problem as item #1).
- **Work needed:** Items #1 and #4 first.

## 6. HP curve in UI
- **Why deferred:** Requires polling `GameData.Player.hitPoints.current` on `OnUpdate` to sample frequently enough for a smooth curve. State polling was explicitly out of scope for v1.
- **Work needed:**
  - Add `OnUpdate` poll (every 0.25s) appending `{ dt = ..., kind = "HP_SAMPLE", current = ..., max = ... }` to the buffer when `isPvpNow`.
  - GUI: render a small ASCII or texture-based HP curve above the timeline. Reference the Rich-scope mockup from brainstorming.
  - Storage cost: ~40 samples per death over 10s. Small.

## 7. Other state polling: morale level, AP, target name, guard distance at death
- **Why deferred:** Same reason as #6 — no polling in v1.
- **Work needed:**
  - Add per-tick poll of relevant `GameData.Player.*` fields (`morale`, `actionPoints.current`, target via `GameData.Player.target.*`).
  - Guard distance is the trickiest — may need to identify guard target (group member with Guard buff on you) then compute distance via world coords. Investigate `GameData.Player.worldPosition` or similar.
  - Add a "state" filter checkbox in the GUI.

## 8. Multi-language ability names
- **Why deferred:** `GetAbilityName(abilityID)` returns whatever the game gives. If a non-English client uses the addon, names are localized — which is correct for that user, but breaks if SavedVariables are shared across clients.
- **Work needed:** Only matters if we ever build sharing / export features. Until then, no action.

## 9. Sharing / export
- **Why deferred:** Sandbox blocks file I/O and HTTP (see memory: `war-ror-addon-sandbox-limits`). Only "export" path is print-to-chat dump.
- **Work needed:**
  - v2 could add `/dr export N` slash command that dumps death #N as formatted chat lines for the user to copy.
  - Real sharing (Discord, web) requires an external companion process — out of addon scope entirely.

## 10. Auto-popup on death (alternate trigger mode)
- **Why deferred:** User picked on-screen indicator + slash command over auto-popup; auto-popup was rejected as annoying mid-rez.
- **Work needed:** Add a config flag and a checkbox in eventual options UI. Trivial code, just hadn't been requested.

## 11. Configurable buffer window length / max-deaths-stored
- **Why deferred:** Defaults (10s, 5 deaths) chosen for v1; values stored in `SavedVariables.config` but not user-exposed.
- **Work needed:**
  - Add `/dr config bufferWindow 15` / `/dr config maxDeaths 10` slash subcommands, or a small options window.
  - Validate ranges (e.g. cap buffer at 30s, max-deaths at 20) to prevent SavedVariables bloat.

## 12. Death context detail: "configurable capture mode" beyond hardcoded PvP-only
- **Why deferred:** Brainstorming step 3's third option ("configurable via slash command") was not chosen; PvP-only was chosen. Config field `captureMode` already lives in SavedVariables shape for future use.
- **Work needed:** Wire `/dr capture pvp|all|scenario` to flip the flag; `inPvpContext()` honors it.

## 13. Indicator: bring back amber/gray tint instead of show/hide
- **Why deferred:** v1 initial Indicator XML used `<Texture texture="EA_Icons" textureSlice="...">` inside a nested `<Windows>` block, which is non-standard WAR XML and triggered the game's "Errors detected!" load warning. Fixup `41692d8` deleted the inner Window+Texture entirely and replaced `WindowSetTintColor` with `WindowSetShowing` — widget now hides when there are no unviewed deaths, shows (default skin border, no icon inside) when there are.
- **Work needed:**
  - Inside the Indicator window, add a `<DynamicImage>` child following the PotionBar pattern (`Interface/AddOns/PotionBar/source/Floating.xml` line uses `texture="shared_01" slice="Radio-Button"` for a tintable background; `<DynamicImage name="$parentIcon" textureScale="0.719" handleinput="false">` for an icon placeholder that gets a texture set via `DynamicImageSetTexture(name, texture, x, y)` from Lua).
  - Restore `LIT_COLOR` / `DIM_COLOR` constants and `WindowSetTintColor` call in `DeathReplayIndicator.Recompute()`, targeting the new DynamicImage's resolved name.
  - Keep `WindowSetShowing` if you want the widget to also fully hide when dim — or just rely on the tint alone (matches the original v1 design intent more closely).
