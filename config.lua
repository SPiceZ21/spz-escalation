-- config.lua — Escalation
-- Valorant's Escalation, on wheels. Push enemies off a Color Rush deck in the
-- sky; enough pushes and your side moves to the next car in one random
-- sequence shared by everyone. Score a push in the FINALE car to win, or have
-- the most pushes when the clock runs out. Team or solo, picked per room.

Config = {}

Config.Command      = "escalation"
Config.StartCommand = "escstart"
Config.MenuCommand  = "escalationmenu"

-- ── Rewards (FREE to join) ──────────────────────────────────────────────────
Config.WinReward  = 1500   -- every player on the winning side (solo: the winner)
Config.PushReward = 50     -- per push you score

-- ── Lobby ───────────────────────────────────────────────────────────────────
Config.MinPlayers   = 2
Config.MaxPlayers   = 16
Config.MaxRooms     = 6
Config.LobbyWaitSec = 45   -- unused: only the host starts (kept for shared room code)

-- ── Match ───────────────────────────────────────────────────────────────────
Config.MatchSec          = 300   -- time limit; most pushes wins at the end
Config.Tiers             = 8     -- cars in the sequence, the last is the finale
Config.TeamPushesPerTier = 3     -- team pushes needed to move the team up one car
Config.SoloPushesPerTier = 1     -- solo: every push moves you up
Config.RespawnSec        = 3.0   -- back on the deck after being pushed off
Config.PushCreditSec     = 6.0   -- a fall within this long of an enemy hit is their push

-- The sequence is rolled from this pool at the start of every match (same for
-- every side), then a finale car from FinalePool goes last. Valorant style: it
-- gets harder as you climb, so the finale is something awkward to push with.
Config.CarPool = {
    "kuruma", "sultan", "dubsta3", "sandking", "rebel2", "bison", "sadler",
    "futo", "blista", "prairie", "rhapsody", "issi2", "brioso", "dilettante",
    "firetruk", "mule", "benson", "riot", "guardian", "taco", "panto",
}
Config.FinalePool = { "caddy2", "tractor2", "panto", "rhapsody" }
Config.CarInvincible = true

-- ── Arena ───────────────────────────────────────────────────────────────────
-- Centre of the TOP surface of the deck, high over open water. Every room has
-- its own routing bucket, so rooms never see each other's deck.
Config.Center   = vector3(-2700.0, -900.0, 260.0)
Config.Grid     = 8        -- sections per side
Config.TileSize = 13.0     -- 8 x 13 = 104 m deck

-- The deck reuses Color Rush's streamed tiles; spz-colorrush must be started.
Config.TileModel = "spz_cr_tile_orange"
Config.TileProps = { "stt_prop_stunt_bblock_mdm3", "stt_prop_stunt_bblock_lrg3", "prop_container_05a" }
Config.MaxPropsPerSide = 6

-- ── Grid maths (shared by client and server) ────────────────────────────────
Grid = {}

function Grid.span()    return Config.Grid * Config.TileSize end
function Grid.originX() return Config.Center.x - (Grid.span() * 0.5) end
function Grid.originY() return Config.Center.y - (Grid.span() * 0.5) end

function Grid.tileCenter(ix, iy)
    return Grid.originX() + ((ix + 0.5) * Config.TileSize),
           Grid.originY() + ((iy + 0.5) * Config.TileSize)
end

function Grid.total() return Config.Grid * Config.Grid end
