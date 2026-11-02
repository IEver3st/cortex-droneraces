RaceAudit = {}
local RESOURCE = GetCurrentResourceName()
local queue, sending, waiting, tries = {}, false, false, 0

local function webhook()
    local url = GetConvar('cortex_droneraces_webhook', '')
    if url:match('^https://discord%.com/api/webhooks/') or url:match('^https://discordapp%.com/api/webhooks/')
        or url:match('^https://ptb%.discord%.com/api/webhooks/') or url:match('^https://canary%.discord%.com/api/webhooks/') then return url end
    return nil
end

function RaceAudit.actor(src)
    if not src or src == 0 then return 'console' end
    local license = GetPlayerIdentifierByType(tostring(src), 'license')
    return ('%s (%s%s)'):format(GetPlayerName(tostring(src)) or '?', src, license and ', ' .. license or '')
end

local flush
local function later(ms)
    waiting = true
    SetTimeout(ms, function() waiting = false; flush() end)
end

flush = function()
    if sending or waiting or #queue == 0 then return end
    local url = webhook()
    if not url then queue = {}; return end
    sending = true
    local batch = {}
    for i = 1, math.min(10, #queue) do batch[i] = table.remove(queue, 1) end
    PerformHttpRequest(url, function(status, body, headers)
        sending = false
        status = tonumber(status) or 0
        local delay = 1500
        if status >= 200 and status < 300 then
            tries = 0
        elseif (status == 429 or status == 0 or status >= 500) and tries < 3 then
            tries = tries + 1
            for i = #batch, 1, -1 do table.insert(queue, 1, batch[i]) end
            local ok, decoded = pcall(json.decode, body or '')
            local after = (ok and type(decoded) == 'table' and tonumber(decoded.retry_after))
                or (type(headers) == 'table' and tonumber(headers['Retry-After'] or headers['retry-after'])) or 5
            delay = math.max(delay, math.min(60000, math.ceil(after * 1000)))
        else
            tries = 0
            print(('^3[%s] audit webhook returned %s; %d entries not sent^7'):format(RESOURCE, tostring(status), #batch))
        end
        if #queue > 0 then later(delay) end
    end, 'POST', json.encode({ username = 'Cortex Drone Races', embeds = batch }), { ['Content-Type'] = 'application/json' })
end

function RaceAudit.log(category, summary, fields)
    if Config.audit[category] ~= true then return end
    local keys = {}
    for key in pairs(fields or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = ('%s=%s'):format(key, tostring(fields[key])) end
    print(('[%s] audit %s: %s %s'):format(RESOURCE, category, summary, table.concat(parts, ' ')))
    if not webhook() then return end
    local embed = { title = summary, color = 0x8fcbbf, fields = {}, timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        footer = { text = RESOURCE .. ' · ' .. category } }
    for _, key in ipairs(keys) do
        if #embed.fields < 10 then embed.fields[#embed.fields + 1] = { name = tostring(key), value = tostring(fields[key]):sub(1, 256), inline = true } end
    end
    if #queue < 50 then queue[#queue + 1] = embed end
    flush()
end
