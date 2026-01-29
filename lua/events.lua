if _G.LLM_WESNOTH_HELPERS then
    return _G.LLM_WESNOTH_HELPERS
end

local wesnoth = wesnoth
local wml = wml

local h = wesnoth.require("~add-ons/LLM_Wesnoth/lua/helpers.lua")

local M = {}

_G.LLM_WESNOTH_HELPERS = M

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
        h.initialize_unit(u)
    end
end

-- WML hook: when a unit is recruited (use [event] name=recruit)
function M.on_unit_recruited()
    local u = wml.variables.unit
    if not u then return end
    h.initialize_unit(u)

    h.debug_chat(string.format(
        "Unit %s (%s) recruited with personality %s",
        tostring(u),
        tostring(u.name or "UNKNOWN"),
        tostring(h.unit_get_var(u, h.PERSONALITY_KEY, "NONE"))
    ))
end

-- WML hook: when an enemy unit is killed (use [event] name=enemy_killed)
function M.on_enemy_killed()
    local dead = wml.variables.unit
    local killer = wml.variables.second_unit

    if not dead or not killer then return end
    if killer.side ~= 1 then return end

    h.increment_unit_var(killer, h.KILL_COUNT_KEY, 1)
    local reply = h.generate_kill_reply(killer, dead)

    wml.fire("message", { speaker = "second_unit", message = reply })
end

-- WML hook: when a unit is damaged (use [event] name=hit)
function M.on_unit_damaged()
    local damager = wml.variables.unit
    local damagee = wml.variables.second_unit
    if not damager or not damagee then return end

    local damage = wml.variables.damage_inflicted
    h.increment_unit_var(damagee, h.TOTAL_DAMAGE_KEY, damage)

    if h.is_close_call(damage, damagee.hitpoints, damagee.max_hitpoints) then
        h.increment_unit_var(damagee, h.CLOSE_CALLS_KEY, 1)
    end

    local name = tostring(damagee.name or damagee.id or "unit")
    h.debug_chat(string.format(
        "%s took %d damage (total damage: %d, close calls: %d)",
        name,
        damage,
        tonumber(h.unit_get_var(damagee, h.TOTAL_DAMAGE_KEY, 0)) or 0,
        tonumber(h.unit_get_var(damagee, h.CLOSE_CALLS_KEY, 0)) or 0
    ))
end

return M
