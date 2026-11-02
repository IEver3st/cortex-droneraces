RaceTracks = { list = {} }
local TR = RaceTracks
local T, Db = RaceTrack, RaceDb
local RESOURCE = GetCurrentResourceName()
local revision = 0

local function stamp(track)
    revision = revision + 1
    track.rev = revision
    return track
end

local function publish()
    local summaries = {}
    for _, track in pairs(TR.list) do summaries[#summaries + 1] = T.summary(track) end
    table.sort(summaries, function(a, b) return a.name < b.name end)
    GlobalState[RESOURCE .. ':tracks'] = summaries
end
TR.publish = publish

local function install(id, raw, meta)
    local track, err = T.normalize(raw, { maxCheckpoints = 200, maxProps = 400, maxSpan = 10000.0 })
    if not track then
        print(('^3[%s] track %s skipped: %s^0'):format(RESOURCE, id, err))
        return nil
    end
    track.id = id
    track.owner = meta.owner
    track.author = meta.author
    track.builtin = meta.builtin == true
    T.derive(track)
    TR.list[id] = stamp(track)
    return track
end

function TR.loadBuiltins()
    for id, raw in pairs(RaceBuiltinTracks or {}) do
        if T.validId(id) then install(id, raw, { author = raw.author or 'GSD Modifications', builtin = true }) end
    end
    publish()
end

function TR.loadSaved()
    for _, row in ipairs(Db.tracks()) do
        local ok, raw = pcall(json.decode, row.data)
        if ok and type(raw) == 'table' and T.validId(row.id) then
            install(row.id, raw, { owner = row.owner, author = row.author, builtin = RaceBuiltinTracks and RaceBuiltinTracks[row.id] ~= nil })
        end
    end
    publish()
end

function TR.get(id)
    return type(id) == 'string' and TR.list[id] or nil
end

function TR.newId()
    for _ = 1, 20 do
        local id = ('t%x%x'):format(os.time() % 0xFFFFFF, math.random(0, 0xFFFF))
        if not TR.list[id] then return id end
    end
end

function TR.save(id, raw, owner, author)
    local track, err = T.normalize(raw)
    if not track then return nil, err end
    local data = json.encode({ name = track.name, loop = track.loop, laps = track.laps, always = track.always, checkpoints = track.checkpoints, props = track.props })
    if not Db.saveTrack(id, track.name, owner, author, data) then return nil, 'database' end
    local existing = TR.list[id]
    track.id = id
    track.owner = existing and existing.owner or owner
    track.author = existing and existing.author or author
    track.builtin = RaceBuiltinTracks and RaceBuiltinTracks[id] ~= nil
    T.derive(track)
    TR.list[id] = stamp(track)
    publish()
    return track
end

function TR.delete(id)
    local track = TR.list[id]
    if not track then return false end
    Db.deleteTrack(id)
    TR.list[id] = nil
    local builtin = RaceBuiltinTracks and RaceBuiltinTracks[id]
    if builtin then install(id, builtin, { author = builtin.author or 'GSD Modifications', builtin = true }) end
    publish()
    return true
end
