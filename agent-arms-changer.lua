local cs_teams = {
	{ "Terrorist", true },
	{ "Counter-Terrorist", false },
}

local game_root_override = nil

local debug_model_scan = true

local function debug_print(message)
	if debug_model_scan then
		print("[model_changer] " .. message)
	end
end

local function normalize_path(path)
	return (path:gsub("\\", "/"))
end

-- filesystem interface
local fs_raw = ffi.cast("void***", memory.create_interface("filesystem_stdio.dll", "VFileSystem017"))

ffi.cdef([[
	typedef const char* (__thiscall* mdl_FindFirstEx)(void*, const char*, const char*, int*);
	typedef const char* (__thiscall* mdl_FindNext)   (void*, int);
	typedef bool        (__thiscall* mdl_FindIsDir)  (void*, int);
	typedef void        (__thiscall* mdl_FindClose)  (void*, int);
	typedef void        (__thiscall* mdl_AddSearch)  (void*, const char*, const char*);
	typedef void        (__thiscall* mdl_RemSearch)  (void*, const char*);
	typedef bool        (__thiscall* mdl_GetCurDir)  (void*, char*, int);
]])

local fs_fn = {
	find_first_ex    = ffi.cast("mdl_FindFirstEx", fs_raw[0][36]),
	find_next        = ffi.cast("mdl_FindNext",    fs_raw[0][33]),
	find_is_dir      = ffi.cast("mdl_FindIsDir",   fs_raw[0][34]),
	find_close       = ffi.cast("mdl_FindClose",   fs_raw[0][35]),
	add_search_path  = ffi.cast("mdl_AddSearch",   fs_raw[0][11]),
	rem_search_paths = ffi.cast("mdl_RemSearch",   fs_raw[0][14]),
	get_cur_dir      = ffi.cast("mdl_GetCurDir",   fs_raw[0][40]),
}

local SEARCH_PATH_ID = "mdlchanger_scan"

local function scan_mdl_files(abs_dir)
	local files = {}
	local norm  = normalize_path(abs_dir)

	fs_fn.rem_search_paths(fs_raw, SEARCH_PATH_ID)
	fs_fn.add_search_path(fs_raw, norm, SEARCH_PATH_ID)

	local queue = { "" }

	while #queue > 0 do
		local subdir  = table.remove(queue, 1)
		local pattern = (subdir == "") and "*" or (subdir .. "/*")

		local handle = ffi.new("int[1]")
		local first  = fs_fn.find_first_ex(fs_raw, pattern, SEARCH_PATH_ID, handle)

		if first ~= nil and first ~= ffi.null then
			local entry = first
			repeat
				local name = ffi.string(entry)

				if name ~= "." and name ~= ".." then
					local rel = (subdir == "") and name or (subdir .. "/" .. name)

					if fs_fn.find_is_dir(fs_raw, handle[0]) then
						queue[#queue + 1] = rel
					else
						if rel:lower():sub(-4) == ".mdl" then
							files[#files + 1] = rel:lower()
						end
					end
				end

				entry = fs_fn.find_next(fs_raw, handle[0])
			until entry == nil or entry == ffi.null

			fs_fn.find_close(fs_raw, handle[0])
		else
			debug_print("find_first_ex returned nil for pattern: " .. pattern)
		end
	end

	fs_fn.rem_search_paths(fs_raw, SEARCH_PATH_ID)

	debug_print(string.format("scanned %s -> %d mdl files", norm, #files))
	return files
end

local function get_game_root()
	if type(game_root_override) == "string" and game_root_override ~= "" then
		debug_print("using manual game root override: " .. game_root_override)
		return game_root_override
	end

	local buf = ffi.new("char[512]")
	fs_fn.get_cur_dir(fs_raw, buf, ffi.sizeof(buf))
	local cwd = normalize_path(ffi.string(buf))
	debug_print("GetCurrentDirectory: " .. cwd)
	return cwd
end

local function display_model_name(rel_to_scan_root)
	return (rel_to_scan_root:match("([^/]+)$") or rel_to_scan_root):gsub("%.mdl$", "")
end

local function is_arms_model(relative_path)
	local file_name = relative_path:match("([^/]+)$") or relative_path
	return file_name:find("arms", 1, true) ~= nil
end

local function is_team_specific(relative_path)
	if
		relative_path:find("ctm_", 1, true)
		or relative_path:find("ct_arms", 1, true)
		or relative_path:find("/ct/", 1, true)
	then
		return false
	elseif
		relative_path:find("tm_", 1, true)
		or relative_path:find("t_arms", 1, true)
		or relative_path:find("/t/", 1, true)
	then
		return true
	end
	return nil
end

local function add_model_entry(target, seen, is_t, name, path)
	if not seen[is_t][path] then
		seen[is_t][path] = true
		target[#target + 1] = { name, path, is_t }
	end
end

local function sort_model_entries(entries)
	table.sort(entries, function(left, right)
		if left[1] == right[1] then
			return left[2] < right[2]
		end
		return left[1] < right[1]
	end)
end

local function build_model_lists()
	local game_root = get_game_root()
	if not game_root then
		debug_print("game root resolution failed; lists will stay empty")
		return {}, {}
	end

	local player_models = {}
	local arm_models    = {}
	local seen_player   = { [true] = {}, [false] = {} }
	local seen_arms     = { [true] = {}, [false] = {} }

	local scan_root = game_root .. "/csgo/models/player/custom_player"
	local scanned   = scan_mdl_files(scan_root)

	if #scanned == 0 then
		debug_print("no .mdl files found under " .. scan_root)
	end

	for _, rel_to_scan_root in ipairs(scanned) do
		-- full engine-relative path used for precaching, team detection, arms detection
		local relative_path = "models/player/custom_player/" .. rel_to_scan_root

		-- display name derived from scan-root-relative portion only, so the
		-- long prefix never appears in the dropdown
		local display_name = display_model_name(rel_to_scan_root)
		local is_arms      = is_arms_model(relative_path)
		local is_t         = is_team_specific(relative_path)

		if is_arms then
			if is_t == nil then
				add_model_entry(arm_models, seen_arms, true,  display_name, relative_path)
				add_model_entry(arm_models, seen_arms, false, display_name, relative_path)
			else
				add_model_entry(arm_models, seen_arms, is_t, display_name, relative_path)
			end
		else
			if is_t == nil then
				add_model_entry(player_models, seen_player, true,  display_name, relative_path)
				add_model_entry(player_models, seen_player, false, display_name, relative_path)
			else
				add_model_entry(player_models, seen_player, is_t, display_name, relative_path)
			end
		end
	end

	sort_model_entries(player_models)
	sort_model_entries(arm_models)
	debug_print(string.format("final model counts -> player: %d, arms: %d", #player_models, #arm_models))

	return player_models, arm_models
end

local player_models, arm_models = build_model_lists()

-- interfaces
local ent_list          = memory.create_interface("client.dll", "VClientEntityList003")
local ent_list_raw      = ffi.cast("void***", ent_list)
local get_client_entity = ffi.cast("void*(__thiscall*)(void*, int)", memory.get_vfunc(ent_list, 3))

local model_info        = memory.create_interface("engine.dll", "VModelInfoClient004")
local model_info_raw    = ffi.cast("void***", model_info)
local get_model_index   = ffi.cast("int(__thiscall*)(void*, const char*)", memory.get_vfunc(model_info, 2))

local set_model_index_t = ffi.typeof("void(__thiscall*)(void*, int)")
local set_model_index   =
	ffi.cast(set_model_index_t, memory.find_pattern("client.dll", "55 8B EC 8B 45 08 56 8B F1 8B 0D ?? ?? ?? ??"))
local arms_model_offset = 0x99d7

-- build UI and model path tables per team
local team_refs  = {}
local team_paths = {}
local arm_refs   = {}
local arm_paths  = {}

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

	if #names == 0 then
		names[1] = "<no models found>"
	end

	team_refs[is_t] = {
		enabled = menu.add_checkbox("Agent Changer", string.format("Enable (%s)", teamname)),
		model   = menu.add_list("Agent Changer", string.format("Model (%s)", teamname), names, 10),
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

	if #names == 0 then
		names[1] = "<no arms found>"
	end

	arm_refs[is_t] = {
		enabled = menu.add_checkbox("Agent Changer", string.format("Enable Arms (%s)", teamname)),
		model   = menu.add_list("Agent Changer", string.format("Arms (%s)", teamname), names, 10),
	}
end

local function resolve_team_selection(refs, paths, is_t)
	local selected_path
	for ref_is_t, t_refs in pairs(refs) do
		local visible = ref_is_t == is_t
		t_refs.enabled:set_visible(visible)
		t_refs.model:set_visible(visible and t_refs.enabled:get())
		if visible and t_refs.enabled:get() then
			selected_path = paths[is_t][t_refs.model:get()]
		end
	end
	return selected_path
end

local function set_arms_model(lp, arms_path)
	local lp_address     = ffi.cast("intptr_t", lp:get_address())
	local arms_model_ptr = ffi.cast("char*", lp_address + arms_model_offset)
	ffi.copy(arms_model_ptr, arms_path, #arms_path + 1)
end

local refresh_pending   = false
local cached_arms_model = "unset"

local function request_refresh()
	refresh_pending = true
end

local function flush_refresh()
	if not refresh_pending then return end
	if not engine.is_in_game() then
		refresh_pending = false
		return
	end
	refresh_pending = false
	engine.execute_cmd("record x; stop")
end

local function do_model_change()
	local lp = entity_list.get_local_player()
	if not lp or not lp:is_alive() then return end

	local is_t       = lp:get_prop("m_iTeamNum") == 2
	local model_path = resolve_team_selection(team_refs, team_paths, is_t)
	local arms_path  = resolve_team_selection(arm_refs,  arm_paths,  is_t)

	if model_path then
		local idx = get_model_index(model_info_raw, model_path)
		if idx == -1 then
			client.precache_model(model_path)
		else
			local lp_ptr = ffi.cast("void***", get_client_entity(ent_list_raw, lp:get_index()))
			if lp_ptr ~= nil then
				local set_idx = ffi.cast(set_model_index_t,
					memory.get_vfunc(tonumber(ffi.cast("unsigned int", lp_ptr)), 75))
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
				cached_arms_model = arms_path
				request_refresh()
			end
		end
	elseif cached_arms_model ~= "unset" then
		cached_arms_model = "unset"
		request_refresh()
	end
end

callbacks.add(e_callbacks.NET_UPDATE, do_model_change)
callbacks.add(e_callbacks.PAINT,      flush_refresh)
