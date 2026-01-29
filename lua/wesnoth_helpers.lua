local wesnoth = wesnoth
local wml = wml

local M = {}

M.ollama_model = "gemma3:latest"
M._memory = M._memory or {}

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
    debug_chat("Getting variable:", key .. " = " .. tostring(M._memory[key]))
    return M._memory[key]
end

local function set_var(key, value)
    debug_chat("Setting variable:", key .. " = " .. tostring(value))
    M._memory[key] = value
end

M.debug_chat = debug_chat
M.generate_ollama = generate_ollama
M.get_var = get_var
M.set_var = set_var

return M
