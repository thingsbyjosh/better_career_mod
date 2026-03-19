-- Better Career Mod entry point
-- BeamNG executes this file when the mod is loaded.
-- It bootstraps the extension manager which installs the override system.
setExtensionUnloadMode("bcm_extensionManager", "manual")

loadManualUnloadExtensions()
