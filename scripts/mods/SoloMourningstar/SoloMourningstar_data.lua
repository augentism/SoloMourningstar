local mod = get_mod("SoloMourningstar")

return {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			{
				setting_id = "solo_hub_on_enter",
				type = "checkbox",
				default_value = true,
				title = "solo_hub_on_enter",
				tooltip = "solo_hub_on_enter_tooltip",
			},
			{
				setting_id = "solo_hub_after_mission",
				type = "checkbox",
				default_value = true,
				title = "solo_hub_after_mission",
				tooltip = "solo_hub_after_mission_tooltip",
			},
			{
				setting_id = "debug_logging",
				type = "checkbox",
				default_value = false,
				title = "debug_logging",
				tooltip = "debug_logging_tooltip",
			},
		},
	},
}
