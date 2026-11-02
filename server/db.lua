RaceDb = { ready = false }
local Db = RaceDb
local RESOURCE = GetCurrentResourceName()

local MIGRATIONS = {
    { version = 1, sql = {
        [[CREATE TABLE IF NOT EXISTS `cortex_droneraces_tracks` (
            `id` VARCHAR(32) NOT NULL PRIMARY KEY,
            `name` VARCHAR(64) NOT NULL,
            `owner` VARCHAR(64) NULL,
            `author` VARCHAR(64) NULL,
            `data` LONGTEXT NOT NULL,
            `created` INT UNSIGNED NOT NULL,
            `updated` INT UNSIGNED NOT NULL,
            KEY `owner` (`owner`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        [[CREATE TABLE IF NOT EXISTS `cortex_droneraces_times` (
            `track` VARCHAR(32) NOT NULL,
            `owner` VARCHAR(64) NOT NULL,
            `name` VARCHAR(64) NOT NULL,
            `best_lap` INT UNSIGNED NULL,
            `best_race` INT UNSIGNED NULL,
            `race_laps` TINYINT UNSIGNED NULL,
            `races` INT UNSIGNED NOT NULL DEFAULT 0,
            `wins` INT UNSIGNED NOT NULL DEFAULT 0,
            `updated` INT UNSIGNED NOT NULL,
            PRIMARY KEY (`track`, `owner`),
            KEY `lap` (`track`, `best_lap`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
        [[CREATE TABLE IF NOT EXISTS `cortex_droneraces_ledger` (
            `id` VARCHAR(64) NOT NULL PRIMARY KEY,
            `race` VARCHAR(48) NOT NULL,
            `citizenid` VARCHAR(64) NOT NULL,
            `kind` VARCHAR(8) NOT NULL,
            `amount` INT UNSIGNED NOT NULL,
            `account` VARCHAR(16) NOT NULL,
            `state` VARCHAR(8) NOT NULL,
            `created` INT UNSIGNED NOT NULL,
            `updated` INT UNSIGNED NOT NULL,
            KEY `race` (`race`),
            KEY `state` (`state`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    } },
    { version = 2, sql = {
        function()
            local present = MySQL.scalar.await([[SELECT 1 FROM `information_schema`.`COLUMNS` WHERE `TABLE_SCHEMA` = DATABASE()
                AND `TABLE_NAME` = 'cortex_droneraces_ledger' AND `COLUMN_NAME` = 'attempt']])
            if not present then MySQL.query.await('ALTER TABLE `cortex_droneraces_ledger` ADD COLUMN `attempt` VARCHAR(64) NULL') end
        end,
    } },
}

local function now() return os.time() end
Db.now = now

MySQL.ready(function()
    local ok, err = pcall(function()
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS `cortex_droneraces_meta` (
            `k` VARCHAR(64) NOT NULL PRIMARY KEY, `v` VARCHAR(255) NOT NULL) ENGINE=InnoDB]])
        local current = tonumber(MySQL.scalar.await('SELECT `v` FROM `cortex_droneraces_meta` WHERE `k` = ?', { 'schema' })) or 0
        for _, m in ipairs(MIGRATIONS) do
            if m.version > current then
                for _, stmt in ipairs(m.sql) do
                    if type(stmt) == 'function' then stmt() else MySQL.query.await(stmt) end
                end
                MySQL.query.await('INSERT INTO `cortex_droneraces_meta` (`k`, `v`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `v` = VALUES(`v`)',
                    { 'schema', tostring(m.version) })
            end
        end
    end)
    if not ok then
        print(('^1[%s] database setup failed: %s^0'):format(RESOURCE, tostring(err)))
        return
    end
    Db.ready = true
    TriggerEvent(RESOURCE .. ':dbReady')
end)

function Db.tracks()
    return MySQL.query.await('SELECT `id`, `name`, `owner`, `author`, `data`, `updated` FROM `cortex_droneraces_tracks`') or {}
end

function Db.saveTrack(id, name, owner, author, data)
    local at = now()
    return MySQL.query.await([[INSERT INTO `cortex_droneraces_tracks` (`id`, `name`, `owner`, `author`, `data`, `created`, `updated`)
        VALUES (?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE `name` = VALUES(`name`), `data` = VALUES(`data`), `updated` = VALUES(`updated`)]],
        { id, name, owner, author, data, at, at }) ~= nil
end

function Db.deleteTrack(id)
    MySQL.query.await('DELETE FROM `cortex_droneraces_times` WHERE `track` = ?', { id })
    return (MySQL.update.await('DELETE FROM `cortex_droneraces_tracks` WHERE `id` = ?', { id }) or 0) > 0
end

function Db.countOwned(owner)
    return tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM `cortex_droneraces_tracks` WHERE `owner` = ?', { owner })) or 0
end

function Db.recordTime(track, owner, name, lap, race, laps, won)
    MySQL.query.await([[INSERT INTO `cortex_droneraces_times` (`track`, `owner`, `name`, `best_lap`, `best_race`, `race_laps`, `races`, `wins`, `updated`)
        VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
        ON DUPLICATE KEY UPDATE
            `name` = VALUES(`name`),
            `best_lap` = IF(VALUES(`best_lap`) IS NOT NULL AND (`best_lap` IS NULL OR VALUES(`best_lap`) < `best_lap`), VALUES(`best_lap`), `best_lap`),
            `race_laps` = IF(VALUES(`best_race`) IS NOT NULL AND (`best_race` IS NULL OR VALUES(`best_race`) < `best_race`), VALUES(`race_laps`), `race_laps`),
            `best_race` = IF(VALUES(`best_race`) IS NOT NULL AND (`best_race` IS NULL OR VALUES(`best_race`) < `best_race`), VALUES(`best_race`), `best_race`),
            `races` = `races` + 1,
            `wins` = `wins` + VALUES(`wins`),
            `updated` = VALUES(`updated`)]],
        { track, owner, name, lap, race, laps, won and 1 or 0, now() })
end

function Db.leaderboard(track, limit)
    return MySQL.query.await([[SELECT `name`, `best_lap`, `best_race`, `wins`, `races` FROM `cortex_droneraces_times`
        WHERE `track` = ? AND `best_lap` IS NOT NULL ORDER BY `best_lap` ASC LIMIT ?]], { track, limit or 10 }) or {}
end

function Db.personal(track, owner)
    local rows = MySQL.query.await('SELECT `best_lap`, `best_race`, `race_laps`, `wins`, `races` FROM `cortex_droneraces_times` WHERE `track` = ? AND `owner` = ?',
        { track, owner })
    return rows and rows[1] or nil
end

local function safe(fn, fallback)
    local ok, result = pcall(fn)
    if not ok then
        print(('^1[%s] ledger query failed: %s^0'):format(RESOURCE, tostring(result)))
        return fallback
    end
    return result
end

local INSERT = [[INSERT INTO `cortex_droneraces_ledger` (`id`, `race`, `citizenid`, `kind`, `amount`, `account`, `state`, `created`, `updated`)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]]

function Db.ledgerInsert(id, race, citizenid, kind, amount, account, state)
    local at = now()
    return safe(function() return MySQL.insert.await(INSERT, { id, race, citizenid, kind, amount, account, state, at, at }) ~= nil end, false)
end

function Db.ledgerState(id, state, from)
    return safe(function()
        if from then
            return (MySQL.update.await('UPDATE `cortex_droneraces_ledger` SET `state` = ?, `updated` = ? WHERE `id` = ? AND `state` = ?',
                { state, now(), id, from }) or 0) > 0
        end
        return (MySQL.update.await('UPDATE `cortex_droneraces_ledger` SET `state` = ?, `updated` = ? WHERE `id` = ?', { state, now(), id }) or 0) > 0
    end, false)
end

function Db.ledgerClaim(id, attempt)
    return safe(function()
        return (MySQL.update.await("UPDATE `cortex_droneraces_ledger` SET `state` = 'pending', `attempt` = ?, `updated` = ? WHERE `id` = ? AND `state` = 'owed'",
            { attempt, now(), id }) or 0) > 0
    end, false)
end

function Db.ledgerExists(id)
    return safe(function()
        return MySQL.scalar.await('SELECT 1 FROM `cortex_droneraces_ledger` WHERE `id` = ?', { id }) ~= nil
    end, nil)
end

function Db.settle(race, fees, rows)
    local at = now()
    local queries = {}
    for _, fee in ipairs(fees) do
        queries[#queries + 1] = { query = "UPDATE `cortex_droneraces_ledger` SET `state` = ?, `updated` = ? WHERE `id` = ? AND `state` IN ('pending', 'held')",
            values = { fee.state, at, fee.id } }
        queries[#queries + 1] = { query = INSERT, values = { ('settle:' .. fee.id):sub(1, 64), race, fee.citizenid, 'settle', 0, '', 'done', at, at } }
    end
    for _, row in ipairs(rows) do
        queries[#queries + 1] = { query = INSERT, values = { row.id, row.race, row.citizenid, row.kind, row.amount, row.account, 'owed', at, at } }
    end
    if #queries == 0 then return true end
    return safe(function() return MySQL.transaction.await(queries) == true end, false)
end

function Db.ledgerOpen()
    return safe(function()
        return MySQL.query.await([[SELECT `id`, `race`, `citizenid`, `kind`, `amount`, `account`, `state`, `attempt`, `updated` FROM `cortex_droneraces_ledger`
            WHERE `state` IN ('pending', 'held', 'owed')]])
    end, nil)
end

function Db.ledgerFor(citizenid)
    return safe(function()
        return MySQL.query.await([[SELECT `id`, `race`, `citizenid`, `kind`, `amount`, `account`, `state` FROM `cortex_droneraces_ledger`
            WHERE `citizenid` = ? AND `state` = 'owed']], { citizenid }) or {}
    end, {})
end

function Db.ledgerUnknownCount()
    return safe(function()
        return tonumber(MySQL.scalar.await([[SELECT COUNT(*) FROM `cortex_droneraces_ledger`
            WHERE `state` = 'unknown' OR (`state` = 'pending' AND `attempt` IS NOT NULL AND `updated` < ?)]], { now() - 600 })) or 0
    end, 0)
end

function Db.ledgerUnknown()
    return safe(function()
        return MySQL.query.await([[SELECT `id`, `race`, `citizenid`, `kind`, `amount`, `account`, `attempt`, `state`, `created` FROM `cortex_droneraces_ledger`
            WHERE `state` = 'unknown' OR (`state` = 'pending' AND `attempt` IS NOT NULL AND `updated` < ?) ORDER BY `created` DESC LIMIT 25]], { now() - 600 }) or {}
    end, {})
end
