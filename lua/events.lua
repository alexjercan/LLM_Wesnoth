if _G.LLM_WESNOTH_HELPERS then
    return _G.LLM_WESNOTH_HELPERS
end

local wesnoth = wesnoth
local wml = wml

local json = wesnoth.require("~add-ons/LLM_Wesnoth/lua/json.lua")

local M = {}

_G.LLM_WESNOTH_HELPERS = M

M.ollama_model = "mistral"
M._memory = M._memory or {}

KILL_COUNT_KEY = "kill_count"
CLOSE_CALLS_KEY = "close_calls"
TOTAL_DAMAGE_KEY = "total_damage"
PERSONALITY_KEY = "personality"

---Trim leading and trailing whitespace from a string
---@param s string input string
---@return string trimmed string
local function trim(s)
    s = tostring(s or "")
    local new_s = s:gsub("^%s*(.-)%s*$", "%1")
    return new_s
end

---debug chat message if debug mode is enabled
---@param speaker string|nil optional
---@param text string|nil message text
---@return nil
local function debug_chat(speaker, text)
    if wesnoth.game_config.debug or wesnoth.debug_mode then
        -- speaker optional
        if text == nil then
            -- if only one arg passed, treat it as the message
            text = speaker
            speaker = nil
        end
        if speaker then
            wesnoth.interface.add_chat_message(speaker, text)
        else
            wesnoth.interface.add_chat_message(text)
        end
    end
end

---error chat message
---@param text string message text
---@return nil
local function error_chat(text)
    wesnoth.interface.add_chat_message("Error", text)
end

---generate text using Ollama LLM
---@param prompt string prompt text
---@return string|nil generated text or nil on failure
local function generate_ollama(prompt)
    local reply = nil
    if wesnoth.generate_ollama then
        local ok, res = pcall(wesnoth.generate_ollama, prompt, M.ollama_model)
        if ok and type(res) == "string" and trim(res) ~= "" then
            reply = trim(res)
        end
    end

    return reply
end

local function get_var(key)
    return M._memory[key]
end

local function set_var(key, value)
    M._memory[key] = value
end

---Generate a stable runtime key for a unit object.
---We use tostring(unit) which for Wesnoth unit proxies returns a unique-ish
---string for the lifetime of that proxy (e.g. "unit: 0x7f...").
---This is stable while the unit object exists in the scenario, but not across
---save/load or if the unit is destroyed and a new unit object is created.
---@param unit any Wesnoth unit object
---@return string|nil unique key for the unit, or nil if unit is nil
local function unit_key(unit)
    if not unit then return nil end
    -- prefer an explicit unique id if available, otherwise fallback to tostring
    -- (tostring for userdata is usually "unit: 0x...").
    local ok_key = nil
    ok_key = trim(tostring(unit.id or unit.__cfg.id or tostring(unit)))
    return ok_key
end

---Get a value from module memory for a unit
---@param unit userdata Wesnoth unit object
---@param key string memory key
---@param default any default value if not found
---@return any value from memory, or default if not found
local function unit_get_var(unit, key, default)
    if not unit then return default end
    local k = unit_key(unit)
    if not k then return default end
    local v = get_var(k .. "_" .. key)
    if v == nil then return default end
    return v
end

---Set a value in module memory for a unit
---@param unit any Wesnoth unit object
---@param key string memory key
---@param value any value to set
---@return nil
local function unit_set_var(unit, key, value)
    if not unit then return end
    local k = unit_key(unit)
    if not k then return end
    set_var(k .. "_" .. key, value)
end

-- personalities
local PERSONALITIES = {
    "calm", "professional",
    "overconfident", "cocky",
    "grim", "battle-hardened",
    "nervous", "determined",
    "quiet", "focused"
}

---initialize a unit's memory with a personality and stats
---@param unit any Wesnoth unit object
---@return nil
local function initialize_unit(unit)
    if not unit then return end
    if unit_get_var(unit, PERSONALITY_KEY, nil) then return end

    -- assign random personality
    local p = PERSONALITIES[ math.random(#PERSONALITIES) ]
    unit_set_var(unit, PERSONALITY_KEY, p)

    -- initialize memory fields
    unit_set_var(unit, KILL_COUNT_KEY, 0)
    unit_set_var(unit, CLOSE_CALLS_KEY, 0)
    unit_set_var(unit, TOTAL_DAMAGE_KEY, 0)

    -- last_hp is used to compute damage deltas if damage var isn't present
    unit_set_var(unit, "last_hp", tonumber(unit.hitpoints) or 0)
end

-- fallback replies
local FALLBACK = {
    easy = {
        "Too easy.",
        "Was that all?",
        "Child's play."
    },
    medium = {
        "That was close.",
        "We took a hit, but we won.",
        "Not bad - keep moving."
    },
    hard = {
        "That was rough.",
        "I barely made it.",
        "We need to be more careful."
    }
}

---choose a fallback reply based on killer's health percentage
---@param killer any Wesnoth unit object
---@return string
local function kill_reply_fallback(killer)
    local killer_hp_pct = 1.0
    if killer.hitpoints and killer.max_hitpoints and killer.max_hitpoints > 0 then
        killer_hp_pct = killer.hitpoints / killer.max_hitpoints
    end

    local difficulty = "medium"
    if killer_hp_pct >= 0.75 then
        difficulty = "easy"
    elseif killer_hp_pct < 0.40 then
        difficulty = "hard"
    end

    local pool = FALLBACK[difficulty] or FALLBACK.medium
    return pool[ math.random(#pool) ]
end

---when a unit kills another unit, generate a response
---@param killer any Wesnoth unit object that did the killing
---@param dead any Wesnoth unit object that was killed
---@return string
local function generate_kill_reply(killer, dead)
    local kills = tonumber(unit_get_var(killer, KILL_COUNT_KEY, 0)) or 0

    local dead_type = trim((dead.__cfg and dead.__cfg.id) or dead.id or dead.type or "enemy")
    local dead_level = dead.level or 1

    local killer_name = trim(killer.name or (killer.__cfg and killer.__cfg.name) or "soldier")
    local killer_personality = tostring(unit_get_var(killer, PERSONALITY_KEY, "calm"))
    local killer_kills = kills
    local killer_close_calls = tonumber(unit_get_var(killer, CLOSE_CALLS_KEY, 0)) or 0
    local total_damage = tonumber(unit_get_var(killer, TOTAL_DAMAGE_KEY, 0)) or 0

    local killer_hp_pct = 1.0
    if killer.hitpoints and killer.max_hitpoints and killer.max_hitpoints > 0 then
        killer_hp_pct = killer.hitpoints / killer.max_hitpoints
    end

    local prompt = string.format(
        "You are a soldier in the Battle for Wesnoth.\n" ..
        "Name: %s\n" ..
        "Personality: %s\n" ..
        "Memory: kills=%d; close_calls=%d; total_damage=%d\n" ..
        "Situation: You just killed a %s (level %d).\n" ..
        "Your condition: %d%% health remaining.\n\n" ..
        "Write ONE short in-character sentence (6–14 words).\n" ..
        "Tone should match your personality and memory.\n" ..
        "Do not mention game mechanics, rules, or UI.",
        killer_name,
        killer_personality,
        killer_kills,
        killer_close_calls,
        total_damage,
        dead_type,
        dead_level,
        math.floor(killer_hp_pct * 100)
    )

    -- debug_chat(string.format("Ollama Prompt:\n%s", prompt))

    local reply = nil
    if generate_ollama then
        local ok, res = pcall(generate_ollama, prompt)
        if ok and type(res) == "string" and trim(res) ~= "" then
            reply = trim(res)
        end
    end

    if not reply then
        reply = kill_reply_fallback(killer)
    end

    return reply
end

ALLOWED_UNITS = {
    "Orcish Grunt",
    "Orcish Archer",
    "Orcish Assassin"
}
ALLOWED_AREAS = {
    "south",
    "south_west",
}

---check if a map location is spawnable
---@param x number x coordinate
---@param y number y coordinate
---@return boolean true if spawnable
local function is_spawnable(x, y)
    if x < 1 or y < 1 then return false end
    if x > wesnoth.current.map.width then return false end
    if y > wesnoth.current.map.height then return false end
    if wesnoth.units.get(x, y) then return false end

    return true
end

---choose a location based on area name
---@param area string area name
---@return table|nil single {x, y} coordinate, or nil if none found
local function choose_location_in_area(area)
    local locations = {}
    local width  = wesnoth.current.map.width
    local height = wesnoth.current.map.height

    local function clamp(v, min, max)
        if v < min then return min end
        if v > max then return max end
        return v
    end

    local max_height = math.floor(height * 4 / 5)
    local y_start = clamp(math.floor(3 * height / 4), 1, max_height)

    if area == "south" then
        for x = 1, width - 1 do
            for y = y_start, max_height do
                if is_spawnable(x, y) then
                    table.insert(locations, { x = x, y = y })
                end
            end
        end

    elseif area == "south_west" then
        local x_end = clamp(math.floor(width / 2), 1, width - 1)
        for x = 1, x_end do
            for y = y_start, max_height do
                if is_spawnable(x, y) then
                    table.insert(locations, { x = x, y = y })
                end
            end
        end
    end

    if #locations == 0 then
        return nil
    end

    return locations[math.random(#locations)]
end

---generate a story line based on stuff
---@return table|nil generated story line as a table, or nil on failure
local function generate_story_line()
    local prompt = string.format(
        "You are generating a short scripted story beat for a Battle for Wesnoth scenario.\n" ..
        "Theme: orc raid, desperate last stand\n\n" ..
        "Scenario context: \n" ..
        " - The orcish forces are attempting to break through the southern defenses.\n" ..
        " - The leader id of the human side is 'Arden'.\n\n" ..
        "Output format (JSON object keyed by turn number):\n" ..
        "{\n" ..
        "  \"1\": [\n" ..
        "    {\n" ..
        "      \"type\": \"spawn\",\n" ..
        "      \"side\": 2,\n" ..
        "      \"area\": \"south\",\n" ..
        "      \"unit\": \"Orcish Grunt\",\n" ..
        "      \"id\": \"orc1\"\n" ..
        "    },\n" ..
        "    {\n" ..
        "      \"type\": \"dialogue\",\n" ..
        "      \"speaker\": \"orc1\",\n" ..
        "      \"message\": \"Break their line!\"\n" ..
        "    }\n" ..
        "  ],\n" ..
        "  \"4\": [ ... ]\n" ..
        "}\n\n" ..
        "Rules:\n" ..
        "- Do NOT invent new factions\n" ..
        "- Only use these unit types: %s\n" ..
        "- Spawn areas allowed: %s\n" ..
        "- Keys MUST be turn numbers\n" ..
        "- No more than 4 enemies per turn\n" ..
        "- Dialogue under 12 words\n" ..
        "- Output ONLY valid JSON\n\n" ..
        "Generate a full multi-turn story plan.",
        table.concat(ALLOWED_UNITS, ", "),
        table.concat(ALLOWED_AREAS, ", ")
    )

    -- debug_chat(string.format("Ollama Story Line Prompt:\n%s", prompt))
    local reply = nil
    if generate_ollama then
        local ok, res = pcall(generate_ollama, prompt)
        if ok and type(res) == "string" and trim(res) ~= "" then
            reply = trim(res)
        end
    end

    if not reply then
        error_chat("Failed to generate story line.")
        return nil
    end

    local story_line = nil
    local ok, res = pcall(json.parse, reply)
    if ok and type(res) == "table" then
        story_line = res
    else
        error_chat("Failed to parse story line JSON.")
        return nil
    end

    return story_line
end

---handle spawn action
---@param action table spawn action
---@return nil
local function handle_spawn_action(action)
    if not action then return end
    local unit_type = tostring(action.unit or "")
    local area = tostring(action.area or "")

    local loc = choose_location_in_area(area)
    if not loc then
        debug_chat("No valid location found for area:", area)
        return
    end

    local u = wesnoth.units.create { type = unit_type, side = action.side or 2, id = action.id }
    u:to_map(loc.x, loc.y)
    initialize_unit(u)
end

---handle dialogue action
---@param action table dialogue action
---@return nil
local function handle_dialogue_action(action)
    if not action then return end

    local speaker_id = tostring(action.speaker or "")
    local message = tostring(action.message or "")
    if message == "" then return end

    local speaker_unit = wesnoth.units.find_on_map { id = speaker_id }[1]

    if speaker_unit then
        wml.fire("message", {
            speaker = speaker_id,
            message = message
        })
    else
        wml.fire("message", {
            speaker = "narrator",
            message = message
        })
    end
end

---handle a story action
---@param action table story action
---@return nil
local function handle_action(action)
    if not action or type(action) ~= "table" then return end

    if action.type == "spawn" then
        debug_chat("Handling spawn action:", json.stringify(action))
        handle_spawn_action(action)
    elseif action.type == "dialogue" then
        debug_chat("Handling dialogue action:", json.stringify(action))
        handle_dialogue_action(action)
    end
end

---detect close call based on damage and HP%
---@param damage number damage dealt
---@param current_hp number current HP of unit
---@param max_hp number max HP of unit
---@return boolean true if close call detected
local function is_close_call(damage, current_hp, max_hp)
    if not damage or not max_hp or max_hp <= 0 then return false end
    if damage >= 0.35 * max_hp then return true end
    if current_hp / max_hp <= 0.25 then return true end
    return false
end

---increment a memory field for a unit
---@param unit any Wesnoth unit object
---@param key string memory key
---@param amount number amount to increment
---@return nil
local function increment_unit_var(unit, key, amount)
    local v = tonumber(unit_get_var(unit, key, 0)) or 0
    unit_set_var(unit, key, v + amount)
end

-- spawn_orcs (keeps behavior, assigns personality immediately)
function M.spawn_orcs()
    local orcs = {
        { type = "Orcish Grunt", x = 2, y = 8 },
        { type = "Orcish Archer", x = 3, y = 9 },
        { type = "Orcish Grunt", x = 1, y = 10 }
    }

    for _, data in ipairs(orcs) do
        local u = wesnoth.units.create { type = data.type, side = 2 }
        u:to_map(data.x, data.y)
        initialize_unit(u)
    end
end

-- WML hook: on story initialization (use [event] name=prestart)
function M.on_story_init()
    local plan = generate_story_line()
    if not plan then return end

    for turn_str, actions in pairs(plan) do
        local turn = tonumber(turn_str)
        if turn and type(actions) == "table" then
            wesnoth.game_events.add{
                name = "turn " .. turn,
                first_time_only = true,
                action = function()
                    debug_chat("Executing story events for turn " .. turn)
                    for _, action in ipairs(actions) do
                        handle_action(action)
                    end
                end
            }
        end
    end

    debug_chat("Story plan initialized.")
end

-- WML hook: when a unit is recruited (use [event] name=recruit)
function M.on_unit_recruited()
    local u = wml.variables.unit
    if not u then return end
    initialize_unit(u)

    debug_chat(string.format(
        "Unit %s (%s) recruited with personality %s",
        tostring(u),
        tostring(u.name or "UNKNOWN"),
        tostring(unit_get_var(u, PERSONALITY_KEY, "NONE"))
    ))
end

-- WML hook: when an enemy unit is killed (use [event] name=last breath)
function M.on_enemy_killed()
    local dead = wml.variables.unit
    local killer = wml.variables.second_unit

    if not dead or not killer then return end
    if killer.side ~= 1 then return end

    increment_unit_var(killer, KILL_COUNT_KEY, 1)
    local reply = generate_kill_reply(killer, dead)

    wml.fire("message", { speaker = "second_unit", message = reply })
end

-- WML hook: when a unit is damaged (use [event] name=hit)
function M.on_unit_damaged()
    local damager = wml.variables.unit
    local damagee = wml.variables.second_unit
    if not damager or not damagee then return end

    local damage = wml.variables.damage_inflicted
    increment_unit_var(damagee, TOTAL_DAMAGE_KEY, damage)

    if is_close_call(damage, damagee.hitpoints, damagee.max_hitpoints) then
        increment_unit_var(damagee, CLOSE_CALLS_KEY, 1)
    end
end

return M
