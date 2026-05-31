-- Hand-curated metadata for weapon-proc abilities.
--
-- Why this file exists: weapon enchants (Shock I-VII, Pilfer I-VII, etc.) hit
-- the combat log with abilityId=0. GetAbilityData(0) returns nothing and the
-- ability is not in Warbuilder's career-line database, so the
-- runtime/Warbuilder fallback chain in resolveIconForAbility cannot recover an
-- icon or description. The engine name comes through correctly though, so we
-- key on it.
--
-- Keys must match the engine's wstring EXACTLY, including the ^n suffix the
-- engine appends to the canonical name. Enable `/dr debug on` and the DR_HIT
-- line prints the engine name verbatim -- copy from there.
--
-- icon       = numeric iconNum (same value space as GetAbilityData(...).iconNum
--              and Warbuilder's Icon field). Leave 0 if unknown -- the lookup
--              skips zero icons and falls back to the default no-icon render.
-- description = wstring shown in the timeline/overview hover tooltip. Leave as
--              L"" if unknown.

DeathReplay_WeaponProcs = {}

DeathReplay_WeaponProcs.meta = {
    -- Tier VI weapon enchants. Descriptions copied verbatim from in-game item
    -- tooltips (the "+ <Name> - <text>" line on weapons that carry the proc).
    -- Icon numbers unknown for now -- lookup skips zero icons and falls back
    -- to the default no-icon render.
    [L"Pilfer VI^n"]     = { icon = 0, description = L"On Being Hit: 10% chance to steal 175 health from your attacker." },
    [L"Blight VI^n"]     = { icon = 0, description = L"On Hit: 5% chance to blight target for 525 Corporeal damage over 9 seconds." },
    [L"Agony VI^n"]      = { icon = 0, description = L"On Hit: 5% chance on hit to harrow target for 525 Spirit damage over 9 seconds." },
    [L"Acclimate VI^n"]  = { icon = 0, description = L"On Direct Heal: 10% chance to reduce the target's Elemental damage taken by 5% for 10 seconds." },
    [L"Judgement VI^n"]  = { icon = 0, description = L"On Hit: 5% chance to persecute target for 350 Spirit damage." },
    [L"Concussion VI^n"] = { icon = 0, description = L"On Hit: 5% chance to jolt target for 350 damage." },
    [L"Hemorrage VI^n"]  = { icon = 0, description = L"On Hit: 5% chance to bleed target for 525 damage over 9 seconds." },
    [L"Blades VI^n"]     = { icon = 0, description = L"On Being Hit: 3% chance attacker is cut and suffers 525 damage over 9 seconds." },
    [L"Burn VI^n"]       = { icon = 0, description = L"On Hit: 5% chance to burn target for 525 Elemental damage over 9 seconds." },
}

function DeathReplay_WeaponProcs.Lookup(abilityName)
    if abilityName == nil or abilityName == L"" then return nil end
    return DeathReplay_WeaponProcs.meta[abilityName]
end
