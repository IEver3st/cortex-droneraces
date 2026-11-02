Locale = {}

local RESOURCE = GetCurrentResourceName()
local fallback, active = {}, {}

local function read(code)
    if type(code) ~= 'string' or not code:match('^[%a%-]+$') then return nil end
    local raw = LoadResourceFile(RESOURCE, ('locales/%s.json'):format(code))
    if not raw then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then
        print(('^3[%s]^0 locales/%s.json is not valid JSON; using English.'):format(RESOURCE, code))
        return nil
    end
    local plain = {}
    for key, value in pairs(data) do
        if type(key) == 'string' and type(value) == 'string' then plain[key] = value end
    end
    return plain
end

function Locale.code()
    local convar = GetConvar('cortex_droneraces_locale', '')
    if convar ~= '' then return convar end
    return (Config and Config.Locale) or 'en'
end

function Locale.load()
    fallback = read('en') or {}
    local code = Locale.code()
    active = code == 'en' and fallback or (read(code) or fallback)
    if active == fallback and code ~= 'en' then
        print(('^3[%s]^0 No locale "%s"; using English.'):format(RESOURCE, code))
    end
end

function L(key, vars)
    local text = active[key] or fallback[key] or key
    if vars then
        text = text:gsub('{(%w+)}', function(name)
            local value = vars[name]
            if value == nil then return '{' .. name .. '}' end
            return tostring(value)
        end)
    end
    return text
end

function Locale.prefixed(prefix)
    local merged = {}
    for key, value in pairs(fallback) do if key:sub(1, #prefix) == prefix then merged[key] = value end end
    for key, value in pairs(active) do if key:sub(1, #prefix) == prefix then merged[key] = value end end
    return merged
end

Locale.load()
