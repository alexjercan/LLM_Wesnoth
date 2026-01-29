local wh = wesnoth.require("~add-ons/LLM_Wesnoth/lua/wesnoth_helpers.lua")

local M = {}

M.KILL_COUNT_KEY = "kill_count"
M.CLOSE_CALLS_KEY = "close_calls"
M.TOTAL_DAMAGE_KEY = "total_damage"
M.PERSONALITY_KEY = "personality"

---Trim leading and trailing whitespace from a string
---@param s string input string
---@return string trimmed string
local function trim(s)
    s = tostring(s or "")
    local new_s = s:gsub("^%s*(.-)%s*$", "%1")
    return new_s
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
    local v = wh.get_var(k .. "_" .. key)
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
    wh.set_var(k .. "_" .. key, value)
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
    if unit_get_var(unit, M.PERSONALITY_KEY, nil) then return end

    -- assign random personality
    local p = PERSONALITIES[ math.random(#PERSONALITIES) ]
    unit_set_var(unit, M.PERSONALITY_KEY, p)

    -- initialize memory fields
    unit_set_var(unit, M.KILL_COUNT_KEY, 0)
    unit_set_var(unit, M.CLOSE_CALLS_KEY, 0)
    unit_set_var(unit, M.TOTAL_DAMAGE_KEY, 0)

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
    local kills = tonumber(unit_get_var(killer, M.KILL_COUNT_KEY, 0)) or 0

    local dead_type = trim((dead.__cfg and dead.__cfg.id) or dead.id or dead.type or "enemy")
    local dead_level = dead.level or 1

    local killer_name = trim(killer.name or (killer.__cfg and killer.__cfg.name) or "soldier")
    local killer_personality = tostring(unit_get_var(killer, M.PERSONALITY_KEY, "calm"))
    local killer_kills = kills
    local killer_close_calls = tonumber(unit_get_var(killer, M.CLOSE_CALLS_KEY, 0)) or 0
    local total_damage = tonumber(unit_get_var(killer, M.TOTAL_DAMAGE_KEY, 0)) or 0

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

    wh.debug_chat(string.format("Ollama Prompt:\n%s", prompt))

    local reply = nil
    if wh.generate_ollama then
        local ok, res = pcall(wh.generate_ollama, prompt)
        if ok and type(res) == "string" and trim(res) ~= "" then
            reply = trim(res)
        end
    end

    if not reply then
        reply = kill_reply_fallback(killer)
    end

    return reply
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

M.debug_chat = wh.debug_chat
M.initialize_unit = initialize_unit
M.generate_kill_reply = generate_kill_reply
M.is_close_call = is_close_call
M.increment_unit_var = increment_unit_var
M.unit_get_var = unit_get_var

return M
