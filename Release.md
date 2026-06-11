# DeathReplay v0.5.0

Released 6/11/2026. Changes since v0.4.3.

## New

- **The death notice in chat is now a clickable link.** On every captured
  death, `[DeathReplay]: Killed by <ability>` is printed gold-yellow in the
  chat log (same channel Deathblow2 uses for its death-stats line). The
  ability name is a yellow hyperlink — click it to open the replay window
  on that death. When the killing ability is in Warbuilder's database, the
  attacker's career is appended in brackets, e.g.
  `Killed by Word of Pain (Sorcerer)`; NPC abilities, weapon procs and
  items print the bare name. The handler chains the original
  `EA_ChatWindow.OnHyperLinkLButtonUp`, so item links and other addons'
  chat links keep working.

## Bug fixes

- **Killing-blow damage no longer goes missing from the replay.** The
  killing blow's combat event is sometimes dispatched just *after* the
  hp=0 update that captures the death, so it missed the snapshot — a hit
  visible on screen and in the combat log but absent from the timeline.
  Trailing damage received while dead is now folded into the just-saved
  death (clamped to the death instant) and becomes the killing blow,
  last hit winning. Hits folded this way can't bleed into the next death.
- **Replay window no longer reopens empty after `/reloadui`.** The window
  manifest persisted visibility across UI reloads, so the GUI came back
  open but with no death loaded. It now closes on reload; reopen with
  `/dr` as usual.

## Notes

- No saved-variables schema change (still v3); no migration required.

---

# DeathReplay v0.4.3

Released 6/3/2026. Changes since v0.4.2.

## Bug fixes

- **Past-death damage no longer leaks into a later death's timeline.**
  When you died, the internal event buffer was only ever emptied once you
  healed back to full HP. If you respawned and died again *without* topping
  off in between — the common case in RvR and scenarios — the previous
  death's hits stayed buffered and were re-stamped against the new death's
  time. They then showed up in the new timeline as stray events from far in
  the past (e.g. damage tagged ~2 minutes before a death, with an obvious
  gap before the fight that actually killed you). The buffer is now flushed
  the moment a death is captured, so every timeline contains only the hits
  leading up to that specific death.

## Internal / cleanup

- Removed the unused `bufferWindowSeconds` config field. It was a leftover
  from an earlier time-window design and was read nowhere in the addon;
  buffer bounding is handled by full-HP health monitoring plus the
  flush-on-death above. Existing saved-variable files are unaffected — the
  stale field, if present, is simply ignored.
- `release.sh` now derives the engine-loaded file list from the
  `DeathReplay.mod` manifest's `<Files>` block instead of a hardcoded list,
  so adding a runtime Lua file only requires touching the manifest.

## Notes

- No saved-variables schema change (still v3); no migration required.
- The death-penalty max-HP debuff was reviewed against the HP-checking
  logic: death (`hp == 0`) and respawn (`hp > 0`) detection don't read max
  HP at all, and the full-HP buffer clear keys on the live (debuffed)
  maximum, so it still fires correctly when you heal up under the penalty.

---

# DeathReplay v0.4.2

Released 5/31/2026. Changes since v0.4.1. This release is all about getting
the right icon and tooltip onto every damage source in a death timeline.

## Improvements

- **DoT tick damage now shows the correct ability icon.** The engine fires a
  DoT's periodic ticks with a different ability id than the cast that applied
  it (e.g. Touch of Palsy: cast 8338, tick 3400), so id-only lookups missed
  them. A name-keyed mirror of the Warbuilder ability database now bridges
  tick → cast by the shared ability name, so ticks resolve to the parent
  ability's icon at the moment the hit is captured.
- **Row tooltips show ability descriptions, including for DoT ticks.** Hovering
  a timeline row resolves the cast id behind a tick and pulls the engine's
  ability description for it, so periodic-damage rows get a real description
  instead of a blank.
- **Weapon-proc damage resolves both icon and description.** Item enchant /
  weapon procs report with ability id 0 and aren't in Warbuilder, so a
  hand-curated proc table (`DeathReplay_WeaponProcs.lua`) now supplies their
  icon and description by name.

## Notes

- A render-time retroactive icon fallback for pre-existing saved deaths was
  prototyped during this cycle but reverted before release: fresh captures
  already resolve icons at hit time, so it only covered old saves and wasn't
  worth the extra rendering branch.
