return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`Solo Mourningstar` encountered an error loading the Darktide Mod Framework.")

		new_mod("SoloMourningstar", {
			mod_script       = "SoloMourningstar/scripts/mods/SoloMourningstar/SoloMourningstar",
			mod_data         = "SoloMourningstar/scripts/mods/SoloMourningstar/SoloMourningstar_data",
			mod_localization = "SoloMourningstar/scripts/mods/SoloMourningstar/SoloMourningstar_localization",
		})
	end,
	packages = {},
}
