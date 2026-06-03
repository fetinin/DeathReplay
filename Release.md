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
