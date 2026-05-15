# Death Replay — v1 design

**Date:** 2026-05-15
**Status:** Draft (pending user review)
**Target game version:** Warhammer Online: Return of Reckoning
**Related docs:** [backlog-ideas.md](../../../backlog-ideas.md) — explicit non-goals and future improvements

---

## Context

When you die in a PvP fight in WAR, the game shows a brief death recap (one line, "killed by X") and that's it. The combat log scrolls past, the scoreboard is gone in 30 seconds, and you're left guessing what actually killed you: which ability dealt the killing blow, what debuffs were on you, whether you had defensive cooldowns up, whether your guard was in range.

Existing addons partially address this:
- **Deathblow2** shows the one-line "killed by" but no timeline context.
- **wsct** displays combat events in real time but doesn't persist them or scope them to a death window.

**Goal:** When you die in PvP, capture the last ~10s of combat events into a persistent, browsable timeline. After-the-fact analysis lets you understand why you died and adjust gear/play.

**Out of scope for v1:** attacker name on each hit (deferred — see backlog item #1), misses/mitigations, healing, state polling (HP curve, morale, guard distance), auto-analysis. Pure event-driven approach for the smallest viable shippable build.

---

## Goals

- Capture last ~10s of incoming damage events and buff/debuff changes whenever the player dies in a PvP context (scenario or open RvR zone).
- Persist last 5 captured deaths across sessions in `SavedVariables`.
- Provide a movable on-screen indicator that lights up when a new unviewed death is captured.
- Provide a slash command (`/dr`) and indicator click to open a window browsing captured deaths.
- Filter the rendered timeline by event type (damage / buffs).

## Non-goals (v1)

See [`backlog-ideas.md`](../../../backlog-ideas.md) for the full list with rationale. Highlights: attacker names, misses, heals, HP curve, auto-analysis, sharing/export, configurable trigger mode, configurable buffer/storage limits, configurable capture context.

---

## Architecture

### File layout

```
Interface/AddOns/DeathReplay/
├── DeathReplay.mod              -- manifest XML
├── DeathReplay.lua              -- events, ring buffer, death detection, slash cmd
├── DeathReplay_GUI.xml          -- replay window definition
├── DeathReplay_GUI.lua          -- replay window controller
├── DeathReplay_Indicator.xml    -- on-screen toggle button definition
└── DeathReplay_Indicator.lua    -- indicator controller (click, lit/dim)
```

Layout mirrors the QueueQueuer convention used across this AddOns folder: one core `.lua` for logic, one `.xml` + controller per window.

### Manifest highlights (`DeathReplay.mod`)

- Dependencies: `LibSlash`, `EATemplate_DefaultWindowSkin`
- `<SavedVariables name="DeathReplay_SavedVariables"/>` — engine handles persistence (per `Interface/AddOns/QueueQueuer/QueueQueuer.mod:46-48` pattern)
- `<OnInitialize>`: calls `DeathReplay.OnInitialize` + `CreateWindow` for main GUI (hidden) and indicator (visible)
- `<OnShutdown>`: calls `DeathReplay.OnShutdown` for clean unregister
- `<OnUpdate>`: calls `DeathReplay.OnUpdate(elapsed)` for ring buffer trim tick

---

## Components

All in `DeathReplay.lua` unless noted.

### 1. EventBus
Registers / unregisters event handlers in `OnInitialize` / `OnShutdown`. Mirrors the pattern in `Interface/AddOns/QueueQueuer/QueueQueuer.lua:436-477`.

Events subscribed:
| Event | Handler | Purpose |
|---|---|---|
| `SystemData.Events.WORLD_OBJ_COMBAT_EVENT` | `DeathReplay.OnCombatEvent` | Capture incoming damage |
| `SystemData.Events.PLAYER_EFFECTS_UPDATED` | `DeathReplay.OnEffectsUpdated` | Diff buff/debuff changes |
| `SystemData.Events.PLAYER_CUR_HIT_POINTS_UPDATED` | `DeathReplay.OnHitPointsUpdated` | Detect death (HP → 0) |
| `SystemData.Events.LOADING_END` | `DeathReplay.OnContextMaybeChanged` | Recompute `isPvpNow` cache, seed buff baseline |
| `SystemData.Events.PLAYER_AREA_NAME_CHANGED` | `DeathReplay.OnContextMaybeChanged` | Recompute `isPvpNow` cache |
| `SystemData.Events.SCENARIO_INSTANCE_JOIN_NOW` | `DeathReplay.OnContextMaybeChanged` | Recompute `isPvpNow` cache |

Reference impls already in the codebase:
- `WORLD_OBJ_COMBAT_EVENT` signature `(objectID, amount, combatEvent, abilityID)` — `Interface/AddOns/wsct/wsct.lua:499`
- `GameData.CombatEvent.*` enum — `Interface/AddOns/wsct/wsct.lua:66-96`
- `PLAYER_EFFECTS_UPDATED` + `GetBuffs(GameData.BuffTargetType.SELF)` — `Interface/AddOns/wsct/wsct.lua:420-421`, `Interface/AddOns/Aura/Source/AuraEngine.lua:577`, `Interface/AddOns/BuffHead/Core.lua:179,220`

### 2. PvP context cache
```lua
local isPvpNow = false

local function recomputePvpContext()
  local prev = isPvpNow
  isPvpNow = (GameData.Player.isInScenario == true)
             or isRvrZone(GameData.Player.zone)
  if prev and not isPvpNow then
    recentEvents = {}        -- leaving PvP clears buffer
  end
end
```

`isRvrZone()` checks a hardcoded list of open-RvR zone ids. Reuse the list at `Interface/AddOns/QueueQueuer/QueueQueuer.lua:280-302` (`QueueQueuer.CampaignZones`).

All event handlers gate on `if not isPvpNow then return end` as their first line. Out-of-PvP cost = one boolean check + early return.

### 3. Ring buffer
```lua
local recentEvents = {}             -- chronological list, oldest first
local BUFFER_WINDOW_S = 10
local MAX_EVENTS_BUFFERED = 500     -- hard cap to prevent runaway growth
```

Append on each gated event. `OnUpdate(elapsed)` trims entries older than `BUFFER_WINDOW_S` every ~0.5s. Trim cadence pattern: `Interface/AddOns/QueueQueuer/QueueQueuer.lua:754-771` (`UpdateCooldownBlacklist`).

On append, if `#recentEvents >= MAX_EVENTS_BUFFERED`, drop oldest before pushing.

### 4. Combat event handler
```lua
function DeathReplay.OnCombatEvent(objectID, amount, combatEvent, abilityID)
  if not isPvpNow then return end
  if not isDefenderPlayer(objectID) then return end
  -- Map combatEvent enum -> "HIT" / "DMG_CRIT" / etc.
  -- Resolve ability name via GetAbilityName(abilityID); fall back to nil.
  -- Append { t=now, kind=..., ability=name, abilityId=abilityID, amount=amount, crit=bool }
end
```

`isDefenderPlayer(objectID)` is the one **implementation-time TBD**: confirm correct field on `GameData.Player.*` for player object id. Fallback if no clean match: correlate damage event to next `PLAYER_CUR_HIT_POINTS_UPDATED` showing HP drop.

v1 stores only damage kinds: `HIT`, `ABILITY_HIT`, `CRITICAL`, `ABILITY_CRITICAL` (mapped to `HIT` with `crit` boolean). Misses dropped per non-goal #2 in backlog.

### 5. Buff diff handler
```lua
local lastEffectSnapshot = nil  -- table keyed by (buffId, casterId)
local effectsBaseline = false

function DeathReplay.OnEffectsUpdated(changedEffects, isFullList)
  if not isPvpNow then return end
  if not effectsBaseline then return end   -- baseline not yet seeded
  local current = snapshotEffects(GetBuffs(GameData.BuffTargetType.SELF))
  for key, eff in pairs(current) do
    if not lastEffectSnapshot[key] then
      -- BUFF_GAIN
    end
  end
  for key, eff in pairs(lastEffectSnapshot) do
    if not current[key] then
      -- BUFF_LOSS
    end
  end
  lastEffectSnapshot = current
end
```

Baseline seeded on `LOADING_END` (in `OnContextMaybeChanged`) by reading `GetBuffs(...)` once and setting `effectsBaseline = true`. Prevents login from emitting "gained" for every pre-existing buff.

Keying by `(buffId, casterId)` instead of name prevents re-fires of the same buff from emitting duplicate entries.

### 6. Death detector
```lua
local deathState = "alive"   -- "alive" | "dead"
local captureDone = false

function DeathReplay.OnHitPointsUpdated()
  if not isPvpNow then return end
  local hp = GameData.Player.hitPoints.current
  if deathState == "alive" and hp == 0 and not captureDone then
    captureDeath()
    captureDone = true
    deathState = "dead"
  elseif deathState == "dead" and hp > 0 then
    deathState = "alive"
    captureDone = false
  end
end
```

`captureDone` prevents double-capture if HP=0 re-fires during the respawn animation.

### 7. Capture + persistence
On capture: copy `recentEvents` to a death record (events sorted chronological, `dt` computed relative to death timestamp), prepend to `DeathReplay_SavedVariables.deaths`, FIFO-trim to `config.maxDeathsStored` (5). Light indicator, print one chat line: `"Death Replay captured. /dr to view."`

### 8. Indicator (`DeathReplay_Indicator.lua` + `.xml`)
Small movable frame. Two icon states: dim (no unviewed captures) / lit (≥1 unviewed). Click → `DeathReplay_GUI.Toggle()`. State derived from `any(d.viewed == false for d in deaths)`.

### 9. Replay window (`DeathReplay_GUI.lua` + `.xml`)
Main browsable window:
- Header: death timestamp, zone name, killing-blow ability
- Navigation: ◀ ▶ buttons, `<currentIndex> / <total>` indicator
- Filter row: checkboxes (dmg, buffs) — both default on
- Timeline: scrollable list of `{ dt, kind, label, amount }` rows
- Empty state: when `#deaths == 0`, show `"No deaths captured yet. Die in a scenario or RvR zone to capture your first replay."`

Window state is purely "current view index + filter flags." All death data read from `SavedVariables`; GUI never mutates it (except to set `deaths[i].viewed = true` on navigation).

### 10. Slash command
`LibSlash.RegisterSlashCmd("dr", function(input) DeathReplay.HandleSlash(input) end)` per `Interface/AddOns/QueueQueuer/QueueQueuer.lua:458` pattern. v1 commands:
- `/dr` or `/dr show` — toggle replay window
- (subcommands deferred to backlog items #10, #11, #12)

---

## Data flow

Happy path: single PvP death capture.

```
T-10s ┐  WORLD_OBJ_COMBAT_EVENT → buffer append
      │  PLAYER_EFFECTS_UPDATED  → buff diff → buffer append
      │  OnUpdate (every ~0.5s)  → drop entries older than 10s
      │
T-0.4s│  Final hit: WORLD_OBJ_COMBAT_EVENT → buffer append
T=0   │  PLAYER_CUR_HIT_POINTS_UPDATED (current=0)
      │     isPvpNow == true, deathState == "alive", captureDone == false
      │     → snapshot buffer, compute dt relative to T=0
      │     → prepend to SavedVariables.deaths, trim to 5
      │     → indicator.SetLit(true), chat notification
      │     → deathState = "dead", captureDone = true
      │
T+~5s │  PLAYER_CUR_HIT_POINTS_UPDATED (current > 0 after respawn)
      │     → deathState = "alive", captureDone = false
      │
later │  User clicks indicator or types /dr
      │     → DeathReplay_GUI.Toggle() → show window, deaths[1].viewed = true
      │     → indicator recomputes lit/dim from viewed flags
```

**Why ordering works:** combat resolution → damage event broadcast → HP update broadcast. Killing-blow event lands in the buffer before HP-zero fires, so the captured snapshot already includes it.

---

## SavedVariables shape

```lua
DeathReplay_SavedVariables = {
  version = 1,                          -- bumped on schema change; migration table in OnInitialize
  config = {
    bufferWindowSeconds = 10,           -- not user-exposed in v1
    maxDeathsStored = 5,                -- not user-exposed in v1
    captureMode = "pvp",                -- v1 hardcoded; not user-exposed
  },
  deaths = {                            -- newest first, max 5 entries
    {
      timestamp = 1747000327,           -- os.time() at capture
      zone = "Tor Anroc",               -- GetZoneName(GameData.Player.zone), FixName'd
      zoneId = 2202,
      context = "scenario",             -- "scenario" | "rvr"
      viewed = false,                   -- flips true when user navigates to this death in GUI
      killingBlow = {
        kind = "ABILITY_CRITICAL",
        ability = "Furious Sweep",
        abilityId = 12345,
        amount = 1650,
      },
      events = {                        -- oldest first; dt = seconds before death (negative)
        { dt = -8.1, kind = "HIT",       ability = "Wounding Strike", abilityId = 111,   amount = 420,  crit = false },
        { dt = -6.4, kind = "BUFF_GAIN", name    = "Cleave",          buffId    = 7733,  duration = 8 },
        { dt = -3.2, kind = "HIT",       ability = "Whirling Axe",    abilityId = 222,   amount = 1180, crit = true  },
        { dt = -0.4, kind = "HIT",       ability = "Furious Sweep",   abilityId = 12345, amount = 1650, crit = true, killingBlow = true },
      },
    },
    -- up to 4 more
  },
}
```

**Notes:**
- `dt` (negative seconds relative to death) is stable across `/reloadui`; absolute timestamps are not needed at render time.
- `abilityId` and `buffId` kept raw so future-version re-resolution (`GetAbilityName` / buff metadata) is possible without losing data.
- `kind` enum is `HIT` | `BUFF_GAIN` | `BUFF_LOSS`. Future kinds (`MISS_*`, `HEAL_IN`, `HP_SAMPLE`) tracked in backlog.
- Storage estimate: 5 deaths × ~50 events × ~80 bytes serialized ≈ < 20 KB. Same order as `QueueQueuer_SavedVariables`.

---

## Error handling & edge cases

| # | Case | Handling |
|---|---|---|
| 1 | Self-id on combat events | Implementation begins with 10-line probe to confirm correct `GameData.Player.*` field for player object id. Fallback: correlate by HP drop. |
| 2 | Buff baseline on login | `LOADING_END` seeds `lastEffectSnapshot` + sets `effectsBaseline = true`. Diff handler ignores events until baseline set. |
| 3 | Buff event flooding | Diff keyed by `(buffId, casterId)` — repeated buffs at same key don't emit duplicates. |
| 4 | Ability ID unresolvable | `abilityId` stored raw; render falls back to `"Ability #<id>"` when `ability == nil`. |
| 5 | Buffer overrun | Hard cap `MAX_EVENTS_BUFFERED = 500`. On append at cap, drop oldest. |
| 6 | HP=0 re-fires during respawn | `captureDone` flag stays true until HP > 0 returns. |
| 7 | `/reloadui` mid-capture-pending | `deaths` persists in SavedVariables. Indicator state recomputed from per-death `viewed` flags. `isPvpNow` recomputed on first `LOADING_END` after reinit. |
| 8 | SavedVariables schema migration | `version` field at root. `OnInitialize` reads version; runs migration table if older. v1 has no migrations; scaffold present so v2 isn't a fire drill. |
| 9 | Very fast deaths (<1s) | Render whatever the buffer has. Killing blow is the priority data point. |
| 10 | First-run empty state | GUI shows `"No deaths captured yet..."` placeholder. |
| 11 | Boundary: events fire before `LOADING_END` on scenario entry | First ~50ms of events dropped. Acceptable v1 trade-off — alternative defeats the `isPvpNow` cache optimization. |
| 12 | Event ordering race: HP-zero arrives before the killing-blow combat event | Assumption: combat resolution broadcasts damage event before HP update. If this is wrong on the RoR server, the killing blow misses the buffer. Verify during implementation by examining captured death timelines. Fallback if wrong: defer capture by one `OnUpdate` tick (~0.5s, or set a 100ms timer) so the late-arriving damage event lands in the buffer before we snapshot. |

---

## Critical files to be created

| Path | Purpose |
|---|---|
| `Interface/AddOns/DeathReplay/DeathReplay.mod` | Addon manifest |
| `Interface/AddOns/DeathReplay/DeathReplay.lua` | Core logic (events, buffer, death detection, capture, slash cmd) |
| `Interface/AddOns/DeathReplay/DeathReplay_GUI.xml` | Main replay window definition |
| `Interface/AddOns/DeathReplay/DeathReplay_GUI.lua` | Replay window controller |
| `Interface/AddOns/DeathReplay/DeathReplay_Indicator.xml` | On-screen indicator definition |
| `Interface/AddOns/DeathReplay/DeathReplay_Indicator.lua` | Indicator controller |

## Existing code patterns to reuse

| Pattern | Source |
|---|---|
| Addon `OnInitialize` / `OnShutdown` / event reg structure | `Interface/AddOns/QueueQueuer/QueueQueuer.lua:436-477` |
| `<SavedVariables>` manifest declaration | `Interface/AddOns/QueueQueuer/QueueQueuer.mod:46-48` |
| `OnUpdate` periodic-trim idiom | `Interface/AddOns/QueueQueuer/QueueQueuer.lua:754-771` |
| `LibSlash.RegisterSlashCmd` | `Interface/AddOns/QueueQueuer/QueueQueuer.lua:458-459` |
| RvR zone id list | `Interface/AddOns/QueueQueuer/QueueQueuer.lua:280-302` |
| `WORLD_OBJ_COMBAT_EVENT` signature + `GameData.CombatEvent.*` enum | `Interface/AddOns/wsct/wsct.lua:66-96, 499` |
| `PLAYER_EFFECTS_UPDATED` + `GetBuffs(GameData.BuffTargetType.SELF)` | `Interface/AddOns/wsct/wsct.lua:420-421`, `Interface/AddOns/BuffHead/Core.lua:179,220`, `Interface/AddOns/Aura/Source/AuraEngine.lua:577` |
| Window styling via `EATemplate_DefaultWindowSkin` dependency | `Interface/AddOns/QueueQueuer/QueueQueuer.mod:34` |

## Sandbox constraints

Per the verified findings in `~/.claude/projects/.../memory/war_ror_addon_sandbox_limits.md`:
- No `io`, `os.execute`, `require`, `socket`, `http`, `loadstring`, `package.*`, `debug.*`, or native `print`.
- All persistence flows through the engine's `<SavedVariables>` mechanism — addon never writes files directly.
- All in-game communication flows through chat events; no networking from inside the sandbox.

These constraints are satisfied by the design above — no out-of-sandbox features are required.

---

## Verification

No automated test harness exists for WAR addons; verification is structured manual testing.

**1. Smoke** (after every code change, before logging in to play):
- `/reloadui` in any zone. No Lua errors in `EA_ChatWindow`.
- Indicator window visible.
- `/dr` slash command prints something recognizable.

**2. Self-id verification** (one-time, during implementation):
- Add temporary debug print of `objectID` at top of `OnCombatEvent`.
- Take a hit from an NPC, read printed value, compare to candidate `GameData.Player.*` fields.
- Lock in the right comparison, remove the print.

**3. Capture happy path:**
- Queue low-tier scenario, die intentionally.
- Verify chat notification, indicator lights up.
- `/dr` opens window; timeline shows last ~10s including killing blow.
- Filter checkboxes hide/show event types correctly.

**4. Buff diff sanity:**
- Log in under standing group buffs. No spurious `BUFF_GAIN` flood (baseline seeded).
- Enter scenario, drink a potion. Single `BUFF_GAIN` entry per potion buff.
- Wait for expiry. Single `BUFF_LOSS` entry.

**5. PvP context gate:**
- PvE-zone death (training dummy or PvE mob): no capture.
- Open-RvR zone death: capture.
- Re-zone to capital city: event handlers stop appending (verify with temporary print).

**6. Death detector edge cases:**
- Two back-to-back deaths in same scenario: two captures, FIFO order.
- Die, `/reloadui` before respawn: capture persisted, indicator lit on reload.
- View death, `/reloadui`, re-open `/dr`: indicator stays dim (viewed flag persisted).

**7. SavedVariables persistence:**
- Capture 5+ deaths, logout, log back in: 5 deaths remain, oldest dropped.
- Manually edit SavedVariables `version = 999`: graceful handling or clear error.

**8. GUI navigation:**
- ◀ ▶ navigate correctly; index doesn't overflow; `N/5` indicator updates.
- Empty state renders when no captures exist.

**9. Coexistence:**
- Run with `Aura`, `BuffHead`, `wsct` enabled. No handler interference.
- Run under `Pure` or `Obsidian` UI skin. Window borders/fonts render acceptably.

**10. Soak:**
- 2+ hours of mixed scenario + RvR play.
- Memory does not grow unbounded (spot-check via `/dump collectgarbage('count')` if available).
- SavedVariables file < 50 KB.

**What this verification will NOT catch:**
- Translated-client name handling (English-only testing).
- Multi-day soak.
- Server-side combat-event quirks unique to careers/abilities not tested.

These are documented acceptable risks for v1.

---

## Out of scope / future work

See [`backlog-ideas.md`](../../../backlog-ideas.md) for 12 deferred items, each with rationale and rough implementation notes.
