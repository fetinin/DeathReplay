<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <UiMod name="DeathReplay" version="0.1.0" date="2026-05-15" autoenabled="true">
        <VersionSettings gameVersion="1.4.8" windowsVersion="1.0" savedVariablesVersion="1.0" />
        <Author name="self" email="" />
        <Description text="Captures the last ~10s of PvP deaths into a browsable timeline." />
        <Dependencies>
            <Dependency name="LibSlash" />
            <Dependency name="EA_ChatWindow" />
            <Dependency name="EATemplate_DefaultWindowSkin" />
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
