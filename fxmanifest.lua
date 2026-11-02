fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_experimental_fxv2_oal 'yes'

name 'cortex-droneraces'
author 'GSDMODS/CORTEX'
description 'FPV drone races for Cortex Drone: neon courses, flames and smoke, a track creator, entry fees and prizes, and a replay of every line flown'
version '1.0.0'

dependencies { 'cortex-lib', 'cortex-drone', 'oxmysql', '/onesync' }

shared_scripts {
    '@cortex-lib/init.lua',
    'config.lua',
    'shared/locale.lua',
    'shared/validate.lua',
    'shared/rig.lua',
    'shared/catalogue.lua',
    'shared/geometry.lua',
    'shared/track.lua',
    'tracks/*.lua',
}

client_scripts {
    '@cortex-lib/presentation-client.lua',
    'client/util.lua',
    'client/nui.lua',
    'client/world.lua',
    'client/fx.lua',
    'client/race.lua',
    'client/replay.lua',
    'client/editor.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/bridge.lua',
    'server/audit.lua',
    'server/db.lua',
    'server/economy.lua',
    'server/tracks.lua',
    'server/race.lua',
    'server/main.lua',
}

ui_page 'web/dist/index.html'
files { 'web/dist/index.html', 'web/dist/assets/*', 'locales/*.json', 'stream/**/*.ytyp' }

data_file 'DLC_ITYP_REQUEST' 'stream/droneraces/cx_dr_droneraces.ytyp'

escrow_ignore { 'config.lua', 'locales/*.json', 'shared/locale.lua', 'server/bridge.lua', 'tracks/*.lua' }
