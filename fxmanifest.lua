fx_version 'cerulean'
game 'gta5'

name 'spz-escalation'
description 'SPiceZ Minigame - Escalation. Valorant-style escalation on wheels: push enemies off a Color Rush deck to climb a shared random car sequence; a push in the finale car wins, or most pushes at the buzzer. Team or solo.'
version '1.0.0'
author 'SPiceZ-Core'
lua54 'yes'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua',
}

client_scripts {
  'client/main.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/main.lua',
}

-- The deck uses spz-colorrush's streamed tiles (Config.TileModel), so that
-- resource must be started first; there is no stream/ folder here.
dependencies {
  'ox_lib',
  'oxmysql',
  'spz-core',
  'spz-identity',
  'spz-progression',
  'spz-minigames',   -- shared in-game HUD + hub
  'spz-colorrush',   -- deck tile models
}
