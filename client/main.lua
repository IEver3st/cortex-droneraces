local RC, U, W, E, R, N = RaceClient, RaceUtil, RaceWorld, RaceEditor, RaceRun, RaceNui
local RESOURCE = GetCurrentResourceName()
local TAB = 'cortex-droneraces'
local MENU = 'droneraces_main'
local BOARD = 'droneraces_board'
local busy = false

local function readPrefs()
    local function read(key, fallback)
        local ok, value = pcall(function() return exports['cortex-lib']:getTabSetting(TAB, key) end)
        if ok and value ~= nil then return value end
        return fallback
    end
    RC.prefs.trails = read('trails', true) ~= false
    RC.prefs.flames = read('flames', true) ~= false
    RC.prefs.lights = read('lights', true) ~= false
end

local function registerSettings()
    local rows = {
        { key = 'trails', type = 'toggle', label = L('settings.trails'), description = L('settings.trails.help') },
        { key = 'flames', type = 'toggle', label = L('settings.flames'), description = L('settings.flames.help') },
        { key = 'lights', type = 'toggle', label = L('settings.lights'), description = L('settings.lights.help') },
    }
    pcall(function()
        exports['cortex-lib']:registerSettings(TAB, L('settings.tab'), 'cortex-droneraces:', rows, { trails = true, flames = true, lights = true }, { group = 'Activities' })
    end)
    readPrefs()
end

AddEventHandler('cortex-lib:settingsChanged', function(tabId) if tabId == TAB then readPrefs() end end)
AddEventHandler('onClientResourceStart', function(name) if name == 'cortex-lib' then registerSettings() end end)

local function money(amount)
    local text = tostring(math.floor(tonumber(amount) or 0))
    local out = text:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return '$' .. out:gsub('^,', '')
end

local function hostForm(summary, access)
    local fields, values = {}, {}
    if summary.loop then
        fields[#fields + 1] = { name = 'laps', type = 'input', inputType = 'number', label = L('ui.host.laps'), min = Config.race.laps.min, max = Config.race.laps.max, step = 1, required = true }
        values.laps = tostring(summary.laps or Config.race.laps.default)
    end
    if access.economy then
        fields[#fields + 1] = { name = 'fee', type = 'input', inputType = 'number', label = L('ui.host.fee'), description = L('ui.host.fee_help', { min = money(access.minFee), max = money(access.maxFee) }),
            min = access.minFee, max = access.maxFee, step = 50 }
        values.fee = tostring(access.minFee)
    end
    if #fields == 0 then return { laps = 1, fee = 0 } end
    local result = lib.contextMenu({ title = L('ui.host.title', { name = summary.name }), labels = { confirm = L('ui.host.confirm'), cancel = L('ui.cancel') }, values = values, fields = fields })
    if not result then return nil end
    return { laps = math.tointeger(tonumber(result.laps)) or 1, fee = math.tointeger(tonumber(result.fee)) or 0 }
end

local function confirmFee(fee)
    if not fee or fee <= 0 then return true end
    local answer = lib.alertDialog({
        header = L('ui.join.title'), content = L('ui.join.body', { fee = money(fee) }),
        labels = { confirm = L('ui.join.confirm', { fee = money(fee) }), cancel = L('ui.cancel') },
    })
    return answer == 'confirm'
end

local function showBoard(trackId, summary)
    local result = U.call('board', trackId)
    if not result or not result.ok then U.failure(result) return end
    local options = {}
    for i, row in ipairs(type(result.data.rows) == 'table' and result.data.rows or {}) do
        options[#options + 1] = {
            label = ('%d  %s'):format(i, tostring(row.name or '?')),
            description = L('ui.board.row', { lap = U.formatTime(row.best_lap), race = U.formatTime(row.best_race), wins = row.wins or 0 }),
            close = false,
        }
    end
    if #options == 0 then options[1] = { label = L('ui.board.empty'), disabled = true } end
    local mine = result.data.mine
    if type(mine) == 'table' then
        options[#options + 1] = { label = L('ui.board.mine'), description = L('ui.board.row', { lap = U.formatTime(mine.best_lap), race = U.formatTime(mine.best_race), wins = mine.wins or 0 }), close = false }
    end
    lib.registerMenu({ id = BOARD, title = L('ui.board.title', { name = summary.name }), options = options }, function() end)
    lib.showMenu(BOARD)
end

local function act(action, trackId, data)
    local summary = RC.tracks[trackId]
    if action == 'host' then
        local access = U.call('access')
        if not access or not access.ok then U.failure(access) return end
        local form = hostForm(summary, access.data)
        if not form then return end
        local result = U.call('host', trackId, form.laps, form.fee)
        if not result or not result.ok then U.failure(result) return end
        U.notify('notify.hosted', 'success', { key = Config.keys.menu })
    elseif action == 'join' then
        if not confirmFee(data.fee) then return end
        local result = U.call('join', data.race)
        if not result or not result.ok then U.failure(result) return end
        U.notify('notify.joined', 'success')
    elseif action == 'start' then
        local result = U.call('start', data.race)
        if not result or not result.ok then U.failure(result) end
    elseif action == 'leave' then
        local result = U.call('leave')
        if not result or not result.ok then U.failure(result) end
    elseif action == 'trial' then
        local result = U.call('trial', trackId)
        if not result or not result.ok then U.failure(result) end
    elseif action == 'board' then
        showBoard(trackId, summary)
    elseif action == 'edit' then
        E.edit(trackId)
    elseif action == 'delete' then
        local answer = lib.alertDialog({
            header = L('ui.delete.title', { name = summary.name }), content = L(summary.builtin and 'ui.delete.body_builtin' or 'ui.delete.body'),
            labels = { confirm = L('ui.delete.confirm'), cancel = L('ui.cancel') },
        })
        if answer ~= 'confirm' then return end
        local result = U.call('delete', trackId)
        if not result or not result.ok then U.failure(result) return end
        U.notify('notify.track_deleted', 'success', { name = summary.name })
    elseif action == 'create' then
        E.create()
    elseif action == 'draft' then
        E.resumeDraft()
    end
end

local function option(label, description, icon, args, disabled)
    return { label = label, description = description, icon = icon, args = args, disabled = disabled }
end

local function trackOptions(trackId, view, access)
    local summary = RC.tracks[trackId]
    local options = {}
    local lobby = view.lobby
    local mineId = view.mine
    if lobby and mineId == lobby.id then
        if lobby.host == GetPlayerServerId(PlayerId()) then
            options[#options + 1] = option(L('ui.menu.start'), L('ui.menu.start_help', { count = #lobby.racers }), 'play', { action = 'start', race = lobby.id })
        end
        options[#options + 1] = option(L('ui.menu.leave'), lobby.fee > 0 and L('ui.menu.leave_refund', { fee = money(lobby.fee) }) or nil, 'door', { action = 'leave' })
    elseif lobby then
        local full = #lobby.racers >= lobby.max
        options[#options + 1] = option(L('ui.menu.join', { count = #lobby.racers, max = lobby.max }),
            lobby.fee > 0 and L('ui.menu.join_fee', { fee = money(lobby.fee), pot = money(lobby.pot) }) or L('ui.menu.join_free'),
            'flag', { action = 'join', race = lobby.id, fee = lobby.fee }, full or mineId ~= false)
    else
        options[#options + 1] = option(L('ui.menu.host'), access.economy and L('ui.menu.host_help') or L('ui.menu.host_free'), 'flag', { action = 'host' }, mineId ~= false)
    end
    options[#options + 1] = option(L('ui.menu.trial'), L('ui.menu.trial_help'), 'clock', { action = 'trial' }, mineId ~= false)
    options[#options + 1] = option(L('ui.menu.board'), nil, 'list', { action = 'board' })
    if view.canEdit then
        options[#options + 1] = option(L('ui.menu.edit'), L('ui.menu.edit_help'), 'pen', { action = 'edit' }, lobby ~= false)
        options[#options + 1] = option(L(summary.builtin and 'ui.menu.reset' or 'ui.menu.delete'), nil, 'trash', { action = 'delete' }, lobby ~= false)
    end
    return options
end

local function openMenu()
    if busy or RC.editing or RC.replaying or N.focused() then return end
    if RC.race then
        if not lib or not lib.alertDialog then return end
        busy = true
        CreateThread(function()
            local answer = lib.alertDialog({ header = L('ui.forfeit.title'), content = L('ui.forfeit.body'), labels = { confirm = L('ui.forfeit.confirm'), cancel = L('ui.cancel') } })
            busy = false
            if answer == 'confirm' then R.forfeit() end
        end)
        return
    end
    if U.piloting() then return end
    busy = true
    CreateThread(function()
        local trackId = W.near
        local access = U.call('access')
        if not access or not access.ok then busy = false; U.failure(access) return end
        local options, title = {}, L('ui.menu.title')
        if trackId and RC.tracks[trackId] then
            local view = U.call('lobby', trackId)
            if not view or not view.ok then busy = false; U.failure(view) return end
            options = trackOptions(trackId, view.data, access.data)
            title = RC.tracks[trackId].name
        elseif RC.lobby then
            options[#options + 1] = option(L('ui.menu.leave'), RC.lobby.fee > 0 and L('ui.menu.leave_refund', { fee = money(RC.lobby.fee) }) or nil, 'door', { action = 'leave' })
        end
        if access.data.create then
            options[#options + 1] = option(L('ui.menu.create'), L('ui.menu.create_help'), 'plus', { action = 'create' })
            if E.hasDraft() then options[#options + 1] = option(L('ui.menu.draft'), L('ui.menu.draft_help'), 'pen', { action = 'draft' }) end
        end
        busy = false
        if #options == 0 then U.notify('notify.no_track_near', 'info') return end
        lib.registerMenu({ id = MENU, title = title, options = options }, function(_, _, args)
            if type(args) ~= 'table' then return end
            CreateThread(function() act(args.action, trackId, args) end)
        end)
        lib.showMenu(MENU)
    end)
end

RegisterCommand('+cortexdroneraces_menu', openMenu, false)
RegisterCommand('-cortexdroneraces_menu', function() end, false)
RegisterKeyMapping('+cortexdroneraces_menu', L('keys.menu'), 'keyboard', Config.keys.menu)
RegisterCommand('droneraces', openMenu, false)

CreateThread(function()
    Wait(500)
    registerSettings()
end)

AddEventHandler('onClientResourceStop', function(name)
    if name ~= RESOURCE then return end
    if lib and lib.hideMenu then pcall(lib.hideMenu) end
end)
