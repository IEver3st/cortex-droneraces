RaceEditor = {}
local E = RaceEditor
local RC, U, T, G, K, W, N = RaceClient, RaceUtil, RaceTrack, RaceGeometry, RaceCatalogue, RaceWorld, RaceNui
local DRAFT_KEY = 'droneraces:draft'
local MOVE = { forward = 32, back = 33, left = 34, right = 35 }
local LOOK = 8.0
local TURN = { normal = 70.0, slow = 15.0 }
local MENU = 'droneraces_editor'

local ed = nil

local function C() return Config.editorControls end

local function copyPiece(p) return { k = p.k, x = p.x, y = p.y, z = p.z, h = p.h, p = p.p } end

local function snapshot(state)
    local out = { id = state.id, name = state.name, loop = state.loop, laps = state.laps, always = state.always, checkpoints = {}, props = {} }
    for i, p in ipairs(state.checkpoints) do out.checkpoints[i] = copyPiece(p) end
    for i, p in ipairs(state.props) do out.props[i] = copyPiece(p) end
    return out
end

local function wireDraft(state)
    local s = snapshot(state)
    s.id = nil
    return s
end

local function persist(state)
    state.dirty = true
    state.persistAt = U.now() + 1500
end

local function flushDraft(state)
    if not state.persistAt then return end
    state.persistAt = nil
    SetResourceKvp(DRAFT_KEY, json.encode(snapshot(state)))
end

local function readDraft()
    local raw = GetResourceKvpString(DRAFT_KEY)
    if not raw then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' or type(data.checkpoints) ~= 'table' or type(data.props) ~= 'table' then return nil end
    return data
end

function E.hasDraft() return readDraft() ~= nil end

local function listFor(kind) return kind.checkpoint and 'checkpoints' or 'props' end

local function spawnAt(state, list, index)
    local piece = state[list][index]
    local entity = W.spawnPiece(piece, K.pieces[piece.k])
    if entity ~= 0 then SetModelAsNoLongerNeeded(K.pieces[piece.k].hash) end
    table.insert(state.entities[list], index, entity)
end

local function removeAt(state, list, index)
    W.removePiece(table.remove(state.entities[list], index))
    return table.remove(state[list], index)
end

local function clearEntities(state)
    for _, list in ipairs({ 'checkpoints', 'props' }) do
        for _, entity in ipairs(state.entities[list]) do W.removePiece(entity) end
        state.entities[list] = {}
    end
    U.deleteEntity(state.preview)
    state.preview, state.previewKind = nil, nil
end

local function spawnAll(state)
    state.entities = { checkpoints = {}, props = {} }
    for _, list in ipairs({ 'checkpoints', 'props' }) do
        for i = 1, #state[list] do
            spawnAt(state, list, i)
            if i % 4 == 0 then Wait(0) end
        end
    end
end

local function camForward(rot)
    local p, h = math.rad(rot.x), math.rad(rot.z)
    return vector3(-math.sin(h) * math.cos(p), math.cos(h) * math.cos(p), math.sin(p))
end

local function currentKind(state) return K.pieces[K.order[state.kindIndex]] end

local function pickPose(state, kind, camPos, rot)
    local forward = camForward(rot)
    local at = camPos + forward * state.reach
    local heading = (rot.z + state.yaw) % 360.0
    local pitch = kind.tilt and state.pitch or 0.0
    local z = at.z
    if state.snap[kind.key] then
        local found, ground = GetGroundZFor_3dCoord(at.x, at.y, math.max(at.z, camPos.z) + 40.0, false)
        if found then z = ground + kind.ground end
    end
    return { k = kind.key, x = at.x, y = at.y, z = z, h = heading, p = pitch }
end

local function hover(state, camPos, rot)
    local forward = camForward(rot)
    local tip = camPos + forward * 150.0
    local best, bestList, bestIndex = math.huge, nil, nil
    for _, list in ipairs({ 'checkpoints', 'props' }) do
        for i, p in ipairs(state[list]) do
            local kind = K.pieces[p.k]
            local d = G.segmentDistance(p.x, p.y, p.z, camPos.x, camPos.y, camPos.z, tip.x, tip.y, tip.z)
            local limit = (kind.reach or 1.4) + 0.4
            if d < limit then
                local along = #(vector3(p.x, p.y, p.z) - camPos)
                if along < best then best, bestList, bestIndex = along, list, i end
            end
        end
    end
    return bestList, bestIndex
end

local function syncPreview(state, pose, kind)
    if state.previewKind ~= kind.key then
        U.deleteEntity(state.preview)
        state.preview = W.spawnPiece(pose, kind, 160)
        state.previewKind = kind.key
        if state.preview ~= 0 then
            SetEntityCollision(state.preview, false, false)
            SetModelAsNoLongerNeeded(kind.hash)
        end
    end
    if state.preview and state.preview ~= 0 then W.place(state.preview, pose) end
end

local function text3d(x, y, z, label, r, g, b)
    SetDrawOrigin(U.F(x), U.F(y), U.F(z), 0)
    SetTextFont(4)
    SetTextScale(0.0, 0.42)
    SetTextColour(r, g, b, 235)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

local function drawCourse(state, camPos, hoverList, hoverIndex)
    local r, g, b = U.accent()
    local list = state.checkpoints
    for i, p in ipairs(list) do
        if #(vector3(p.x, p.y, p.z) - camPos) < 260.0 then
            local hot = hoverList == 'checkpoints' and hoverIndex == i
            text3d(p.x, p.y, p.z + ((K.pieces[p.k].h or 3.0) * 0.5) + 0.9, tostring(i), hot and 255 or 240, hot and 255 or 240, hot and 255 or 233)
        end
        local nextPiece = list[i + 1] or (state.loop and #list > 2 and list[1])
        if nextPiece then
            U.ribbon(p.x, p.y, p.z, nextPiece.x, nextPiece.y, nextPiece.z, 0.18, r, g, b, 170)
        end
        local fx, fy, fz = G.toWorld(p, 0.0, 2.5, 0.0)
        U.ribbon(p.x, p.y, p.z, fx, fy, fz, 0.12, 240, 240, 233, 200)
    end
    if hoverList then
        local p = state[hoverList][hoverIndex]
        local top = (K.pieces[p.k].h and K.pieces[p.k].h * 0.5) or K.pieces[p.k].r or 1.2
        DrawMarker(0, U.F(p.x), U.F(p.y), U.F(p.z + top + 0.4), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.5, r, g, b, 220, true, true, 2, false, nil, nil, false)
    end
end

local function warnings(state)
    local list = {}
    local pads = 0
    for _, p in ipairs(state.props) do if p.k == 'pad' then pads = pads + 1 end end
    if #state.checkpoints < 2 then list[#list + 1] = L('ui.editor.need_checkpoints') end
    if pads < 1 then list[#list + 1] = L('ui.editor.need_pad') end
    if pads > 0 and pads < Config.race.maxRacers then list[#list + 1] = L('ui.editor.few_pads', { count = pads }) end
    return list, pads
end

local function pushState(state, hoverList, hoverIndex)
    local kind = currentKind(state)
    local warn, pads = warnings(state)
    local hovered = hoverList and state[hoverList][hoverIndex]
    local data = {
        name = state.name, kind = L('piece.' .. kind.key), kindIndex = state.kindIndex, kinds = #K.order,
        checkpoints = #state.checkpoints, maxCheckpoints = Config.editor.maxCheckpoints, props = #state.props, maxProps = Config.editor.maxProps,
        pads = pads, reach = math.floor(state.reach + 0.5), snap = state.snap[kind.key] == true, tilt = kind.tilt == true,
        pitch = math.floor(state.pitch + 0.5), loop = state.loop, laps = state.laps, dirty = state.dirty == true,
        grabbing = state.grab ~= nil, saved = state.id ~= nil,
        hover = hovered and (hoverList == 'checkpoints' and L('ui.editor.hover_gate', { index = hoverIndex, piece = L('piece.' .. hovered.k) }) or L('piece.' .. hovered.k)) or nil,
        warnings = warn,
    }
    local signature = table.concat({ data.kindIndex, data.checkpoints, data.props, data.reach, tostring(data.snap), data.pitch, tostring(data.loop),
        data.laps, tostring(data.dirty), tostring(data.grabbing), data.hover or '-', data.name, #warn }, '|')
    N.state('editor:state', data, signature)
end

local function legend()
    if not lib or not lib.showHelp then return end
    lib.showHelp({
        { label = L('help.editor_place'), value = 'LMB' }, { label = L('help.editor_grab'), value = 'RMB' },
        { label = L('help.editor_delete'), value = 'DELETE' }, { label = L('help.editor_cycle'), value = 'TAB' },
        { label = L('help.editor_reach'), value = 'WHEEL' }, { label = L('help.editor_turn'), value = 'Q E' },
        { label = L('help.editor_pitch'), value = 'R F' }, { label = L('help.editor_order'), value = 'PAGEUP PAGEDOWN' },
        { label = L('help.editor_snap'), value = 'G' }, { label = L('help.editor_fly'), value = 'W A S D' },
        { label = L('help.editor_rise'), value = 'SPACE CTRL' }, { label = L('help.editor_menu'), value = 'ENTER' },
    }, { compact = true })
end

local function place(state, pose)
    local kind = K.pieces[pose.k]
    local list = listFor(kind)
    if state.grab then
        local index = math.min(state.grab.index, #state[list] + 1)
        table.insert(state[list], index, pose)
        spawnAt(state, list, index)
        state.grab = nil
        U.sound('CHECKPOINT_NORMAL')
        persist(state)
        return
    end
    local max = list == 'checkpoints' and Config.editor.maxCheckpoints or Config.editor.maxProps
    if #state[list] >= max then U.notify(list == 'checkpoints' and 'error.too_many_checkpoints' or 'error.too_many_props') return end
    local first = state.checkpoints[1]
    if first and G.distance(first.x, first.y, first.z, pose.x, pose.y, pose.z) > Config.editor.maxSpan then U.notify('error.too_spread') return end
    state[list][#state[list] + 1] = pose
    spawnAt(state, list, #state[list])
    U.sound('CHECKPOINT_NORMAL')
    persist(state)
end

local function grab(state, list, index)
    if state.grab or not list then return end
    local piece = removeAt(state, list, index)
    state.grab = { list = list, index = index, piece = piece }
    for i, key in ipairs(K.order) do if key == piece.k then state.kindIndex = i end end
    local rot = GetCamRot(state.cam, 2)
    state.yaw = (piece.h - rot.z) % 360.0
    state.pitch = piece.p or 0.0
    state.reach = math.max(Config.editor.reach.min, math.min(Config.editor.reach.max, #(vector3(piece.x, piece.y, piece.z) - GetCamCoord(state.cam))))
    persist(state)
end

local function dropGrab(state)
    local held = state.grab
    if not held then return end
    state.grab = nil
    local index = math.min(held.index, #state[held.list] + 1)
    table.insert(state[held.list], index, held.piece)
    spawnAt(state, held.list, index)
end

local function reorder(state, list, index, delta)
    if list ~= 'checkpoints' then return end
    local target = index + delta
    if target < 1 or target > #state.checkpoints then return end
    state.checkpoints[index], state.checkpoints[target] = state.checkpoints[target], state.checkpoints[index]
    state.entities.checkpoints[index], state.entities.checkpoints[target] = state.entities.checkpoints[target], state.entities.checkpoints[index]
    U.sound('NAV_UP_DOWN', 'HUD_FRONTEND_DEFAULT_SOUNDSET')
    persist(state)
end

local function stopCam(state)
    RenderScriptCams(false, true, 300, true, true)
    if state.cam then DestroyCam(state.cam, false) end
    state.cam = nil
    ClearFocus()
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
end

local function teardown(state, keepDraft)
    flushDraft(state)
    clearEntities(state)
    stopCam(state)
    if state.id then W.hide(state.id, false) end
    W.force('draft', nil)
    if lib and lib.hideHelp then lib.hideHelp() end
    N.send('editor:hide')
    N.forget('editor:state')
    U.hud(true)
    if not keepDraft then DeleteResourceKvp(DRAFT_KEY) end
end

local editorLoop

local function begin(state)
    ed = state
    RC.editing = true
    U.hud(false)
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    state.cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', state.camPos.x, state.camPos.y, state.camPos.z, state.camRot.x, 0.0, state.camRot.z, 60.0, false, 2)
    SetCamActive(state.cam, true)
    RenderScriptCams(true, true, 400, true, true)
    W.force('draft', nil)
    if state.id then W.hide(state.id, true) end
    spawnAll(state)
    legend()
    N.send('editor:show', { name = state.name })
    editorLoop(state)
end

local function finish(state, keepDraft)
    if ed ~= state then return end
    ed = nil
    state.closed = true
    teardown(state, keepDraft)
    RC.editing = false
end

local function save(state)
    if state.saving then return end
    local _, pads = warnings(state)
    if #state.checkpoints < 2 then U.notify('error.need_checkpoints') return end
    if pads < 1 then U.notify('error.need_pad') return end
    state.saving = true
    local result = U.call('save', state.id, wireDraft(state))
    state.saving = false
    if not result or not result.ok then U.failure(result) return end
    state.id = result.data.id
    W.hide(state.id, true)
    state.dirty = false
    flushDraft(state)
    U.notify('notify.track_saved', 'success', { name = state.name })
end

local function settingsForm(state)
    if not lib or not lib.contextMenu then return end
    local fields = {
        { name = 'name', type = 'input', label = L('ui.editor.field_name'), required = true, placeholder = L('ui.editor.field_name_hint') },
        { name = 'mode', type = 'select', label = L('ui.editor.field_mode'), required = true,
            options = { { value = 'loop', label = L('ui.editor.mode_loop') }, { value = 'sprint', label = L('ui.editor.mode_sprint') } } },
        { name = 'laps', type = 'input', inputType = 'number', label = L('ui.editor.field_laps'), min = Config.race.laps.min, max = Config.race.laps.max, step = 1 },
    }
    if state.staff then
        fields[#fields + 1] = { name = 'always', type = 'checkbox', label = L('ui.editor.field_always'), description = L('ui.editor.field_always_help') }
    end
    local values = lib.contextMenu({
        title = L('ui.editor.settings'), labels = { confirm = L('ui.apply'), cancel = L('ui.cancel') },
        values = { name = state.name, mode = state.loop and 'loop' or 'sprint', laps = tostring(state.laps), always = state.always == true },
        fields = fields,
    })
    if not values or ed ~= state then return end
    local name = T.cleanName(values.name)
    if not name then U.notify('error.bad_name') return end
    state.name = name
    state.loop = values.mode ~= 'sprint'
    state.laps = math.tointeger(tonumber(values.laps)) or state.laps
    state.laps = math.max(Config.race.laps.min, math.min(Config.race.laps.max, state.laps))
    if state.staff then state.always = values.always == true end
    persist(state)
end

local function suspend(state)
    state.camPos, state.camRot = GetCamCoord(state.cam), GetCamRot(state.cam, 2)
    finish(state, true)
    RC.editorResume = state
end

local function resumeWatch(state)
    CreateThread(function()
        local deadline = U.now() + 25000
        while not RC.race and U.now() < deadline do Wait(250) end
        while RC.race or RC.replaying or N.focused() do Wait(500) end
        Wait(600)
        if RC.editorResume ~= state or ed then return end
        RC.editorResume = nil
        state.closed, state.saving, state.grab = nil, false, nil
        begin(state)
    end)
end

local function testRun(state)
    local _, pads = warnings(state)
    if #state.checkpoints < 2 then U.notify('error.need_checkpoints') return end
    if pads < 1 then U.notify('error.need_pad') return end
    local draft = wireDraft(state)
    local normalized, err = T.normalize(draft)
    if not normalized then U.notify('error.' .. tostring(err)) return end
    normalized.id, normalized.rev = 'draft', 0
    RC.cache.draft = W.install(normalized)
    suspend(state)
    local result = U.call('trial', nil, draft)
    if not result or not result.ok then
        U.failure(result)
        if RC.editorResume == state then
            RC.editorResume = nil
            state.closed, state.saving, state.grab = nil, false, nil
            begin(state)
        end
        return
    end
    resumeWatch(state)
end

local function leave(state)
    if state.dirty and lib and lib.alertDialog then
        local answer = lib.alertDialog({
            header = L('ui.editor.leave_title'), content = L('ui.editor.leave_body'),
            labels = { confirm = L('ui.editor.leave_confirm'), cancel = L('ui.editor.leave_cancel') },
        })
        if answer ~= 'confirm' or ed ~= state then return end
    end
    finish(state, false)
end

local function clearAll(state)
    if lib and lib.alertDialog then
        local answer = lib.alertDialog({
            header = L('ui.editor.clear_title'), content = L('ui.editor.clear_body'),
            labels = { confirm = L('ui.editor.clear_confirm'), cancel = L('ui.cancel') },
        })
        if answer ~= 'confirm' or ed ~= state then return end
    end
    clearEntities(state)
    state.checkpoints, state.props, state.grab = {}, {}, nil
    state.entities = { checkpoints = {}, props = {} }
    persist(state)
end

local function openMenu(state)
    if not lib or not lib.registerMenu then return end
    dropGrab(state)
    state.menuOpen = true
    lib.registerMenu({
        id = MENU, title = state.name,
        options = {
            { label = L('ui.editor.save'), description = L('ui.editor.save_help'), icon = 'check', args = { action = 'save' } },
            { label = L('ui.editor.test'), description = L('ui.editor.test_help'), icon = 'play', args = { action = 'test' } },
            { label = L('ui.editor.settings'), description = L('ui.editor.settings_help'), icon = 'gear', args = { action = 'settings' } },
            { label = L('ui.editor.clear'), icon = 'trash', args = { action = 'clear' } },
            { label = L('ui.editor.exit'), icon = 'door', args = { action = 'exit' } },
        },
        onClose = function() state.menuOpen = false end,
    }, function(_, _, args)
        state.menuOpen = false
        if ed ~= state or type(args) ~= 'table' then return end
        CreateThread(function()
            if args.action == 'save' then save(state)
            elseif args.action == 'test' then testRun(state)
            elseif args.action == 'settings' then settingsForm(state)
            elseif args.action == 'clear' then clearAll(state)
            elseif args.action == 'exit' then leave(state) end
        end)
    end)
    lib.showMenu(MENU)
end

editorLoop = function(state)
    CreateThread(function()
        local c = C()
        local last = U.now()
        local nextPush = 0
        local reach = Config.editor.reach
        while ed == state and not state.closed do
            local now = U.now()
            local dt = math.min(0.1, (now - last) / 1000.0)
            last = now
            DisableAllControlActions(0)
            if not state.menuOpen and not IsNuiFocused() and not IsPauseMenuActive() then
                local rot = GetCamRot(state.cam, 2)
                local pitch = math.max(-89.0, math.min(89.0, rot.x - GetDisabledControlNormal(0, 2) * LOOK))
                local heading = rot.z - GetDisabledControlNormal(0, 1) * LOOK
                SetCamRot(state.cam, pitch, 0.0, heading, 2)
                rot = vector3(pitch, 0.0, heading)
                local speed = Config.editor.speed.normal
                if IsDisabledControlPressed(0, c.fast) then speed = Config.editor.speed.fast
                elseif IsDisabledControlPressed(0, c.slow) then speed = Config.editor.speed.slow end
                local forward = camForward(rot)
                local h = math.rad(heading)
                local right = vector3(math.cos(h), math.sin(h), 0.0)
                local move = vector3(0.0, 0.0, 0.0)
                if IsDisabledControlPressed(0, MOVE.forward) then move = move + forward end
                if IsDisabledControlPressed(0, MOVE.back) then move = move - forward end
                if IsDisabledControlPressed(0, MOVE.right) then move = move + right end
                if IsDisabledControlPressed(0, MOVE.left) then move = move - right end
                if IsDisabledControlPressed(0, c.up) then move = move + vector3(0.0, 0.0, 1.0) end
                if IsDisabledControlPressed(0, c.down) then move = move - vector3(0.0, 0.0, 1.0) end
                local camPos = GetCamCoord(state.cam)
                if #move > 0.001 then
                    camPos = camPos + move / #move * speed * dt
                    local origin = state.origin
                    local offset = camPos - origin
                    local limit = Config.editor.maxSpan + 200.0
                    if #offset > limit then camPos = origin + offset / #offset * limit end
                    SetCamCoord(state.cam, camPos.x, camPos.y, camPos.z)
                end
                SetFocusPosAndVel(camPos.x, camPos.y, camPos.z, 0.0, 0.0, 0.0)
                if IsDisabledControlJustPressed(0, c.reachIn) then state.reach = math.min(reach.max, state.reach + 1.0) end
                if IsDisabledControlJustPressed(0, c.reachOut) then state.reach = math.max(reach.min, state.reach - 1.0) end
                if not state.grab and IsDisabledControlJustPressed(0, c.cycle) then
                    state.kindIndex = state.kindIndex % #K.order + 1
                    if not currentKind(state).tilt then state.pitch = 0.0 end
                end
                local turn = IsDisabledControlPressed(0, c.slow) and TURN.slow or TURN.normal
                if IsDisabledControlPressed(0, c.yawLeft) then state.yaw = (state.yaw + turn * dt) % 360.0 end
                if IsDisabledControlPressed(0, c.yawRight) then state.yaw = (state.yaw - turn * dt) % 360.0 end
                local kind = currentKind(state)
                if kind.tilt then
                    if IsDisabledControlPressed(0, c.pitchUp) then state.pitch = math.min(90.0, state.pitch + turn * dt) end
                    if IsDisabledControlPressed(0, c.pitchDown) then state.pitch = math.max(-90.0, state.pitch - turn * dt) end
                end
                if IsDisabledControlJustPressed(0, c.snap) then state.snap[kind.key] = not state.snap[kind.key] end
                local pose = pickPose(state, kind, camPos, rot)
                syncPreview(state, pose, kind)
                local hoverList, hoverIndex = nil, nil
                if not state.grab then hoverList, hoverIndex = hover(state, camPos, rot) end
                drawCourse(state, camPos, hoverList, hoverIndex)
                if IsDisabledControlJustPressed(0, c.place) then place(state, pose)
                elseif IsDisabledControlJustPressed(0, c.grab) and hoverList then grab(state, hoverList, hoverIndex)
                elseif IsDisabledControlJustPressed(0, c.delete) and hoverList then
                    removeAt(state, hoverList, hoverIndex)
                    U.sound('CHECKPOINT_MISSED')
                    persist(state)
                elseif IsDisabledControlJustPressed(0, c.earlier) and hoverList then reorder(state, hoverList, hoverIndex, -1)
                elseif IsDisabledControlJustPressed(0, c.later) and hoverList then reorder(state, hoverList, hoverIndex, 1)
                elseif IsDisabledControlJustPressed(0, c.menu) then openMenu(state)
                elseif IsDisabledControlJustPressed(0, c.back) then
                    if state.grab then dropGrab(state) else CreateThread(function() leave(state) end) end
                end
                if now >= nextPush then
                    nextPush = now + 100
                    pushState(state, hoverList, hoverIndex)
                end
            end
            if state.persistAt and now >= state.persistAt then flushDraft(state) end
            Wait(0)
        end
    end)
end

local function newState(source, access)
    local ped = PlayerPedId()
    local at = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local state = {
        id = source.id, name = source.name or L('ui.editor.untitled'), loop = source.loop ~= false,
        laps = math.tointeger(tonumber(source.laps)) or Config.race.laps.default, always = source.always == true,
        checkpoints = {}, props = {}, entities = { checkpoints = {}, props = {} },
        kindIndex = 1, reach = Config.editor.reach.default, yaw = 0.0, pitch = 0.0, snap = {},
        staff = access and access.staff == true, dirty = source.dirty == true,
    }
    for key, kind in pairs(K.pieces) do state.snap[key] = kind.snap == true end
    for _, list in ipairs({ 'checkpoints', 'props' }) do
        for _, p in ipairs(type(source[list]) == 'table' and source[list] or {}) do
            local kind = K.get(p.k)
            if kind and listFor(kind) == list and type(p.x) == 'number' and type(p.y) == 'number' and type(p.z) == 'number' then state[list][#state[list] + 1] = copyPiece(p) end
        end
    end
    local first = state.checkpoints[1] or state.props[1]
    local focus = first and vector3(first.x, first.y, first.z) or at
    state.origin = first and vector3(first.x, first.y, first.z) or at
    local h = math.rad(heading)
    state.camPos = first and (focus + vector3(0.0, -12.0, 8.0)) or (at + vector3(math.sin(h) * 4.0, -math.cos(h) * 4.0, 3.0))
    state.camRot = vector3(-15.0, 0.0, first and 0.0 or heading)
    return state
end

function E.open(source)
    if ed or RC.race or RC.replaying then return end
    if U.piloting() then U.notify('error.on_foot') return end
    if IsPedInAnyVehicle(PlayerPedId(), false) then U.notify('error.on_foot') return end
    local access = U.call('access')
    if not access or not access.ok then U.failure(access) return end
    if not access.data.create then U.notify('error.denied') return end
    RC.editorResume = nil
    begin(newState(source or {}, access.data))
end

function E.create()
    E.open({})
end

function E.resumeDraft()
    local draft = readDraft()
    if not draft then E.open({}) return end
    draft.dirty = true
    E.open(draft)
end

function E.edit(trackId)
    local track = W.fetch(trackId)
    if not track then U.notify('error.no_track') return end
    E.open({ id = track.id, name = track.name, loop = track.loop, laps = track.laps, always = track.always, checkpoints = track.checkpoints, props = track.props })
end

function E.active() return ed ~= nil end

function E.close()
    if ed then finish(ed, true) end
end

AddEventHandler('onClientResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    if ed then pcall(teardown, ed, true) end
end)
