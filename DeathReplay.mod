<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <UiMod name="DeathReplay" version="0.1.0" date="5/15/2026" autoenabled="true">
        <VersionSettings gameVersion="1.4.8" windowsVersion="1.0" savedVariablesVersion="1.0" />
        <Author name="self" email="" />
        <Description text="Captures the last ~10s of PvP deaths into a browsable timeline." />
        <WARInfo>
            <Categories>
                <Category name="RVR" />
                <Category name="COMBAT" />
            </Categories>
            <Careers>
                <Career name="BLACKGUARD" />
                <Career name="WITCH_ELF" />
                <Career name="DISCIPLE" />
                <Career name="SORCERER" />
                <Career name="IRON_BREAKER" />
                <Career name="SLAYER" />
                <Career name="RUNE_PRIEST" />
                <Career name="ENGINEER" />
                <Career name="BLACK_ORC" />
                <Career name="CHOPPA" />
                <Career name="SHAMAN" />
                <Career name="SQUIG_HERDER" />
                <Career name="WITCH_HUNTER" />
                <Career name="KNIGHT" />
                <Career name="BRIGHT_WIZARD" />
                <Career name="WARRIOR_PRIEST" />
                <Career name="CHOSEN" />
                <Career name="MARAUDER" />
                <Career name="ZEALOT" />
                <Career name="MAGUS" />
                <Career name="SWORDMASTER" />
                <Career name="SHADOW_WARRIOR" />
                <Career name="WHITE_LION" />
                <Career name="ARCHMAGE" />
            </Careers>
        </WARInfo>
        <Dependencies>
            <Dependency name="LibSlash" />
            <Dependency name="EATemplate_DefaultWindowSkin" />
            <Dependency name="Warbuilder" optional="false" forceEnable="true" />
        </Dependencies>
        <Files>
            <File name="DeathReplay.lua" />
            <File name="DeathReplay_Indicator.xml" />
            <File name="DeathReplay_Indicator.lua" />
            <File name="DeathReplay_GUI.xml" />
            <File name="DeathReplay_GUI.lua" />
        </Files>
        <SavedVariables>
            <SavedVariable name="DeathReplay_SavedVariables" />
        </SavedVariables>
        <OnInitialize>
            <CreateWindow name="DeathReplay_Indicator" show="true" />
            <CreateWindow name="DeathReplay_GUI" show="false" />
            <CallFunction name="DeathReplay.OnInitialize" />
        </OnInitialize>
        <OnShutdown>
            <CallFunction name="DeathReplay.OnShutdown" />
        </OnShutdown>
        <OnUpdate>
            <CallFunction name="DeathReplay.OnUpdate" />
        </OnUpdate>
    </UiMod>
</ModuleFile>
