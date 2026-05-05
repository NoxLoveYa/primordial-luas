local player_models = {
	{ "komo (t)", "models/player/custom_player/2019x/komo/komo.mdl", true },
	{ "komo (ct)", "models/player/custom_player/2019x/komo/komo.mdl", false },
}

local cs_teams = {
	{ "Terrorist", true },
	{ "Counter-Terrorist", false },
}
local arm_models = {
	{ "Komo - Arms", "models/player/custom_player/2019x/komo/komo_arms.mdl", true },
	{ "Komo - Arms", "models/player/custom_player/2019x/komo/komo_arms.mdl", false },
}

-- interfaces
local ent_list = memory.create_interface("client.dll", "VClientEntityList003")
local ent_list_raw = ffi.cast("void***", ent_list)
local get_client_entity = ffi.cast("void*(__thiscall*)(void*, int)", memory.get_vfunc(ent_list, 3))

local model_info = memory.create_interface("engine.dll", "VModelInfoClient004")
local model_info_raw = ffi.cast("void***", model_info)
local get_model_index = ffi.cast("int(__thiscall*)(void*, const char*)", memory.get_vfunc(model_info, 2))

local set_model_index_t = ffi.typeof("void(__thiscall*)(void*, int)")
local set_model_index =
	ffi.cast(set_model_index_t, memory.find_pattern("client.dll", "55 8B EC 8B 45 08 56 8B F1 8B 0D ?? ?? ?? ??"))
local arms_model_offset = 0x99d7

-- build UI and model path tables per team
local team_refs = {}
local team_paths = {}
local arm_refs = {}
local arm_paths = {}

for _, team in ipairs(cs_teams) do
	local teamname, is_t = team[1], team[2]

	local names = {}
	team_paths[is_t] = {}

	for _, model in ipairs(player_models) do
		local name, path, model_is_t = model[1], model[2], model[3]
		if model_is_t == nil or model_is_t == is_t then
			table.insert(names, name)
			table.insert(team_paths[is_t], path)
		end
	end

	team_refs[is_t] = {
		enabled = menu.add_checkbox("Agent Changer", string.format("Enable (%s)", teamname)),
		model = menu.add_list("Agent Changer", string.format("Model (%s)", teamname), names, 10),
	}
end

for _, team in ipairs(cs_teams) do
	local teamname, is_t = team[1], team[2]

	local names = {}
	arm_paths[is_t] = {}

	for _, model in ipairs(arm_models) do
		local name, path, model_is_t = model[1], model[2], model[3]
		if model_is_t == nil or model_is_t == is_t then
			table.insert(names, name)
			table.insert(arm_paths[is_t], path)
		end
	end

	arm_refs[is_t] = {
		enabled = menu.add_checkbox("Agent Changer", string.format("Enable Arms (%s)", teamname)),
		model = menu.add_list("Agent Changer", string.format("Arms (%s)", teamname), names, 10),
	}
end

local function resolve_team_selection(refs, paths, is_t)
	local selected_path
	for ref_is_t, team_refs in pairs(refs) do
		local visible = ref_is_t == is_t
		team_refs.enabled:set_visible(visible)
		team_refs.model:set_visible(visible and team_refs.enabled:get())
		if visible and team_refs.enabled:get() then
			selected_path = paths[is_t][team_refs.model:get()]
		end
	end
	return selected_path
end

local function set_arms_model(lp, arms_path)
	local lp_address = ffi.cast("intptr_t", lp:get_address())
	local arms_model_ptr = ffi.cast("char*", lp_address + arms_model_offset)
	ffi.copy(arms_model_ptr, arms_path, #arms_path + 1)
end

local cached_arms_model = "unset"

local function do_model_change()
	local lp = entity_list.get_local_player()
	if not lp or not lp:is_alive() then
		return
	end

	local is_t = lp:get_prop("m_iTeamNum") == 2
	local model_path = resolve_team_selection(team_refs, team_paths, is_t)
	local arms_path = resolve_team_selection(arm_refs, arm_paths, is_t)

	if model_path then
		local idx = get_model_index(model_info_raw, model_path)
		if idx == -1 then
			client.precache_model(model_path)
		else
			local lp_ptr = ffi.cast("void***", get_client_entity(ent_list_raw, lp:get_index()))
			if lp_ptr ~= nil then
				local set_idx =
					ffi.cast(set_model_index_t, memory.get_vfunc(tonumber(ffi.cast("unsigned int", lp_ptr)), 75))

				if lp:get_prop("m_nModelIndex") ~= idx then
					set_idx(lp_ptr, idx)
					lp:set_prop("m_nModelIndex", idx)
				end
			end
		end
	end

	if arms_path then
		local arms_idx = get_model_index(model_info_raw, arms_path)
		if arms_idx == -1 then
			client.precache_model(arms_path)
		else
			if lp:get_prop("m_szArmsModel") ~= arms_path then
				set_arms_model(lp, arms_path)
			end
			if cached_arms_model ~= arms_path then
				engine.execute_cmd("record x; stop")
				cached_arms_model = arms_path
			end
		end
	elseif cached_arms_model ~= "unset" then
		engine.execute_cmd("record x; stop")
		cached_arms_model = "unset"
	end
end

callbacks.add(e_callbacks.NET_UPDATE, do_model_change)
