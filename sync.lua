addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '1.0'
addon.desc    = 'sync'

require('common')
local imgui = require('imgui')
local settings = require('settings')

------------------------------------------------------------
-- LUA / API
------------------------------------------------------------
local AshitaCore  = AshitaCore
local mm          = AshitaCore:GetMemoryManager()
local chat        = AshitaCore:GetChatManager()
local pointer_mgr = AshitaCore:GetPointerManager()

local os_clock      = os.clock
local math_floor    = math.floor
local ipairs        = ipairs
local pairs         = pairs
local pcall         = pcall
local print         = print
local t_insert      = table.insert
local t_remove      = table.remove
local t_clear       = table.clear

local bit_lshift    = bit.lshift
local bit_rshift    = bit.rshift
local bit_band      = bit.band
local bit_bor       = bit.bor

local mem_read_u8   = ashita.memory.read_uint8
local mem_read_u32  = ashita.memory.read_uint32

local igBegin                = imgui.Begin
local igEnd                  = imgui.End
local igBeginTable           = imgui.BeginTable
local igEndTable             = imgui.EndTable
local igTableSetupColumn     = imgui.TableSetupColumn
local igTableNextRow         = imgui.TableNextRow
local igTableNextColumn      = imgui.TableNextColumn
local igTextColored          = imgui.TextColored
local igText                 = imgui.Text
local igTextDisabled         = imgui.TextDisabled
local igCheckbox             = imgui.Checkbox
local igSmallButton          = imgui.SmallButton
local igSetNextWindowBgAlpha = imgui.SetNextWindowBgAlpha
local igBeginDisabled        = imgui.BeginDisabled
local igEndDisabled          = imgui.EndDisabled

local igIsItemHovered        = imgui.IsItemHovered
local igSetTooltip           = imgui.SetTooltip
local igSameLine             = imgui.SameLine

local COLOR_OFFLINE = {1.0, 0.2, 0.2, 1.0}
local COLOR_BUSY    = {1.0, 0.8, 0.0, 1.0}
local COLOR_GUEST   = {0.6, 0.9, 1.0, 1.0}
local COLOR_RECOVERING = {0.4, 0.6, 1.0, 1.0}

local STYLE_BTN = {
    bg     = {0, 0, 0, 0},
    hover  = {1, 1, 1, 0.15},
    active = {1, 1, 1, 0.25},
    -- OPT: GEO green parked here so the always-on render_ui (which already closes
    -- over STYLE_BTN) can reference STYLE_BTN.geo instead of allocating a fresh
    -- {0.4,1.0,0.4,1.0} table twice every frame. Saves steady GC churn at the
    -- 200-local ceiling cost of zero new locals/upvalues.
    geo    = {0.4, 1.0, 0.4, 1.0},
    brd    = {0.75, 0.4, 1.0, 1.0},  -- purple for Singer / BRD panel toggle
}

-- NOTE: tooltip helper. Call IMMEDIATELY after the imgui item to tip. Cheap (one
-- IsItemHovered branch); only resolves the tooltip string when actually hovered.
local function tip(text)
    if igIsItemHovered() then igSetTooltip(text) end
end

local SYNC_WINDOW_FLAGS = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)

local SYNC_WINDOW_OPEN  = {true}

------------------------------------------------------------
-- CONFIGURATION & DICTIONARIES
------------------------------------------------------------
local show_ui = true
local show_guests = true
local show_advanced = false
local show_buffpanel = false
local show_debuffpanel = false

local adv_seeded   = false
-- OPT: three follow-timing constants collapsed into one table to reclaim two
-- locals against the 200-local ceiling (combat mode needs the headroom).
local TIMING = { engage = 0.5, retry = 0.7, settle = 0.5 }

local BUFF_IDS = {
    HASTE = 33, PROTECT = 40, SHELL = 41, REFRESH = 43,
    PHALANX = 116, FLURRY = 265, HASTE_SAMBA = 370, COMPOSURE = 419,
    LIGHT_ARTS = 358, ADDENDUM_WHITE = 401, AFFLATUS_SOLACE = 417, MAJESTY = 621
}

local BUFF_ID_TO_KEY = {
    [BUFF_IDS.HASTE]       = 'h',
    [BUFF_IDS.FLURRY]      = 'fl',
    [BUFF_IDS.REFRESH]     = 'r',
    [BUFF_IDS.PHALANX]     = 'p',
    [BUFF_IDS.COMPOSURE]   = 'comp',
    [BUFF_IDS.PROTECT]     = 'pro',
    [BUFF_IDS.SHELL]       = 'sh',
    [BUFF_IDS.HASTE_SAMBA] = 'samba',
    [BUFF_IDS.LIGHT_ARTS]     = 'larts',
    [BUFF_IDS.ADDENDUM_WHITE] = 'addw',
    [BUFF_IDS.AFFLATUS_SOLACE] = 'solace',
    [BUFF_IDS.MAJESTY]         = 'majesty',
    [113]                      = 'reraise',  -- all Reraise tiers share status 113
}

local chars = {
    { name='shaymin',  is_main=true, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, heal={false}, fl={false}, ref={false}, face={true}, hunt={false}, runto={false} },
    { name='goomy',    is_rdm=true,  f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, heal={false}, fl={false}, ref={false}, face={true}, hunt={false}, runto={false} },
    { name='muunch',                 f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, heal={false}, fl={false}, ref={false}, face={true}, hunt={false}, runto={false} },
    { name='slowpoke',               f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, heal={false}, fl={false}, ref={false}, face={true}, hunt={false}, runto={false} },
    { name='dreepy',                 f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, heal={false}, fl={false}, ref={false}, face={true}, hunt={false}, runto={false} },
}

local BUFF_PRIORITY = {"h","r","pro","sh","p"}
local RDM_SELF_FIRST = {"h","r"}
local COMBAT_FLAG_KEYS = {'e', 'hs', 'bs', 'qs', 'abs', 'deb', 'buf', 'heal'}

local guests = {}
local current_active = {}
local known_cores = {}
local debuff_queue = {}
local slot_addr = {}

local cached_rdm  = nil
local cached_main = nil

local last_engage_target = 0

local ui_columns = {
    { label = 'F', key = 'f',    hdr = 'flw',  tip = 'Follow main  (/sync f [name|all] [on|off])',                              allow_main = false, rdm_only = false },
    { label = 'E', key = 'e',    hdr = 'eng',  tip = 'Engage Tracking - click header to open Combat panel  (/sync e [name|all] [on|off]; /sync combat)',                          allow_main = false, rdm_only = false },
    { label = 'H', key = 'hs',   hdr = 'hsam', tip = 'Haste Samba  (/sync hs [name|all] [on|off])',                             allow_main = false, rdm_only = false },
    { label = 'B', key = 'bs',   hdr = 'box',  tip = 'Box Step  (/sync bs [name|all] [on|off])',                                allow_main = false, rdm_only = false },
    { label = 'Q', key = 'qs',   hdr = 'qui',  tip = 'Quick Step  (/sync qs [name|all] [on|off])',                              allow_main = false, rdm_only = false },
    { label = 'A', key = 'abs',  hdr = 'a-tp', tip = 'Absorb-TP (Aminon)  (/sync abs [name|all] [on|off])',                     allow_main = false, rdm_only = false },
    { label = 'D', key = 'deb',  hdr = 'deb',  tip = 'RDM Debuffs - click header to open controls  (/sync d [name|all] [on|off]; /sync dpanel)', allow_main = false, rdm_only = true  },
    { label = 'B', key = 'buf',  hdr = 'buf',  tip = 'RDM Buffs - click header to open controls  (/sync b [name|all] [on|off]; /sync panel)',   allow_main = true,  rdm_only = false },
    { label = 'C', key = 'heal', hdr = 'cure', tip = 'Cure & Status Removal  (/sync c [name|all] [on|off])',                   allow_main = true,  rdm_only = false }
}

local NUM_UI_COLS = #ui_columns

------------------------------------------------------------
-- GEO (Indi / Geo bubble / Entrust scheduler)
------------------------------------------------------------
-- Sync is the SCHEDULER; the GEO box runs no helper. We fire /ma + /ja lines
-- via its mst_prefix on a duration+jitter cadence and trust the cast to land.
-- Failed casts are picked up on the next jitter window automatically.
-- Everything is folded into one module-level table to keep under LuaJIT's
-- 200-local ceiling: ui flag, spell dictionaries, per-slot timers/jitter,
-- TICK constant. Access via geo_mod.X.
local geo_mod = {
    show_panel = false,
    tick = 1.0,         -- check GEO scheduler at most once per second
    -- suffix list (no Indi-/Geo- prefix); panel builds full names by prefix
    suffixes = {
        'Regen','Poison','Refresh','Haste','STR','DEX','VIT','AGI','INT','MND','CHR',
        'Fury','Barrier','Acumen','Fend','Precision','Voidance','Focus','Attunement',
        'Wilt','Frailty','Fade','Malaise','Slip','Torpor','Vex','Languor',
        'Slow','Paralysis','Gravity'
    },
    indi_spells = {},  -- filled below
    geo_spells  = {},
    -- per-slot timer + jitter state. wear_at = os.clock() epoch when the buff
    -- is expected to drop; jitter is the random pre-wear offset (re-rolled
    -- per fire).
    indi    = { wear_at = 0, jitter = 0 },
    geo     = { wear_at = 0, jitter = 0 },
    entrust = { wear_at = 0, jitter = 0 },
    next_check = 0,
}
for i = 1, #geo_mod.suffixes do
    geo_mod.indi_spells[i] = 'Indi-' .. geo_mod.suffixes[i]
    geo_mod.geo_spells[i]  = 'Geo-'  .. geo_mod.suffixes[i]
end

------------------------------------------------------------
-- COMBAT / HUNT (face-lock + radius pack-hunting)
------------------------------------------------------------
-- All combat-mode state folded into one module table to stay under LuaJIT's
-- 200-local ceiling. Per-character toggles (c.face / c.hunt) live on the chars
-- entries (mirrors c.e). Radius + per-box mob whitelists persist in
-- config.combat (radius, lists[name_lower] = T{...}); face/hunt toggles are
-- runtime and reset on zone with the other combat flags.
--
-- Radius is gated PER-HUNTER (each box's own position vs the mob), since alts
-- can be far from the main. Claim semantics mirror targetbar: low 16 bits of
-- GetClaimStatus, 0 = unclaimed, else a crew sId (masked 0xFFFF) = ours. Spawn
-- bits: 0x10 = mob, 0x01 = PC (excluded, drops players/trusts).
local hunt_mod = {
    show_panel = false,
    open  = {true},
    flags = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar),
    scan_gap   = 2.0,   -- HUNT_SCAN_GAP: rebuild candidate pool at most this often
    next_scan  = 0,
    mob_lo     = 1,     -- entity index scan range for mobs (players sit 0x700+)
    mob_hi     = 0x6FF,
    radius_buf = {12.0}, -- panel input mirror of config.combat.radius
    -- scratch (reused each pass; never re-alloc in the hot loop)
    cand       = {},    -- ordered candidate mob indices (in radius, valid, free-claim)
    cand_hp    = {},    -- [idx] = hp pct  (for highest-HP fallback)
    cand_dist  = {},    -- [idx] = dist^2  (for nearest-first assignment)
    taken      = {},    -- [idx] = true    (mob already assigned this pass)
    crew_mask  = {},    -- [sId & 0xFFFF] = true (in-zone crew, for claim gate)
    engaged    = {},    -- union of crew-engaged mob indices (RDM multi-target)
    eng_n      = 0,
    addbuf     = {},    -- [name_lower] = {''} input buffer for whitelist add
    pullbuf    = {},    -- [name_lower] = {cmd} input buffer for pull action
    rdiabuf    = nil,   -- {cmd} input buffer for the RDM hunt-debuff command
    blbuf      = {''},  -- input buffer for blacklist add
    pulldistbuf = {},   -- [name_lower] -> {n} slider buffer for that box's pull distance
    frangbuf    = {},   -- [name_lower] -> {n} slider buffer for that box's fight (leash) range
    main_goto  = { active = false, x = 0, y = 0, deadline = 0 },  -- main campsite move
    -- RDM hunt-debuff bookkeeping: [idx] = os_clock of last Dia III sent
    diaed      = {},
    -- facing calibration offset (radians) added to every yaw write; set via
    -- /sync faced once, persisted to config.combat.yaw_off.
    yaw_off    = 0.0,
}

------------------------------------------------------------
-- BRD (Bard song cycle -- integrated Singer)
------------------------------------------------------------
-- Singer folded into sync as a remote scheduler. Sync runs on the MAIN only, so
-- the bard (an alt) is driven by forwarding every song/JA with do_action via the
-- bard mst_prefix (/mst <character> ...), paced by that box action_lock --
-- structurally identical to the GEO scheduler. The main can't read the bard
-- recast timers or its song-JA buffs, and it doesn't try to: each enabled JA is
-- ATTEMPTED ONCE PER CYCLE (Marcato/Pianissimo once per row) straight off the
-- playlist toggles -- if it's on cooldown the game ignores the command and the
-- cycle moves on. All state + the song dictionary + UI buffers hang off this one
-- table to keep the main chunk under the 200-local ceiling (no new local; the
-- subsystem rides on geo_mod, the established multi-feature container).
geo_mod.brd = {
    show_window = false,
    open  = {true},
    flags = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar),
    poll  = 0.1,            -- min seconds between scheduler ticks
    next_check = 0,
    ja_lock   = 1.2,        -- action_lock seconds applied after a JA fire
    song_cast = 4.0,        -- base song cast estimate; config.brd.delay is added on top
    seeded = false,
    -- Cycle: idx walks the playlist 1..#songs+1; phase casting|waiting; start =
    -- os.time() epoch of the current cycle; ann60/ann30 = one-shot reminder flags.
    -- ja_done = per-cycle one-shot flags for the global JAs; row_* track the
    -- current row's per-row JAs. NO timer monitoring -- the playlist toggles alone
    -- decide what is attempted; a JA on cooldown is simply ignored by the game and
    -- the cycle moves on.
    cycle = {
        idx = 1, phase = 'casting', start = os.time(), ann60 = false, ann30 = false,
        ja_done = { soul_voice = false, nightingale = false, troubadour = false, clarion = false },
        row_idx = 0, row_marcato = false, row_pianissimo = false,
    },
    buf = {
        character  = {''},
        song_input = {''},
        pl_save    = {''},
        pl_idx     = {0},
        last_pl    = nil,
        -- OPT: persistent single-element mirrors for the static checkboxes below,
        -- reused every frame instead of `local ref = {b.X}` allocating a fresh
        -- table on each of the ~7 checkboxes every frame the window is open.
        -- Value is re-synced from config.brd on every render call (not just on
        -- reseed), so an external change -- /sync brd nightingale off, etc. --
        -- while the window is open still shows correctly; only the table itself
        -- is reused, never the value.
        sing_ref        = {false},
        nightingale_ref = {false},
        troubadour_ref  = {false},
        soul_voice_ref  = {false},
        clarion_ref     = {false},
        announce_ref    = {false},
        engagelock_ref  = {false},
        -- OPT: lazily-created per-row buffer set, keyed by song NAME (stable
        -- across move up/down, unlike row index). See geo_mod.brd.row_buf.
        row = {},
    },
}
-- Song id -> name (verbatim from Singer sing_get). Drives /sync brd add fuzzy
-- resolve and cycle song-name validation.
geo_mod.brd.song = {

    [368] = 'Foe Requiem',          [369] = 'Foe Requiem II',       [370] = 'Foe Requiem III',
    [371] = 'Foe Requiem IV',       [372] = 'Foe Requiem V',        [373] = 'Foe Requiem VI',
    [374] = 'Foe Requiem VII',      [375] = 'Foe Requiem VIII',     [376] = 'Horde Lullaby',
    [377] = 'Horde Lullaby II',     [378] = 'Army\'s Paeon',        [379] = 'Army\'s Paeon II',
    [380] = 'Army\'s Paeon III',    [381] = 'Army\'s Paeon IV',     [382] = 'Army\'s Paeon V',
    [383] = 'Army\'s Paeon VI',     [384] = 'Army\'s Paeon VII',    [385] = 'Army\'s Paeon VIII',
    [386] = 'Mage\'s Ballad',       [387] = 'Mage\'s Ballad II',    [388] = 'Mage\'s Ballad III',
    [389] = 'Knight\'s Minne',      [390] = 'Knight\'s Minne II',   [391] = 'Knight\'s Minne III',
    [392] = 'Knight\'s Minne IV',   [393] = 'Knight\'s Minne V',    [394] = 'Valor Minuet',
    [395] = 'Valor Minuet II',      [396] = 'Valor Minuet III',     [397] = 'Valor Minuet IV',
    [398] = 'Valor Minuet V',       [399] = 'Sword Madrigal',       [400] = 'Blade Madrigal',
    [401] = 'Hunter\'s Prelude',    [402] = 'Archer\'s Prelude',    [403] = 'Sheepfoe Mambo',
    [404] = 'Dragonfoe Mambo',      [405] = 'Fowl Aubade',          [406] = 'Herb Pastoral',
    [407] = 'Chocobo Hum',          [408] = 'Shining Fantasia',     [409] = 'Scop\'s Operetta',
    [410] = 'Puppet\'s Operetta',   [411] = 'Jester\'s Operetta',   [412] = 'Gold Capriccio',
    [413] = 'Devotee Serenade',     [414] = 'Warding Round',        [415] = 'Goblin Gavotte',
    [416] = 'Cactuar Fugue',        [417] = 'Honor March',          [418] = 'Aria of Passion',
    [419] = 'Advancing March',      [420] = 'Victory March',        [421] = 'Battlefield Elegy',
    [422] = 'Carnage Elegy',        [423] = 'Massacre Elegy',       [424] = 'Sinewy Etude',
    [425] = 'Dextrous Etude',       [426] = 'Vivacious Etude',      [427] = 'Quick Etude',
    [428] = 'Learned Etude',        [429] = 'Spirited Etude',       [430] = 'Enchanting Etude',
    [431] = 'Herculean Etude',      [432] = 'Uncanny Etude',        [433] = 'Vital Etude',
    [434] = 'Swift Etude',          [435] = 'Sage Etude',           [436] = 'Logical Etude',
    [437] = 'Bewitching Etude',     [438] = 'Fire Carol',           [439] = 'Ice Carol',
    [440] = 'Wind Carol',           [441] = 'Earth Carol',          [442] = 'Lightning Carol',
    [443] = 'Water Carol',          [444] = 'Light Carol',          [445] = 'Dark Carol',
    [446] = 'Fire Carol II',        [447] = 'Ice Carol II',         [448] = 'Wind Carol II',
    [449] = 'Earth Carol II',       [450] = 'Lightning Carol II',   [451] = 'Water Carol II',
    [452] = 'Light Carol II',       [453] = 'Dark Carol II',        [454] = 'Fire Threnody',
    [455] = 'Ice Threnody',         [456] = 'Wind Threnody',        [457] = 'Earth Threnody',
    [458] = 'Ltng. Threnody',       [459] = 'Water Threnody',       [460] = 'Light Threnody',
    [461] = 'Dark Threnody',        [462] = 'Magic Finale',         [463] = 'Foe Lullaby',
    [464] = 'Goddess\'s Hymnus',    [465] = 'Chocobo Mazurka',      [466] = 'Maiden\'s Virelai',
    [467] = 'Raptor Mazurka',       [468] = 'Foe Sirvente',         [469] = 'Adventurer\'s Dirge',
    [470] = 'Sentinel\'s Scherzo',  [471] = 'Foe Lullaby II',       [472] = 'Pining Nocturne',
    [871] = 'Fire Threnody II',     [872] = 'Ice Threnody II',      [873] = 'Wind Threnody II',
    [874] = 'Earth Threnody II',    [875] = 'Ltng. Threnody II',    [876] = 'Water Threnody II',
    [877] = 'Light Threnody II',    [878] = 'Dark Threnody II',
}
-- OPT: reverse lookup (normalized name -> canonical name), built once so
-- song_valid/song_from_command are O(1) instead of re-lowercasing and
-- linear-scanning this ~110-entry dictionary on every cycle/command call.
-- Keyed by the fully-normalized form (whitespace/punctuation stripped,
-- lowercased) -- strictly more aggressive than song_valid's plain :lower(),
-- and safe to share since no two canonical names collide once normalized.
geo_mod.brd.song_lookup = {}
for _, name in pairs(geo_mod.brd.song) do
    geo_mod.brd.song_lookup[(name:gsub('[%s%p]', '')):lower()] = name
end

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function blank_buffs()
    return { h=false, r=false, p=false, fl=false, comp=false, pro=false, sh=false, samba=false,
             larts=false, addw=false, solace=false, majesty=false, reraise=false }
end

local function get_debuff_queue(targetIdx, rdm)
    if not targetIdx or targetIdx == 0 then return {} end
    if not debuff_queue[targetIdx] then
        local q = {}
        if rdm and rdm.sil  and rdm.sil[1]  then t_insert(q, { name="Silence",      done=false }) end
        if rdm and rdm.dia  and rdm.dia[1]  then t_insert(q, { name="Dia III",      done=false }) end
        if rdm and rdm.fraz and rdm.fraz[1] then t_insert(q, { name="Frazzle III",  done=false }) end
        if rdm and rdm.dist and rdm.dist[1] then t_insert(q, { name="Distract III", done=false }) end
        debuff_queue[targetIdx] = q
    end
    return debuff_queue[targetIdx]
end

local BUFF_RETRY_GAP = 15.0
local RDM_FAST_CAST  = 0.50
local ANIMATION_LOCK = 2.75
-- NOTE(blind guests): when a target is UNREADABLE (cross-party AND no fresh
-- rdmhelper report) the RDM cannot tell whether the buff is up, so the normal
-- 15s retry turns into a permanent spam cycle. BUFF_BLIND_GAP is the fallback
-- retry-gap used in that case -- 6 minutes, well past Haste II / Flurry II's
-- natural duration so the buff is re-applied once per cycle instead of every
-- tick. Used by check_needs together with REPORT_BUFF_TTL (the report-freshness
-- window: a target with last_rep_time within this many seconds is treated as
-- readable since rep_buffs is OR'd over the memory scan).
local BUFF_BLIND_GAP   = 360.0
local REPORT_BUFF_TTL  = 15.0

local SPELL_CAST_TIMES = {
    ["Refresh III"] = 3.0,   ["Distract III"] = 3.0,
    ["Haste"] = 5.0,         ["Haste II"] = 3.0,
    ["Phalanx II"] = 3.0,
    ["Flurry II"] = 3.0,
    ["Phalanx"] = 3.0,       ["Protect V"] = 3.0,
    ["Shell V"] = 3.0,       ["Silence"] = 3.0,
    ["Dia III"] = 2.5,       ["Frazzle III"] = 3.0,
    ["Cure II"] = 2.0,       ["Cure III"] = 2.25,
    ["Cure IV"] = 2.5,       ["Cure V"] = 2.75,
    ["Cure VI"] = 3.0,
    ["Sleep II"] = 2.5,      ["Regen IV"] = 2.0,
    ["Curaga II"] = 2.25,    ["Curaga III"] = 2.5,
    ["Curaga IV"] = 2.75,    ["Curaga V"] = 3.0,
    ["Poisona"] = 2.0,       ["Paralyna"] = 2.0,
    ["Blindna"] = 2.0,       ["Silena"] = 2.0,
    ["Stona"] = 2.0,         ["Viruna"] = 2.0,
    ["Cursna"] = 2.0,        ["Erase"] = 2.0,
    ["Reraise"] = 12.0,      ["Reraise II"] = 12.0,
    ["Reraise III"] = 12.0,  ["Reraise IV"] = 12.0,
}

local function get_cast_delay(spell)
    local base_time = SPELL_CAST_TIMES[spell] or 3.0
    return (base_time * (1.0 - RDM_FAST_CAST)) + ANIMATION_LOCK
end

local function _resolve_target(targ)
    return targ:GetTargetIndex(targ:GetIsSubTargetActive())
end

local function get_target_index(targ)
    if not targ then return 0 end
    local ok, idx = pcall(_resolve_target, targ)
    return (ok and idx and idx > 0) and idx or 0
end

local get_player_target = get_target_index

local function GetTargetOfTarget(targ, ent)
    if not ent then return 0 end
    local idx = get_target_index(targ)
    if idx == 0 then return 0 end
    local tot = ent:GetTargetedIndex(idx)
    return (tot and tot > 0) and tot or 0
end

------------------------------------------------------------
-- ENGAGE RETRY
------------------------------------------------------------
local function queue_retry(c, cmd, now)
    c.retry = { cmd = cmd, time = now + TIMING.retry, is_attack = cmd:find('/attack', 1, true) ~= nil }
end

local function process_retry(c, now, party, ent)
    local r = c.retry
    if not r or now < r.time then return end
    if r.is_attack then
        local pIdx   = c.pt_data and c.pt_data.index
        local entIdx = pIdx and party:GetMemberTargetIndex(pIdx) or 0
        local status = (entIdx > 0) and ent:GetStatus(entIdx) or 0
        if status ~= 1 then
            chat:QueueCommand(1, r.cmd)
        end
    else
        chat:QueueCommand(1, r.cmd)
    end
    c.retry = nil
end

------------------------------------------------------------
-- STATE UTILS
------------------------------------------------------------
local function qcmd(cmd, isFollow)
    if not isFollow then
        local player = mm:GetPlayer()
        if player and player:GetIsZoning() ~= 0 then return end
    end
    chat:QueueCommand(1, cmd)
end

local function do_action(c, cmd, lock_time, current_time)
    qcmd(c.mst_prefix .. cmd)
    c.action_lock = current_time + lock_time
end

-- Deferred casts: a few combos need a short gap between two casts on the same
-- box (Accession -> Cure/Regen). Queue the follow-up and drain it when due.
local pending_casts = {}
local function queue_cast(c, cmd, fire_at, extra_lock)
    pending_casts[#pending_casts + 1] = { prefix = c.mst_prefix, cmd = cmd, at = fire_at }
    if extra_lock then c.action_lock = fire_at + extra_lock end
end
local function drain_pending(now)
    if #pending_casts == 0 then return end
    local keep = {}
    for _, p in ipairs(pending_casts) do
        if now >= p.at then qcmd(p.prefix .. p.cmd) else keep[#keep + 1] = p end
    end
    pending_casts = keep
end

local function init_char_state(c)
    c.name_lower = c.name:lower()
    c.disp_name  = c.name:sub(1,3):upper()
    c.mst_prefix = '/mst ' .. c.name .. ' '
    c.cmd_follow_on  = c.mst_prefix .. '/ms follow on'
    c.cmd_follow_off = c.mst_prefix .. '/ms follow off'
    c.cmd_attack_on  = c.mst_prefix .. '/attack [t]'
    c.cmd_attack_off = c.mst_prefix .. '/attack off'
    c.action_lock  = 0
    c.comp_lock    = 0
    c.convert_lock = 0
    c.ds_lock          = 0
    c.silence_item_lock = 0
    c.wake_lock        = 0
    c.cast_reserved_until = 0
    c.solace_lock      = 0
    c.larts_lock       = 0
    c.addw_lock        = 0
    c.solace_seen      = 0  
    c.larts_seen       = 0
    c.addw_seen        = 0
    c.reraise_seen     = 0
    c.reraise_lock     = 0
    -- WHM-main extras (Protectra V, Shellra V, Auspice, Boost-X, Bar-Element,
    -- Bar-Status, Accession+Regen). Each holds os_clock() of last fire so the
    -- pass can gate `now - last >= recast`.
    c.extra_last = { protectra=0, shellra=0, auspice=0, boost=0, barel=0, barst=0, regen=0 }
    c.last_extra_cast = 0   -- os_clock of the last WHM-extra fired (EXTRAS_MIN_GAP spacing)
    c.comp_seen        = 0
    c.job              = 0
    c.sjob             = 0
    c.sjlvl            = 0
    c._kit_mj          = -1
    c._kit_sj          = -1
    c._prof_mj         = -1   -- OPT: memoized build_profile key (mj/sj/sjlvl) + result
    c._prof_sj         = -1
    c._prof_sl         = -1
    c._prof            = nil
    c.buff_locks   = {}
    c.low_mp_mode  = false
    c.emergency_refresh = false
    c.in_zone      = false
    c.actual_follow = nil
    c.buffs = blank_buffs()
    c.rep_buffs = blank_buffs()  -- last GetBuffs-accurate wire snapshot (OR'd over the memory scan)
    c.status = 0
    c.last_status_time = 0
    c.last_rep_time = 0
    c.ui_ids = {}
    c.last_engage_target = 0
    c.last_engage_time   = 0
    c.auto_engaged       = false
    c.retry              = nil
    c.debuff_pause       = false
    c.fl  = c.fl  or {false}
    c.ref = c.ref or {false}
    c.heal = c.heal or {false}
    if c.is_rdm then c.ref[1] = true end
    -- Per-buff casting toggles for the RDM Buff Controls panel. Durable across
    -- zones (not in COMBAT_FLAG_KEYS); the master 'buf' still gates the member.
    -- Default-cycle buffs default ON so legacy "buf on = Haste+Protect+Shell+
    -- Phalanx" is preserved; Flurry/Refresh are opt-in appends (default OFF, set
    -- via fl/ref above). bh and fl share the Haste priority slot, mutually excl.
    c.bh   = c.bh   or {true}    -- cast Haste line (exclusive with Flurry)
    c.bpro = c.bpro or {false}    -- cast Protect
    c.bsh  = c.bsh  or {false}    -- cast Shell
    c.bp   = c.bp   or {true}    -- cast Phalanx
    if c.is_rdm then
        c.sil  = c.sil  or {false}
        c.dist = c.dist or {false}
        c.fraz = c.fraz or {false}
        c.dia  = c.dia  or {true}

    end
    for _, col in ipairs(ui_columns) do
        c.ui_ids[col.key] = '##' .. col.key .. '_' .. c.name_lower
    end

    c.buff_ids = {
        buf  = '##bp_buf_'  .. c.name_lower,
        bh   = '##bp_bh_'   .. c.name_lower,
        fl   = '##bp_fl_'   .. c.name_lower,
        ref  = '##bp_ref_'  .. c.name_lower,
        bpro = '##bp_bpro_' .. c.name_lower,
        bsh  = '##bp_bsh_'  .. c.name_lower,
        bp   = '##bp_bp_'   .. c.name_lower,
    }
    c.debuff_ids = {
        sil  = '##dp_sil_'  .. c.name_lower,
        dia  = '##dp_dia_'  .. c.name_lower,
        fraz = '##dp_fraz_' .. c.name_lower,
        dist = '##dp_dist_' .. c.name_lower,
    }
    if c.is_rdm  then cached_rdm  = c end
    if c.is_main then cached_main = c end
end

------------------------------------------------------------
-- PERSISTENT SETTINGS (crew roster + per-healer heal config)
------------------------------------------------------------
-- Per-healer cure/curaga tables are { [tier] = HP% at-or-below which that tier
-- fires }; 0 disables a tier (e.g. tiers a job can't cast). The highest enabled
-- threshold doubles as the heal gate. na = this healer does status removal;
-- solace/arts = maintain that healer's stance (only applied where the job grants
-- it). Both healers.* slots are concurrent co-healers running independently; the
-- cross-healer claim keeps them off the SAME target. Divine Seal is gated by WHM
-- job (main job WHM, or /WHM >= 30) -- NOT by slot. Edits in the Advanced window
-- persist here, per character.
local default_settings = T{
    crew = T{ 'shaymin', 'goomy', 'muunch', 'slowpoke', 'dreepy' },
    healers = T{
        T{ name = 'slowpoke', na = true, solace = true,  arts = false, majesty = false, ds = true,  dsthresh = 40,
           haste1 = false,
           reraise = false, reraisespell = 'Reraise IV',
           silence = true, silenceitem = 'Echo Drops', silencegap = 15.0,
           cure   = T{ [1]=100,  [2]=82.5, [3]=77.5, [4]=70, [5]=55, [6]=45 },
           curaga = T{ [1]=82.5, [2]=80,   [3]=65,   [4]=50, [5]=40 }, curagamin = 2,
           -- WHM-main proactive buffs / AoE Regen monitor. Each entry is timer-
           -- driven (no rdmhelper buff plumbing) -- recast is the MM:SS-style
           -- interval between auto-casts. recast values below stay UNDER the
           -- natural buff duration so we refresh before the buff drops:
           --   Protectra V / Shellra V: ~30min wear -> 28:20 default
           --   Auspice:                 3min   wear -> 02:50
           --   Boost-stat:              5min   wear -> 04:40
           --   Bar-Element / Bar-Status: 3min  wear -> 02:50
           --   Regen (Accession+Regen): cycle every 1:30 by default
           extras = T{
               protectra = T{ enabled = false, recast = 1700 },
               shellra   = T{ enabled = false, recast = 1700 },
               auspice   = T{ enabled = false, recast = 170 },
               boost     = T{ enabled = false, recast = 280, spell = 'Boost-STR' },
               barel     = T{ enabled = false, recast = 170, spell = 'Barfire'   },
               barst     = T{ enabled = false, recast = 170, spell = 'Barsleep'  },
               regen     = T{ enabled = false, recast = 90,  spell = 'Regen IV'  },
           } },
        T{ name = 'goomy',    na = true, solace = false, arts = false, majesty = false, ds = false, dsthresh = 40,
           haste1 = false,
           reraise = false, reraisespell = 'Reraise',
           silence = true, silenceitem = 'Echo Drops', silencegap = 15.0,
           cure   = T{ [1]=70,   [2]=60,   [3]=50,   [4]=40, [5]=0,  [6]=0 },
           curaga = T{ [1]=0,    [2]=0,    [3]=0,    [4]=0,  [5]=0 }, curagamin = 2,
           extras = T{
               protectra = T{ enabled = false, recast = 1700 },
               shellra   = T{ enabled = false, recast = 1700 },
               auspice   = T{ enabled = false, recast = 170 },
               boost     = T{ enabled = false, recast = 280, spell = 'Boost-STR' },
               barel     = T{ enabled = false, recast = 170, spell = 'Barfire'   },
               barst     = T{ enabled = false, recast = 170, spell = 'Barsleep'  },
               regen     = T{ enabled = false, recast = 90,  spell = 'Regen IV'  },
           } },
    },
    -- Combat / hunt persistence. radius = yalm acquisition radius (squared at
    -- use). lists[name_lower] = T{ 'Mob Name', ... }; an empty/absent list means
    -- that box hunts ANY valid mob in radius (pack-hunting picks distinct mobs).
    combat = T{
        radius  = 12.0,
        yaw_off = 0.0,
        camp_x  = 0.0, camp_y = 0.0, camp_set = false,
        lists   = T{},
        pull    = T{},   -- [name_lower] = pull command string ('' = none)
        rdm_dia = '/ma "Dia III" <t>',  -- RDM hunt-mode debuff cycled across mobs
        blacklist = T{},  -- mob names never hunted by any box
        pull_dist   = T{},   -- [name_lower] = yalms; box fires its pull only within this range (default 20.0)
        fight_range = T{},   -- [name_lower] = yalms leash from the engaged mob; box closes distance if it
                              -- drifts beyond this (default 3.5; max 4.9 for Taru melee range)
        huntmode    = T{},    -- per-box: 0=off 1=hunt(distinct) 2=converge(same mob)
        retmode     = T{},    -- per-box camp return: 0=off 1=on-claim 2=on-death
    },
    -- GEO scheduler config. character = '' disables the entire block (zero work
    -- in the logic loop). Durations are user-specified (no equipment parsing);
    -- recast jitter fires the spell randomly between (duration - recast_max)
    -- and (duration - recast_min) seconds BEFORE the configured wear-off.
    -- Geo bubble target_mode: 'party' = named party member, 'mob' = current
    -- engaged target (combat_only gates this on the main being engaged).
    -- JAs: bog fires immediately BEFORE the Geo bubble cast; ea + demat fire
    -- ~5s and ~7s AFTER the Geo bubble cast (anchored on the luopan).
    geo = T{
        character = '',
        active = true,
        indi = T{
            spell = 'Indi-Precision',
            duration = 240,
            recast_min = 30,
            recast_max = 60,
        },
        geo = T{
            spell = 'Geo-Frailty',
            duration = 240,
            recast_min = 30,
            recast_max = 60,
            target_mode = 'party',
            target = '',
            combat_only = true,
        },
        entrust = T{
            spell = 'Indi-Haste',
            duration = 240,
            recast_min = 30,
            recast_max = 60,
            target = '',
        },
        ja = T{ bog = false, ea = false, demat = false },
        sets = T{
            -- Examples. Each set captures all three spells PLUS the JA toggles.
            -- Edit / add via the panel or /sync geo set ...
            T{ name='dps',  indi='Indi-Haste',   geo='Geo-Frailty', entrust='Indi-Fury',
               bog=true,  ea=true,  demat=false },
            T{ name='tank', indi='Indi-Barrier', geo='Geo-Wilt',    entrust='Indi-Haste',
               bog=false, ea=false, demat=true },
        },
    },
    -- BRD box assignment. BRD (Bard song cycle) -- Singer folded in; the
    -- standalone addon is no longer loaded. Full playlist + JA toggles + named
    -- playlists live here so they persist through sync's own settings.
    -- character names the bard box; songs/JAs are forwarded to it via /mst
    -- (sync runs on the main only, so the bard is driven entirely remotely).
    brd = T{
        character        = '',
        sing             = false,
        nightingale      = true,
        troubadour       = true,
        soul_voice       = false,
        clarion          = false,
        delay            = 2.0,
        interval         = 240,
        announce         = true,
        engagelock       = false,
        debug            = false,
        playlists        = T{},
        current_playlist = '',
        songs            = T{},
    },
}
local config = settings.load(default_settings)
if not config.combat then config.combat = T{ radius = 12.0, lists = T{} } end
if not config.combat.lists then config.combat.lists = T{} end
if not config.combat.pull  then config.combat.pull  = T{} end
if config.combat.rdm_dia == nil then config.combat.rdm_dia = '/ma "Dia III" <t>' end
if not config.combat.blacklist then config.combat.blacklist = T{} end
-- pull_dist / fight_range MIGRATION: older saved configs had these as a single
-- global number. Per-character control replaces that; the old global value (if
-- present) becomes nobody's setting -- defaults (20.0 / 3.5) apply per-box until
-- the user dials each box in individually via the Combat panel.
if type(config.combat.pull_dist) ~= 'table' then config.combat.pull_dist = T{} end
if type(config.combat.fight_range) ~= 'table' then config.combat.fight_range = T{} end
if not config.combat.retmode then config.combat.retmode = T{} end
if not config.combat.huntmode   then config.combat.huntmode   = T{} end
if config.combat.camp_set == nil then config.combat.camp_set = false end
if not config.brd then config.brd = T{ character = '' } end
if config.brd.character == nil then config.brd.character = '' end
do
    -- BRD field defaulting + entry migration (mirrors Singer load-time pass).
    -- No `local` here -- the main chunk sits exactly at the 200-local ceiling.
    if config.brd.sing        == nil then config.brd.sing        = false end
    if config.brd.nightingale == nil then config.brd.nightingale = true  end
    if config.brd.troubadour  == nil then config.brd.troubadour  = true  end
    if config.brd.soul_voice  == nil then config.brd.soul_voice  = false end
    if config.brd.clarion     == nil then config.brd.clarion     = false end
    if config.brd.delay       == nil then config.brd.delay       = 2.0   end
    if config.brd.interval    == nil then config.brd.interval    = 240   end
    if config.brd.announce    == nil then config.brd.announce    = true  end
    if config.brd.engagelock  == nil then config.brd.engagelock  = false end
    if config.brd.debug       == nil then config.brd.debug       = false end
    if not config.brd.playlists then config.brd.playlists = T{} end
    if config.brd.current_playlist == nil then config.brd.current_playlist = '' end
    if not config.brd.songs then config.brd.songs = T{} end
    for _, e in ipairs(config.brd.songs) do
        if e.enabled    == nil then e.enabled    = true  end
        if e.marcato    == nil then e.marcato    = false end
        if e.pianissimo == nil then e.pianissimo = false end
        if e.target     == nil then e.target     = ''    end
    end
end
hunt_mod.radius_buf[1] = config.combat.radius or 12.0
hunt_mod.yaw_off = config.combat.yaw_off or 0.0

-- Apply persisted crew names BEFORE per-char state is derived below.
for i = 1, #chars do
    if config.crew[i] and config.crew[i] ~= '' then chars[i].name = config.crew[i] end
end

for _, c in ipairs(chars) do init_char_state(c); known_cores[c.name_lower] = true end

------------------------------------------------------------
-- RDM HELPER FUNCTIONS
------------------------------------------------------------
local function check_needs(t, key, rdm, now)
    if not t or not t.in_zone or not t.pt_data or not t.buf or not t.buf[1] then return false end

    -- Guest scope limiter: a guest is anyone not on the crew (not running our
    -- rdmhelper, no per-buff UI surface). Cross-party Refresh / Phalanx already
    -- block at the same-party gate below, and long-duration buffs like Protect /
    -- Shell are out of scope on a non-coordinated target -- the user prefers to
    -- handle them manually if applicable. So a guest only receives the Haste
    -- column (key 'h', which covers both Haste II and Flurry II via fl).
    if t.is_guest and key ~= 'h' then return false end

    local is_self = (t.name_lower == rdm.name_lower)

    if key == 'comp' and rdm.buffs.comp then return false end

    if (key == 'r' or key == 'p') and not is_self then
        if not rdm.pt_data or not t.pt_data then return false end
        -- OPT 3: use the precomputed pt_data.group (set in update_membership_and_zones)
        -- instead of recomputing math_floor(index/6) every RDM buff loop iteration.
        if rdm.pt_data.group ~= t.pt_data.group then
            return false
        end
    end

    local want = key
    if key == 'h' then
        local want_fl = t.fl and t.fl[1]
        local want_h  = t.bh and t.bh[1]
        if not (want_fl or want_h) then return false end
        if want_fl then want = 'fl' end
    elseif key == 'pro' then
        if not (t.bpro and t.bpro[1]) then return false end
    elseif key == 'sh' then
        if not (t.bsh and t.bsh[1]) then return false end
    elseif key == 'p' then
        if not (t.bp and t.bp[1]) then return false end
    end

    if t.buffs and t.buffs[want] then return false end

    if key == 'r' and not is_self and not (t.ref and t.ref[1]) then return false end

    -- Retry-gap selector. A target is READABLE when we can verify whether the
    -- buff actually landed -- either our own alliance party (memory scan, idx
    -- < 6) or a fresh rdmhelper report within REPORT_BUFF_TTL. Otherwise the
    -- buff scan reads ABSENT no matter how many times we cast (no memory, no
    -- report), so the 15s loop turns into spam. Bump to BUFF_BLIND_GAP (6min)
    -- in that case so the buff is re-applied once per cycle, not every tick.
    local readable = (t.pt_data.index < 6) or (now - (t.last_rep_time or 0) < REPORT_BUFF_TTL)
    local gap = readable and BUFF_RETRY_GAP or BUFF_BLIND_GAP
    local locks = rdm.buff_locks[t.name]
    if not locks then locks = {}; rdm.buff_locks[t.name] = locks end
    if now - (locks[key] or 0) < gap then return false end

    return true
end

------------------------------------------------------------
-- HEAL (CURE + CURAGA + STATUS REMOVAL)
-- `heal` is a RECIPIENT flag (like `buf`): healers cure / -na any in-zone member
-- that has it set. Two healers (config.healers slots) run concurrently:
--   Each runs its FULL kit independently (cures, curaga, wakes, -na, stances).
--   Divine Seal is available to whichever healer is on WHM (main or /WHM>=30),
--   regardless of slot. The cross-healer claim is what keeps the two from
--   curing/waking the same target or stripping the same (target,bit) -- so they
--   help in parallel without doubling MP/time on one member.
-- Each healer's per-tier HP% table is its own tier selector AND heal gate (a tier
-- set to 0 is off); tiers are clamped to the healer's live job cap.
--
-- Cures use party HP% (alliance-wide, near real-time) so they cross parties.
-- Curaga only heals the CASTER's own party, so it is gated to the healer's party
-- group. Status removal reads each recipient's `t.status` bitfield (rdmhelper
-- reports; main reads its own locally) and -na ignores party lines.
--
-- WHM specifics: Cure->Cure V, Curaga->Curaga V, Divine Seal (potency burst),
-- Afflatus Solace (cure stance). RDM caps at Cure IV and has no Curaga/JAs.
------------------------------------------------------------
-- Cure/Curaga gating is per-healer: each healer's per-tier HP% table (in the
-- settings file / Advanced window) is both the tier selector and the heal gate.
local EMERGENCY_PCT  = 40    -- NOTE: at/below this the main WHM pops Divine Seal
local CURE_MIN_MP    = 40    -- NOTE: skip cures below this when MP is readable
local CURE_RETRY_GAP = 3.5   -- NOTE: per-target re-cure guard (HP table latency)
-- NOTE(heal stagger): cross-healer claim window. When one healer commits a heal
-- (cure/curaga/wake) to a target, the OTHER healer defers on that SAME target
-- until the cast has had time to LAND -- the commit sites claim for the spell's
-- cast delay + HEAL_LAND_MARGIN, not the bare HEAL_STAGGER, so the second healer
-- can't fire a now-wasted cure into a target the first already topped (the bug:
-- with a 1.5s claim the second healer re-picked the target mid-cast, even when
-- thresholds differed). The claiming healer is exempt from its own claim and
-- re-cures on its own per-target CURE_RETRY_GAP; after the claim lapses the other
-- healer legitimately helps only if the target is STILL below its threshold.
local HEAL_STAGGER     = 1.5
local HEAL_LAND_MARGIN = 1.5   -- NOTE: extra time past a cure's cast delay for HP% to refresh before the other healer may re-pick the target
local heal_claim_by    = {}   -- [target_name] = name_lower of the claiming healer
local heal_claim_until = {}   -- [target_name] = os_clock expiry of the claim
local function heal_claimed_by_other(healer, name, now)
    return (heal_claim_until[name] or 0) > now and heal_claim_by[name] ~= healer.name_lower
end
local function claim_heal(healer, name, now, dur)
    heal_claim_by[name]    = healer.name_lower
    heal_claim_until[name] = now + (dur or HEAL_STAGGER)
end
-- (na stagger): same idea as heal claims but keyed per (target, status-bit) so
-- the two healers can still strip DIFFERENT ailments off one target in parallel --
-- only the SAME ailment on the SAME target is deferred (the wasteful case). Reuses
-- HEAL_STAGGER; the key string is built only when a removable bit is actually set.
local na_claim_by    = {}   -- [name..'#'..bit] = claiming healer name_lower
local na_claim_until = {}   -- [name..'#'..bit] = os_clock expiry
local function na_claimed_by_other(healer, name, b, now)
    local k = name .. '#' .. b
    return (na_claim_until[k] or 0) > now and na_claim_by[k] ~= healer.name_lower
end
local function claim_na(healer, name, b, now)
    local k = name .. '#' .. b
    na_claim_by[k]    = healer.name_lower
    na_claim_until[k] = now + HEAL_STAGGER
end
local WAKE_MIN_MP    = 12    -- NOTE: keep this low so a wake is NOT blocked by the routine CURE_MIN_MP floor.
local NA_MIN_MP      = 12
local NA_RETRY_GAP   = 4.0   -- NOTE: per-(target,status) re-cast guard
local CHARM_SLEEP_GAP = 8.0  -- NOTE: RDM Sleep II re-cast guard on a charmed member
local CHARM_SLEEP_MAX   = 3    -- NOTE: max Sleep II attempts per charm episode before the RDM
                               -- gives up. A member that resists every cast, or is woken
                               -- instantly by a DoT, can't be kept down -- stop cycling Sleep.
local CHARM_SLEEP_STUCK = 6.0  -- NOTE: a Sleep that HOLDS this long is treated as working and
                               -- refunds the attempt budget, so a long charm keeps getting
                               -- re-slept on each natural wake. Sits above the DoT tick (~3s)
                              
local CURAGA_MIN_TARGETS = 2
local DIVINE_SEAL_RECAST = 240.0 
-- Stance maintenance (Afflatus Solace / Light Arts + Addendum: White) is per-healer
-- see each healer's toggles. /SCH -na still requires Addendum: White, so
-- disabling a /SCH healer's arts also stops its -na.
local STANCE_GUARD        = 8.0   -- NOTE: recast-suppression after a stance cast -- covers JA
                                  -- animation + buff registration so we never re-fire mid-land.
                                  -- Used for cast lockouts where a separate timer (Majesty
                                  -- refresh, Reraise) drives the longer-term re-cast cadence.
-- FIX(stance spam): non-expiring stances (Light Arts, Addendum: White, Afflatus Solace) MUST
-- NOT re-attempt on a flickering memory read or a dropped report -- the JA animation eats a
-- cast slot for ~1.5s and is wasteful/harmful. After a successful cast we lock the slot for
-- PERMA_STANCE_GUARD (matches Composure's 295s pattern). A genuine dispel is picked up after
-- the lock expires via the existing absent-debounce path.
local PERMA_STANCE_GUARD  = 300.0
local STANCE_READABLE_GAP = 5.0   -- NOTE: cross-party report freshness for stance gating
local STANCE_LOSS_DEBOUNCE = 15.0 -- FIX(stance spam): a stance must read ABSENT continuously for
                                  -- this long (since it was last SEEN up) before it is re-cast.
                                  -- Bumped from 4.0 -- intermittent memory-icon misses can run
                                  -- 4-10s in the wild even with a fresh rdmhelper report; the
                                  -- 15s floor survives those without re-firing an already-up
                                  -- stance. Only a sustained genuine loss (or a zone) re-fires.
local MAJESTY_REFRESH      = 170.0  -- NOTE(PLD): Majesty is a 180s buff, NOT a persistent
                                   -- stance, so it is re-cast on this cadence (kept under 180
                                   -- to refresh before it drops) AND early if read dispelled.
local SILENCE_ITEM     = "Echo Drops"  -- NOTE: per-healer default; override in Advanced
local SILENCE_ITEM_GAP = 7.5          -- NOTE: medicine recast guard

-- Cap-based spell selection: tier picked by HP% then clamped to the job's max.
local CURE_NAME   = { [1]="Cure", [2]="Cure II", [3]="Cure III", [4]="Cure IV", [5]="Cure V", [6]="Cure VI" }
local CURAGA_NAME = { [1]="Curaga", [2]="Curaga II", [3]="Curaga III", [4]="Curaga IV", [5]="Curaga V" }

-- Per-healer tier selection. cure/curaga config tables map { [tier] = HP% } where
-- 0 disables the tier. pick_tier returns the strongest enabled tier whose threshold
-- still covers HP% p (clamped to the job cap), or 0 if none -- so the table is both
-- selector AND heal gate. low_tier returns the cheapest enabled tier (for waking,
-- where HP% is irrelevant). maxt is the spell line's top tier (6 cure / 5 curaga).
local function pick_tier(thr, p, cap, maxt)
    local hi = (cap < maxt) and cap or maxt
    for tier = hi, 1, -1 do
        local th = thr[tier]
        if th and th > 0 and p <= th then return tier end
    end
    return 0
end

local function low_tier(thr, cap, maxt)
    local hi = (cap < maxt) and cap or maxt
    for tier = 1, hi do
        local th = thr[tier]
        if th and th > 0 then return tier end
    end
    return 0
end


-- Job ids.
local JOB_WHM, JOB_RDM, JOB_PLD, JOB_SCH, JOB_GEO = 3, 5, 7, 20, 21

local REMOVE_ALL = 1 + 2 + 4 + 8 + 16 + 32 + 64 + 128 + 256

-- MAIN job native heal kit (always max level). cure/curaga = max tier (0 = none).
-- na = removable bits; na_arts = those bits require Light Arts + Addendum: White.
-- ds/solace = WHM job abilities. NOTE(BGWiki): RDM has NO native -na/Erase;
-- GEO has NO native healing magic (its cures/-na come from the subjob).
local MAIN_HEAL = {
    [JOB_WHM] = { cure = 6, curaga = 5, na = REMOVE_ALL, na_arts = false, ds = true,  solace = true  },
    [JOB_SCH] = { cure = 4, curaga = 0, na = REMOVE_ALL, na_arts = true,  ds = false, solace = false },
    [JOB_RDM] = { cure = 4, curaga = 0, na = 0,          na_arts = false, ds = false, solace = false },
    [JOB_PLD] = { cure = 4, curaga = 0, na = 0,          na_arts = false, ds = false, solace = false },
    -- GEO and others: no native healing magic.
}

-- SUBJOB access is computed from the *detected* subjob level, so it follows
-- Master Levels (which raise the subjob cap above 49, e.g. ML20 -> sub 59).
-- These are the BGWiki learn levels for the granting job.
local CURE_LV = {                        -- cure tier -> { job = learn level }
    [1] = { [JOB_WHM]=1,  [JOB_RDM]=3,  [JOB_SCH]=5,  [JOB_PLD]=5  },
    [2] = { [JOB_WHM]=11, [JOB_RDM]=14, [JOB_SCH]=17, [JOB_PLD]=17 },
    [3] = { [JOB_WHM]=21, [JOB_RDM]=26, [JOB_SCH]=30, [JOB_PLD]=30 },
    [4] = { [JOB_WHM]=41, [JOB_RDM]=48, [JOB_SCH]=55, [JOB_PLD]=55 },
    [5] = { [JOB_WHM]=61 },
}
-- removable-status bit -> learn level, for the two -na-granting subjobs.
-- /WHM has no Addendum requirement; /SCH grants these only under Addendum: White.
-- bit 256 = Erase (Enhancing): WHM 32, SCH(Addendum) 39.
local NA_LV = {
    [JOB_WHM] = { [1]=6,  [2]=9,  [4]=14, [8]=19, [16]=39, [32]=34, [64]=29, [128]=29, [256]=32 },
    [JOB_SCH] = { [1]=10, [2]=12, [4]=17, [8]=22, [16]=50, [32]=46, [64]=32, [128]=32, [256]=39 },
}

local function sub_cure_cap(sj, lv)
    local cap = 0
    for tier = 1, 6 do
        local req = CURE_LV[tier] and CURE_LV[tier][sj]
        if req and lv >= req then cap = tier end
    end
    return cap
end

local function sub_na_mask(sj, lv)
    local t = NA_LV[sj]
    if not t then return 0 end
    local mask = 0
    for b, req in pairs(t) do if lv >= req then mask = bit_bor(mask, b) end end
    return mask
end

-- Combine main job + (sub job, sub level) into one kit. nil if it can't heal.
-- na_now = removable right now; na_arts = removable once Addendum: White is up.
local function build_profile(mj, sj, sjlvl)
    local m = MAIN_HEAL[mj]
    local s_cure = sub_cure_cap(sj, sjlvl or 0)
    local s_na   = sub_na_mask(sj, sjlvl or 0)
    local s_arts = (sj == JOB_SCH)            -- /SCH -na needs Addendum: White
    if not m and s_cure == 0 and s_na == 0 then return nil end
    local na_now, na_arts = 0, 0
    if m then
        if m.na_arts then na_arts = bit_bor(na_arts, m.na) else na_now = bit_bor(na_now, m.na) end
    end
    if s_na ~= 0 then
        if s_arts then na_arts = bit_bor(na_arts, s_na) else na_now = bit_bor(na_now, s_na) end
    end
    return {
        cure    = math.max(m and m.cure or 0, s_cure),
        curaga  = m and m.curaga or 0,
        ds      = (m and m.ds) or (sj == JOB_WHM and (sjlvl or 0) >= 30) or false,  -- Divine Seal: WHM lv30 (main or /WHM)
        solace  = (m and m.solace) or false,
        majesty = (mj == JOB_PLD),  -- PLD: 180s Cure-potency/AoE stance (timer-refreshed)
        haste   = (mj == JOB_WHM) or (sj == JOB_WHM and (sjlvl or 0) >= 40),  -- WHM Haste (lv40 main or /WHM)
        na_now  = na_now,
        na_arts = na_arts,
        sch     = (mj == JOB_SCH) or (sj == JOB_SCH),  -- needs Light Arts + Addendum
        accession = (mj == JOB_SCH) or (sj == JOB_SCH and (sjlvl or 0) >= 40),  -- SCH Accession (lv40)
    }
end

-- NOTE(status ids): MUST stay identical to rdmhelper's copy.
-- Bits 1..128 are the dedicated -na ailments; bit 256 is the aggregate "an
-- Erase-removable effect is present"
local STATUS_ID_TO_BIT = {
    [3]  = 1,    -- Poison        -> Poisona
    [4]  = 2,    -- Paralysis     -> Paralyna
    [5]  = 4,    -- Blindness     -> Blindna
    [6]  = 8,    -- Silence       -> Silena
    [7]  = 16,   -- Petrification -> Stona
    [8]  = 32,   -- Disease       -> Viruna
    [31] = 32,   -- Plague        -> Viruna
    [9]  = 64,   -- Curse         -> Cursna
    [15] = 128,  -- Doom          -> Cursna
    -- Special-case bits (NOT -na/Erase removable):
    [14] = 512,  -- Charm         -> RDM sleeps them (and we never heal them)
    [17] = 512,  -- Charm (II)    -> "
    [2]  = 1024, -- Sleep         -> wake with Curaga / Accession+Cure / Cure
    [19] = 1024, -- Sleep (II)    -> "
    [193] = 1024, -- Lullaby      -> " (BRD-style sleep; Cure also wakes it)
}
-- Every Erase-removable status id collapses to bit 256.
local ERASE_BIT = 256
local ERASE_IDS = {
    11,  -- Bind      
    12,  -- Weight
    13,  -- Slow
    21,  -- Addle
    128, -- Burn
    129, -- Frost
    130, -- Choke
    131, -- Rasp
    132, -- Shock
    133, -- Drown
    134, -- Dia
    135, -- Bio
    136, -- STR Down
    137, -- DEX Down
    138, -- VIT Down
    139, -- AGI Down
    140, -- INT Down
    141, -- MND Down
    142, -- CHR Down
    144, -- Max HP Down
    145, -- Max MP Down
    146, -- Accuracy Down
    147, -- Attack Down
    148, -- Evasion Down
    149, -- Defense Down
    156, -- Flash
    167, -- Magic Def Down
    174, -- Magic Acc Down
    175, -- Magic Atk Down
    186, -- Helix
    189, -- Max TP Down
    192, -- Requiem
    194, -- Elegy
    298, -- Critical Hit Evasion Down
    404, -- Magic Evasion Down
}
for _, id in ipairs(ERASE_IDS) do STATUS_ID_TO_BIT[id] = ERASE_BIT end

local STATUS_BIT_TO_SPELL = {
    [1]  = "Poisona", [2]  = "Paralyna", [4]   = "Blindna", [8]   = "Silena",
    [16] = "Stona",   [32] = "Viruna",   [64]  = "Cursna",  [128] = "Cursna",
    [256] = "Erase",
}
-- highest -> lowest cast priority
local STATUS_BIT_PRIORITY = {16, 8, 2, 128, 64, 256, 32, 4, 1}
local SILENCE_BIT = 8
local CHARM_BIT   = 512
local SLEEP_BIT   = 1024

-- main's own removable-status bitfield (it is the box running sync).
local function self_status_bits(player)
    local bits = 0
    local b = player:GetBuffs()
    for i = 0, 31 do
        local fb = STATUS_ID_TO_BIT[b[i]]
        if fb then bits = bit_bor(bits, fb) end
    end
    return bits
end

local _PARTY_API = {
    mj  = function(p, i) return p:GetMemberMainJob(i)     end,
    sj  = function(p, i) return p:GetMemberSubJob(i)      end,
    sjl = function(p, i) return p:GetMemberSubJobLevel(i) end,
}

-- Resolve a healer's (main job, sub job, sub level). main box reads itself;
-- others come from rdmhelper reports, with a guarded party-API fast path.
local function healer_jobs(healer, party, player)
    if healer == cached_main then
        return player:GetMainJob() or 0, player:GetSubJob() or 0, player:GetSubJobLevel() or 0
    end
    local mj, sj, sl = healer.job or 0, healer.sjob or 0, healer.sjlvl or 0
    if mj == 0 and healer.pt_data and healer.pt_data.index < 6 then
        local idx = healer.pt_data.index
        local ok, m = pcall(_PARTY_API.mj, party, idx)
        if ok and m and m > 0 then
            mj = m
            local ok2, s = pcall(_PARTY_API.sj, party, idx)
            if ok2 and s then sj = s end
            local ok3, l = pcall(_PARTY_API.sjl, party, idx)
            if ok3 and l and l > 0 then sl = l end
        end
    end
    return mj, sj, sl
end

-- One action per tick from one healer. `cfg` is this healer's persisted config
-- (per-tier cure/curaga HP% tables + na/solace/arts toggles); `do_status` enables
-- -na; `do_wake` enables waking sleepers. Divine Seal is gated inside on the WHM job. The
-- configured tiers are clamped to the healer's live job cap.
-- Reraise source for a healer's live jobs. WHM (main OR /WHM sub) casts Reraise
-- natively; SCH (main OR sub) casts it only under Addendum: White; Returns can-cast, needs-AddW.
local function reraise_caps(mj, sj)
    if mj == JOB_WHM or sj == JOB_WHM then return true, false end
    if mj == JOB_SCH or sj == JOB_SCH then return true, true  end
    return false, false
end
local RERAISE_MAX_TRIES = 2   -- NOTE: give up after this many casts that never land
                              -- (e.g. a wrong spell name) so a stuck Reraise can't
                              -- permanently block this healer's cures. Reset when the
                              -- buff is seen up or the job changes.
local function cure_candidate(t, healer, party, cfg, prof, now)
    if not (t.heal and t.heal[1] and t.in_zone and t.pt_data) then return nil end
    if bit_band(t.status or 0, CHARM_BIT) ~= 0 then return nil end
    if heal_claimed_by_other(healer, t.name, now) then return nil end
    local pct = party:GetMemberHPPercent(t.pt_data.index) or 0
    if pct <= 0 or pick_tier(cfg.cure, pct, prof.cure, 6) == 0 then return nil end
    local locks = healer.buff_locks[t.name]
    if now - ((locks and locks['cure']) or 0) < CURE_RETRY_GAP then return nil end
    return pct
end

-- casts the highest-priority -na on one same-party member and returns true 
-- so the caller stops the scan, else false 
local function na_consider(t, healer, hgroup, na_mask, now)
    if not (t.heal and t.heal[1] and t.in_zone and t.pt_data) then return false end
    if bit_band(t.status or 0, CHARM_BIT) ~= 0 then return false end
    -- -na is same-party only. A detached healer (e.g. RDM in the alliance party)
    -- can't reliably -na a member in another party -- out of range -> 'Unable to
    -- see' command errors. The co-partied healer handles them.
    if t.pt_data.group ~= hgroup then return false end
    local st = bit_band(t.status or 0, na_mask)
    if st == 0 then return false end
    for _, b in ipairs(STATUS_BIT_PRIORITY) do
        if bit_band(st, b) ~= 0 then
            local locks = healer.buff_locks[t.name]
            local key   = 'na' .. b
            if now - ((locks and locks[key]) or 0) >= NA_RETRY_GAP
               and not na_claimed_by_other(healer, t.name, b, now) then
                if not locks then locks = {}; healer.buff_locks[t.name] = locks end
                locks[key] = now
                claim_na(healer, t.name, b, now)
                local spell = STATUS_BIT_TO_SPELL[b]
                local tstr  = (t.name_lower == healer.name_lower) and "<me>" or t.name
                do_action(healer, '/ma "' .. spell .. '" ' .. tstr, get_cast_delay(spell), now)
                return true
            end
        end
    end
    return false
end

local function heal_pass(healer, cfg, party, player, now, do_status, do_wake)
    if now < (healer.cast_reserved_until or 0) then return false end
    local mj, sj, sjlvl = healer_jobs(healer, party, player)
    -- OPT: memoize the per-job kit on the healer. build_profile is a pure function
    -- of (mj, sj, sjlvl) and the returned table is read-only, so recompute ONLY when
    -- the live job/sub/level actually changes -- drops a fresh 10-field table (plus
    -- the sub_na_mask/sub_cure_cap walks) every tick, per active healer.
    sjlvl = sjlvl or 0
    local prof
    if healer._prof_mj == mj and healer._prof_sj == sj and healer._prof_sl == sjlvl then
        prof = healer._prof
    else
        prof = build_profile(mj, sj, sjlvl)
        healer._prof_mj, healer._prof_sj, healer._prof_sl, healer._prof = mj, sj, sjlvl, prof
    end
    if not prof then return false end   -- assigned healer isn't on a healing job

    -- Re-allow stance setup when the job changes (incl. first detection).
    if healer._kit_mj ~= mj or healer._kit_sj ~= sj then
        healer._kit_mj, healer._kit_sj = mj, sj
        healer.solace_lock = 0; healer.solace_seen = 0
        healer.larts_lock  = 0; healer.larts_seen  = 0
        healer.addw_lock   = 0; healer.addw_seen   = 0
        healer.majesty_lock = 0; healer.majesty_seen = 0; healer.majesty_cast = 0
        healer.reraise_lock = 0; healer.reraise_seen = 0; healer.reraise_fails = 0
    end

    -- 0. SELF-SILENCE -- magic is locked out; clear it with an item 
    if bit_band(healer.status or 0, SILENCE_BIT) ~= 0 then
        if cfg.silence and now >= (healer.silence_item_lock or 0) then
            healer.silence_item_lock = now + (cfg.silencegap or SILENCE_ITEM_GAP)
            do_action(healer, '/item "' .. (cfg.silenceitem or SILENCE_ITEM) .. '" <me>', 2.0, now)
        end
        return true
    end

    -- 1. STANCES -- /SCH grants white magic via Light Arts -> Addendum: White
    -- (order matters); WHM adds Afflatus Solace. A stance fires ONLY when (a) its
    -- toggle is on, (b) the buff is genuinely ABSENT, and (c) the buff is READABLE
    -- for this healer -- in-party (memory) or a fresh cross-party report. Without
    -- (c) we'd re-fire a stance that is already up but unseen
    -- rdmhelper now reports Light Arts/Addendum/Solace so cross-party is readable.
    local hb = healer.buffs or blank_buffs()
    local stance_readable = (healer.pt_data.index < 6)
        or (now - (healer.last_rep_time or 0) < STANCE_READABLE_GAP)
    -- Reraise capability/needs for this healer; want_arts folds Reraise's Addendum
    -- requirement into the existing arts maintenance, so checking Reraise on a
    -- /SCH healer establishes Light Arts -> Addendum White even if the -na 'arts'
    -- toggle is off.
    local rr_can, rr_arts = reraise_caps(mj, sj)
    local want_reraise = cfg.reraise and rr_can
    local want_arts = (cfg.arts or (want_reraise and rr_arts)) and prof.sch
    if stance_readable then
        if hb.larts  then healer.larts_seen  = now end
        if hb.addw   then healer.addw_seen   = now end
        if hb.solace then healer.solace_seen = now end

        if want_arts and not hb.larts
           and (now - (healer.larts_seen or 0)) >= STANCE_LOSS_DEBOUNCE
           and now > (healer.larts_lock or 0) then
            healer.larts_lock = now + PERMA_STANCE_GUARD
            do_action(healer, '/ja "Light Arts" <me>', 1.5, now)
            return true
        end
        if want_arts and hb.larts and not hb.addw
           and (now - (healer.addw_seen or 0)) >= STANCE_LOSS_DEBOUNCE
           and now > (healer.addw_lock or 0) then
            healer.addw_lock = now + PERMA_STANCE_GUARD
            do_action(healer, '/ja "Addendum: White" <me>', 1.5, now)
            return true
        end
        if prof.solace and cfg.solace and not hb.solace
           and (now - (healer.solace_seen or 0)) >= STANCE_LOSS_DEBOUNCE
           and now > (healer.solace_lock or 0) then
            healer.solace_lock = now + PERMA_STANCE_GUARD
            do_action(healer, '/ja "Afflatus Solace" <me>', 1.5, now)
            return true
        end

        -- PLD Majesty -- a 180s buff (Cure potency + AoE), NOT a persistent stance,
        -- so it is refreshed on a timer (MAJESTY_REFRESH) rather than only on loss.
        -- It is ALSO re-cast early if read dispelled, with the same absent-debounce
        -- + readability gate so an already-active Majesty is never wastefully re-cast.
        if prof.majesty and cfg.majesty then
            if hb.majesty then healer.majesty_seen = now end
            local dispelled = (not hb.majesty)
                and (now - (healer.majesty_seen or 0)) >= STANCE_LOSS_DEBOUNCE
            local stale = (now - (healer.majesty_cast or 0)) >= MAJESTY_REFRESH
            if (dispelled or stale) and now > (healer.majesty_lock or 0) then
                healer.majesty_lock = now + STANCE_GUARD
                healer.majesty_cast = now
                do_action(healer, '/ja "Majesty" <me>', 1.5, now)
                return true
            end
        end

        -- RERAISE -- self-preservation, kept up when this healer's Reraise toggle is
        -- on. Cast right after stances. /SCH-sourced Reraise waits until Addendum:
        -- White is actually up (want_arts establishes it). One status (id 113) covers
        -- every tier, so any Reraise up suppresses it; seen-debounce + readability
        -- avoid re-casting one already up but momentarily unread cross-party; the
        -- RERAISE_MAX_TRIES cap stops a never-landing cast from blocking cures.
        if want_reraise and (not rr_arts or hb.addw) then
            if hb.reraise then healer.reraise_seen = now; healer.reraise_fails = 0 end
            if not hb.reraise
               and (healer.reraise_fails or 0) < RERAISE_MAX_TRIES
               and (now - (healer.reraise_seen or 0)) >= STANCE_LOSS_DEBOUNCE
               and now > (healer.reraise_lock or 0) then
                local rr = cfg.reraisespell or "Reraise"
                healer.reraise_lock  = now + STANCE_GUARD
                healer.reraise_fails = (healer.reraise_fails or 0) + 1
                do_action(healer, '/ma "' .. rr .. '" <me>', get_cast_delay(rr), now)
                return true
            end
        end
    end

    local idx      = healer.pt_data.index
    local hgroup   = healer.pt_data.group
    local mp       = party:GetMemberMP(idx) or 0
    local mp_known = (idx < 6)   -- MP is only readable for our own party

    -- 2. WAKE SLEEPERS -- Cure/Curaga removes Sleep. Wake any heal-flagged member
    -- that is asleep but NOT charmed (charmed sleepers are kept asleep on purpose).
    -- Prefer AoE: Curaga (WHM, own party) > Accession+Cure (SCH) > single Cure.
    if do_wake and ((not mp_known) or mp >= WAKE_MIN_MP) then
        local sleeper = nil
        for _, t in ipairs(chars) do
            if t.heal and t.heal[1] and t.in_zone and t.pt_data then
                local st = t.status or 0
                if bit_band(st, SLEEP_BIT) ~= 0 and bit_band(st, CHARM_BIT) == 0
                   and not heal_claimed_by_other(healer, t.name, now)
                   and now - ((healer.buff_locks[t.name] and healer.buff_locks[t.name]['wake']) or 0) >= CURE_RETRY_GAP then
                    sleeper = t; break
                end
            end
        end
        if not sleeper then for _, t in ipairs(guests) do
            if t.heal and t.heal[1] and t.in_zone and t.pt_data then
                local st = t.status or 0
                if bit_band(st, SLEEP_BIT) ~= 0 and bit_band(st, CHARM_BIT) == 0
                   and not heal_claimed_by_other(healer, t.name, now)
                   and now - ((healer.buff_locks[t.name] and healer.buff_locks[t.name]['wake']) or 0) >= CURE_RETRY_GAP then
                    sleeper = t; break
                end
            end
        end end
        if sleeper then
            -- (sleep cure): wake must NEVER be gated by the per-tier cfg HP-threshold
            -- table -- a sleeping member is a hard requirement to clear regardless of HP%
            -- or how the user has tiered their cures. Use the cheapest castable tier the
            -- job's profile supports (tier 1 if the job has Cure/Curaga at all). Same-party
            -- gating on Curaga is preserved (Curaga only heals the caster's own party).
            local wcg = (prof.curaga >= 1) and 1 or 0
            local wcu = (prof.cure   >= 1) and 1 or 0
            local same_pty = (sleeper.pt_data.group == hgroup)
            if (wcg > 0 and same_pty) or wcu > 0 then
                local tstr = (sleeper.name_lower == healer.name_lower) and "<me>" or sleeper.name
                -- FIX: Accession+Cure waking is gated behind the Cure (C) flag ALONE,
                -- never behind the -na / status-removal 'arts' toggle. Accession is a
                -- Light Arts stratagem, so a SCH with status-removal OFF has no Light
                -- Arts and the AoE wake used to silently fail. Establish Light Arts
                -- here, straight from the wake path (independent of want_arts), then
                -- Accession+Cure on the next tick. If Light Arts can't be readied this
                -- tick (not readable / debounce / guard), fall back to single Cure,
                -- which wakes without arts. The wake claim/lock is taken ONLY when a
                -- wake actually casts, so the Light-Arts setup tick never burns the
                -- per-target retry gap.
                local want_accession = prof.accession and same_pty and wcg == 0
                if want_accession and not hb.larts then
                    if stance_readable
                       and (now - (healer.larts_seen or 0)) >= STANCE_LOSS_DEBOUNCE
                       and now > (healer.larts_lock or 0) then
                        healer.larts_lock = now + PERMA_STANCE_GUARD
                        do_action(healer, '/ja "Light Arts" <me>', 1.5, now)
                        return true
                    end
                    want_accession = false   -- Light Arts not ready -> single Cure wake
                end
                local locks = healer.buff_locks[sleeper.name]
                if not locks then locks = {}; healer.buff_locks[sleeper.name] = locks end
                locks['wake'] = now
                claim_heal(healer, sleeper.name, now)
                if wcg > 0 and same_pty then
                    local spell = CURAGA_NAME[wcg]
                    do_action(healer, '/ma "' .. spell .. '" ' .. tstr, get_cast_delay(spell), now)
                elseif want_accession then
                    local cure = CURE_NAME[wcu]
                    local cd   = get_cast_delay(cure)
                    do_action(healer, '/ja "Accession" <me>', 0.5, now)
                    healer.cast_reserved_until = now + 0.5 + cd + 0.5
                    queue_cast(healer, '/ma "' .. cure .. '" ' .. tstr, now + 0.5, cd)
                else
                    local cure = CURE_NAME[wcu]   -- single Cure still wakes the target
                    do_action(healer, '/ma "' .. cure .. '" ' .. tstr, get_cast_delay(cure), now)
                end
                return true
            end
        end
    end

    -- 3. Scan injured recipients (respecting this healer's per-target cure gap).
    --    worst* = lowest HP anywhere (single cure / DS); g* = healer's own party
    --    cluster (Curaga only helps the caster's party). Charmed members are
    --    skipped entirely -- curing them would wake them back into attacking us.
    local worst, worst_pct = nil, 101
    local gworst, gworst_pct, gcount = nil, 101, 0
    if prof.cure > 0 and ((not mp_known) or mp >= CURE_MIN_MP) then
        for _, t in ipairs(chars) do
            local pct = cure_candidate(t, healer, party, cfg, prof, now)
            if pct then
                if pct < worst_pct then worst, worst_pct = t, pct end
                if t.pt_data.group == hgroup then 
                    gcount = gcount + 1
                    if pct < gworst_pct then gworst, gworst_pct = t, pct end
                end
            end
        end
        for _, t in ipairs(guests) do
            local pct = cure_candidate(t, healer, party, cfg, prof, now)
            if pct then
                if pct < worst_pct then worst, worst_pct = t, pct end
                if t.pt_data.group == hgroup then
                    gcount = gcount + 1
                    if pct < gworst_pct then gworst, gworst_pct = t, pct end
                end
            end
        end
    end

    if worst then
        -- 3. DIVINE SEAL -- any WHM healer (main job WHM or /WHM>=30), at/under the
        --    per-healer HP% gate, off cooldown. FIX: pop DS then QUEUE the boosted heal to fire the instant
        --    the 1.5s JA lock clears, with the target claimed/locked now, so the
        --    doubled potency actually lands (was firing DS then returning, letting
        --    the next tick re-decide and sometimes drop the burst). Prefer party
        --    Curaga when 2+ are hurt in the healer's own party, else single Cure.
        if prof.ds and cfg.ds and worst_pct <= (cfg.dsthresh or EMERGENCY_PCT)
           and now > (healer.ds_lock or 0) then
            local btarget, bspell
            local cgt = gworst and pick_tier(cfg.curaga, gworst_pct, prof.curaga, 5) or 0
            if cgt > 0 and gcount >= (cfg.curagamin or CURAGA_MIN_TARGETS) then
                btarget, bspell = gworst, CURAGA_NAME[cgt]
            else
                btarget, bspell = worst, CURE_NAME[pick_tier(cfg.cure, worst_pct, prof.cure, 6)]
            end
            local cd = get_cast_delay(bspell)
            local locks = healer.buff_locks[btarget.name]
            if not locks then locks = {}; healer.buff_locks[btarget.name] = locks end
            locks['cure'] = now
            claim_heal(healer, btarget.name, now, 1.5 + cd + HEAL_LAND_MARGIN)  -- 1.5 DS JA + cure cast + land
            healer.ds_lock = now + DIVINE_SEAL_RECAST
            local tstr = (btarget.name_lower == healer.name_lower) and "<me>" or btarget.name
            do_action(healer, '/ja "Divine Seal" <me>', 1.5, now)
            healer.cast_reserved_until = now + 1.5 + cd + 0.5
            queue_cast(healer, '/ma "' .. bspell .. '" ' .. tstr, now + 1.5, cd)
            return true
        end

        -- 4. CURAGA -- AoE, 2+ injured in the healer's own party (enabled tier only).
        local cgt = gworst and pick_tier(cfg.curaga, gworst_pct, prof.curaga, 5) or 0
        if cgt > 0 and gcount >= (cfg.curagamin or CURAGA_MIN_TARGETS) then
            local spell = CURAGA_NAME[cgt]
            local locks = healer.buff_locks[gworst.name]
            if not locks then locks = {}; healer.buff_locks[gworst.name] = locks end
            locks['cure'] = now
            claim_heal(healer, gworst.name, now, get_cast_delay(spell) + HEAL_LAND_MARGIN)
            local tstr = (gworst.name_lower == healer.name_lower) and "<me>" or gworst.name
            do_action(healer, '/ma "' .. spell .. '" ' .. tstr, get_cast_delay(spell), now)
            return true
        end

        -- 5. CURE -- single target, lowest HP anywhere (cross-party capable).
        local spell = CURE_NAME[pick_tier(cfg.cure, worst_pct, prof.cure, 6)]
        local locks = healer.buff_locks[worst.name]
        if not locks then locks = {}; healer.buff_locks[worst.name] = locks end
        locks['cure'] = now
        claim_heal(healer, worst.name, now, get_cast_delay(spell) + HEAL_LAND_MARGIN)
        local tstr = (worst.name_lower == healer.name_lower) and "<me>" or worst.name
        do_action(healer, '/ma "' .. spell .. '" ' .. tstr, get_cast_delay(spell), now)
        return true
    end

    -- 6. STATUS REMOVAL -- only statuses this job can actually cure. na_now is
    -- available immediately; na_arts adds once Addendum: White is up (SCH).
    local na_mask = prof.na_now
    if healer.buffs and healer.buffs.addw then na_mask = bit_bor(na_mask, prof.na_arts) end
    if do_status and na_mask ~= 0 and ((not mp_known) or mp >= NA_MIN_MP) then
        for _, t in ipairs(chars)  do if na_consider(t, healer, hgroup, na_mask, now) then return true end end
        for _, t in ipairs(guests) do if na_consider(t, healer, hgroup, na_mask, now) then return true end end
    end

    return false
end

-- Resolve a healer char by name (must be in zone with valid party data).
local function resolve_healer(name)
    if not name or name == '' or name == 'off' or name == 'none' then return nil end
    for _, c in ipairs(chars) do
        if c.name_lower == name then
            return (c.in_zone and c.pt_data) and c or nil
        end
    end
    return nil
end
local function reset_list_combat(list)
    for _, e in ipairs(list) do
        for _, key in ipairs(COMBAT_FLAG_KEYS) do if e[key] then e[key][1] = false end end
        e.last_engage_target = 0
        e.last_engage_time   = 0
        e.auto_engaged       = false
        e.retry              = nil
        e.debuff_pause       = false
        e.solace_lock        = 0
        e.larts_lock         = 0
        e.addw_lock          = 0
        -- Hunt/movement state: must be cleared on zone so entity indices from the
        -- previous zone don't suppress pulls or keep stale run_active blocking follow.
        -- (hunt_pulled in particular: if a mob in the new zone lands on the same
        -- entity index as the old target, the pull would be silently skipped forever.)
        e.hunt_engaged  = false
        e.hunt_assigned = 0
        e.hunt_pulled   = nil
        e.hunt_prev_mob = nil
        e.run_active    = false
        e.run_idx       = nil
    end
end

local function reset_combat_flags()
    reset_list_combat(chars)
    reset_list_combat(guests)
end

local function update_membership_and_zones(party)
    local my_zone = party:GetMemberZone(0)
    for _, v in pairs(current_active) do v.active_this_scan = false end
    for i = 0, 17 do
        local name = party:GetMemberName(i)
        if name and name ~= "" then
            local zId = party:GetMemberZone(i)
            local sId = party:GetMemberServerId(i)
            if sId ~= 0 and sId < 0x01000000 and party:GetMemberIsActive(i) ~= 0 and zId == my_zone then
                local nl = name:lower()
                local e = current_active[nl]
                if e then
                    e.index            = i
                    e.group            = math_floor(i / 6)
                    e.sId              = sId
                    e.active_this_scan = true
                else
                    current_active[nl] = {
                        index            = i,
                        group            = math_floor(i / 6),
                        sId              = sId,
                        active_this_scan = true,
                    }
                end
            end
        end
    end
    for k, v in pairs(current_active) do if not v.active_this_scan then current_active[k] = nil end end
    for _, c in ipairs(chars) do
        if not current_active[c.name_lower] then
            c.buffs = blank_buffs()
            c.status = 0
            c.in_zone = false
        end
    end
    for _, c in ipairs(chars) do c.pt_data = current_active[c.name_lower]; c.in_zone = (c.pt_data ~= nil) end
    for i = #guests, 1, -1 do
        guests[i].pt_data = current_active[guests[i].name_lower]
        if not guests[i].pt_data then t_remove(guests, i) else guests[i].in_zone = true end
    end
    for nl, data in pairs(current_active) do
        local known = known_cores[nl]
        if not known then for _, g in ipairs(guests) do if g.name_lower == nl then known = true; break end end end
        if not known then
            local g = { name = party:GetMemberName(data.index), buf = {false}, is_guest = true }
            init_char_state(g); g.in_zone, g.pt_data = true, data
            g.ref[1]  = false
            g.bpro[1] = false
            g.bsh[1]  = false
            g.bp[1]   = false
            t_insert(guests, g)
        end
    end
end

-- A crew box's rdmhelper self-reports its own buffs from GetBuffs (100% accurate);
-- guests are relayed by an elected co-zoned crew member. or_rep_buffs ORs that wire
-- snapshot OVER whatever the party-status-icon memory scan found, so a stance the
-- icon array hasn't surfaced yet -- or a cross-party member we can't read at all --
-- still reads PRESENT and never triggers a redundant recast. Memory is the fallback
-- for the main box (self) and for members whose helper isn't reporting.
-- (REPORT_BUFF_TTL is declared near BUFF_RETRY_GAP so check_needs can also use it
-- as the readability window for the blind-guest retry-gap path.)
local function or_rep_buffs(c, now)
    local rb = c.rep_buffs
    if not rb or (now - (c.last_rep_time or 0)) >= REPORT_BUFF_TTL then return end
    local cb = c.buffs
    if rb.h       then cb.h = true end
    if rb.r       then cb.r = true end
    if rb.p       then cb.p = true end
    if rb.fl      then cb.fl = true end
    if rb.comp    then cb.comp = true end
    if rb.pro     then cb.pro = true end
    if rb.sh      then cb.sh = true end
    if rb.larts   then cb.larts = true end
    if rb.addw    then cb.addw = true end
    if rb.solace  then cb.solace = true end
    if rb.majesty then cb.majesty = true end
    if rb.reraise then cb.reraise = true end
end

local function scan_buff_list(t, slot_addr, myNameL, player, now)
    for _, c in ipairs(t) do
        if not c.pt_data then goto continue end

        local cb = c.buffs
        cb.h=false; cb.r=false; cb.p=false; cb.fl=false; cb.comp=false
        cb.pro=false; cb.sh=false; cb.samba=false
        cb.larts=false; cb.addw=false; cb.solace=false; cb.majesty=false; cb.reraise=false

        -- Our own party (index<6): read status (and the main's own buffs) straight from
        -- memory -- the authoritative, low-latency status source for -na. Members of
        -- OTHER alliance parties aren't in our status-icon table, so their buffs/status
        -- arrive only via reports (handled by or_rep_buffs / the status TTL pass).
        if c.in_zone and c.pt_data.index < 6 then
            local st = 0
            if c.name_lower == myNameL then
                local b = player:GetBuffs()
                for i = 0, 31 do
                    local id = b[i]
                    local k = BUFF_ID_TO_KEY[id]; if k then cb[k] = true end
                    local sb = STATUS_ID_TO_BIT[id]; if sb then st = bit_bor(st, sb) end
                end
            else
                local m = slot_addr[c.pt_data.sId]
                if m then
                    local hi
                    for j = 0, 31 do
                        local low = mem_read_u8(m + 16 + j)
                        if low == 255 then break end
                        local bp = j % 4
                        if bp == 0 then hi = mem_read_u8(m + 8 + math_floor(j / 4)) end
                        local id = bit_lshift(bit_band(bit_rshift(hi, bp * 2), 0x03), 8) + low
                        local k = BUFF_ID_TO_KEY[id]; if k then cb[k] = true end
                        local sb = STATUS_ID_TO_BIT[id]; if sb then st = bit_bor(st, sb) end
                    end
                end
            end
            c.status = st
            c.last_status_time = now
        end
        or_rep_buffs(c, now)
        ::continue::
    end
end

local function scan_buffs(party, player, now)
    local ptr = pointer_mgr:Get('party.statusicons')
    if ptr == 0 then return end
    local buff_ptr = mem_read_u32(ptr)
    if buff_ptr == 0 then return end
    local myNameL = (party:GetMemberName(0) or ''):lower()

    t_clear(slot_addr)
    for slot = 0, 5 do
        local m = buff_ptr + (0x30 * slot)
        slot_addr[mem_read_u32(m)] = m
    end

    scan_buff_list(chars,  slot_addr, myNameL, player, now)
    scan_buff_list(guests, slot_addr, myNameL, player, now)

    -- Status source: main reads its own removable statuses locally (it is the box
    -- running sync); everyone else's arrive via rdmhelper reports (cross-party).
    -- Expire stale reports so a cleared/zoned status stops driving -na.
    if cached_main then
        cached_main.status = self_status_bits(player)
        cached_main.job    = player:GetMainJob() or 0
        cached_main.sjob   = player:GetSubJob() or 0
        cached_main.sjlvl  = player:GetSubJobLevel() or 0
    end
    for _, c in ipairs(chars)  do
        if c ~= cached_main and now - (c.last_status_time or 0) > 15.0 then c.status = 0 end
    end
    for _, g in ipairs(guests) do
        if now - (g.last_status_time or 0) > 15.0 then g.status = 0 end
    end
end

------------------------------------------------------------
-- CORE LOGIC
------------------------------------------------------------
local function sleep_bookkeep(rdm, t, now)
    local st = t.status or 0
    local lk = rdm.buff_locks[t.name]
    if bit_band(st, CHARM_BIT) == 0 then
        if lk then lk.sleep2_n = 0; lk.sleep2_stuck = nil end
    elseif bit_band(st, SLEEP_BIT) ~= 0 then
        if not lk then lk = {}; rdm.buff_locks[t.name] = lk end
        lk.sleep2_stuck = lk.sleep2_stuck or now
        if now - lk.sleep2_stuck >= CHARM_SLEEP_STUCK then lk.sleep2_n = 0 end
    else
        if not lk then lk = {}; rdm.buff_locks[t.name] = lk end
        lk.sleep2_stuck = nil
    end
end

local TICK_ACTION = 0.1
local TICK_SCAN   = 0.5
local lastTick, lastScanTick = 0, 0
local is_zoning_prev = false
local rdm_buff_idle_until = 0

------------------------------------------------------------
-- COMBAT / HUNT ENGINE
------------------------------------------------------------
-- All hunt helpers hang off hunt_mod (table fields, not locals) so they add
-- ZERO to the main chunk's 200-local budget. Call as hunt_mod.run(...) etc.

-- per-box mob whitelist (created lazily). Empty list => hunt ANY valid mob.
function hunt_mod.list(c)
    local L = config.combat.lists[c.name_lower]
    if not L then L = T{}; config.combat.lists[c.name_lower] = L end
    return L
end

function hunt_mod.pull_cmd(c)
    return config.combat.pull[c.name_lower] or ''
end

-- Fire a one-shot pull action at the assigned mob to draw it into range. Main
-- targets locally then runs the command; alts route through rdmhelper's 'exec'
-- (SetTarget idx + run command). The command should use <t> (e.g. /ma "Dia III"
-- <t>, /ra <t>, /ja "Sic" <t>).
function hunt_mod.do_pull(c, idx, cmd)
    if c.is_main then
        local tm = mm:GetTarget()
        if tm then pcall(hunt_mod.set_target_safe, tm, idx) end
        chat:QueueCommand(1, cmd)
    else
        qcmd(c.mst_prefix .. '/rdmhelper exec ' .. idx .. ' ' .. cmd)
    end
end

-- RUN-TO-MOB / CAMPSITE (experimental movement). Uses the AutoFollow run state
-- (Bambooya's primitive): set the follow delta to the unit direction and turn on
-- auto-running; the client runs (and turns) that way. Alts move via rdmhelper;
-- the main moves here. Stops within ~2y, with a hard timeout. Movement suppresses
-- follow for that box (see want_follow gate) so the two don't fight.
function hunt_mod.runto(c, idx)
    if c.is_main then return end
    local fr = hunt_mod.fight_range(c)
    qcmd(c.mst_prefix .. '/rdmhelper runto ' .. idx .. ' ' .. string.format('%.4f', fr * fr))
    c.run_active = true
end

function hunt_mod.stoprun(c)
    if c.is_main then return end
    qcmd(c.mst_prefix .. '/rdmhelper stoprun')
    c.run_active = false
end

-- Send an alt back to the saved campsite (point-move; the helper auto-stops on
-- arrival). Used by the per-box return modes.
function hunt_mod.goto_camp(c)
    if c.is_main or not config.combat.camp_set then return end
    qcmd(c.mst_prefix .. '/rdmhelper goto ' ..
         string.format('%.2f %.2f', config.combat.camp_x or 0, config.combat.camp_y or 0))
    c.run_active = true
end

function hunt_mod.camp_set()
    local me = GetPlayerEntity()
    if not me then print('[sync] camp: no player entity'); return end
    local p = me.Movement.LocalPosition
    config.combat.camp_x, config.combat.camp_y = p.X, p.Y
    config.combat.camp_set = true
    settings.save()
    print(string.format('[sync] campsite set: %.1f, %.1f', p.X, p.Y))
end

function hunt_mod.camp_go()
    if not config.combat.camp_set then print('[sync] camp not set (use /sync camp set)'); return end
    local cx, cy = config.combat.camp_x, config.combat.camp_y
    for _, c in ipairs(chars) do
        if c.in_zone then
            if c.is_main then
                local g = hunt_mod.main_goto
                g.x, g.y, g.active, g.deadline = cx, cy, true, os_clock() + 30.0
            else
                qcmd(c.mst_prefix .. '/rdmhelper goto ' .. string.format('%.2f %.2f', cx, cy))
            end
        end
    end
    print('[sync] returning crew to campsite')
end

-- Main campsite move tick (called each logic loop). Runs the main toward the
-- saved point until within ~2y or the deadline.
function hunt_mod.main_move_tick(now)
    local g = hunt_mod.main_goto
    if not g.active then return end
    local af = mm:GetAutoFollow()
    if now > g.deadline then g.active = false; if af then af:SetIsAutoRunning(0) end; return end
    local me = GetPlayerEntity()
    if not me or not af then return end
    local sp = me.Movement.LocalPosition
    local dx, dy = g.x - sp.X, g.y - sp.Y
    local d2 = dx*dx + dy*dy
    if d2 <= 4.0 then af:SetIsAutoRunning(0); g.active = false; return end
    local d = math.sqrt(d2)
    af:SetFollowDeltaX(dx / d); af:SetFollowDeltaY(dy / d); af:SetFollowDeltaZ(0)
    af:SetIsAutoRunning(1)
end

function hunt_mod.in_list(L, nm)
    if not L or #L == 0 then return true end  -- empty list = any mob
    local n = hunt_mod.norm(nm)
    for i = 1, #L do if hunt_mod.norm(L[i]) == n then return true end end
    return false
end

-- A live, attackable, in-radius mob whose claim is free or held by crew.
-- Returns the entity name (for whitelist matching) or nil.
-- Global blacklist: a mob name here is NEVER hunted by any box.
-- Normalize a mob name for matching: lowercase, curly-apostrophe -> ', trim.
-- FFXI names and typed entries can differ on apostrophe glyph / spacing, which
-- silently broke exact matches (e.g. Demon's Elemental).
function hunt_mod.norm(str)
    str = (str or ''):lower()
    str = str:gsub('\226\128\152', "'"):gsub('\226\128\153', "'")
    str = str:gsub('^%s+', ''):gsub('%s+$', '')
    return str
end

function hunt_mod.blacklisted(nm)
    local B = config.combat.blacklist
    if not B or #B == 0 then return false end
    local n = hunt_mod.norm(nm)
    for i = 1, #B do
        local e = hunt_mod.norm(B[i])
        if e ~= '' and n:find(e, 1, true) then return true end  -- substring, plain
    end
    return false
end

-- A live, attackable mob whose claim is free or held by crew, not blacklisted.
-- Distance is NOT checked here -- it's gated per-hunter in the assignment, since
-- ent:GetDistance is anchored on the MAIN and alts can be far from it.
function hunt_mod.valid(ent, idx)
    if idx == 0 then return nil end
    local spawn = ent:GetSpawnFlags(idx) or 0
    if bit_band(spawn, 0x10) == 0 then return nil end      -- not a mob
    if bit_band(spawn, 0x01) ~= 0 then return nil end      -- a PC (player/trust)
    if (ent:GetHPPercent(idx) or 0) <= 0 then return nil end
    local claim = bit_band(ent:GetClaimStatus(idx) or 0, 0xFFFF)
    if claim ~= 0 and not hunt_mod.crew_mask[claim] then return nil end
    local nm = ent:GetName(idx)
    if not nm or nm == '' or nm == 'Unknown' then return nil end
    if hunt_mod.blacklisted(nm) then return nil end
    return nm
end

-- Ground-plane (X/Y) position of a hunting box. Main via GetPlayerEntity();
-- alts resolved by name into the entity array (cached on c.hunt_eidx, throttled
-- re-resolve). Returns hx, hy or nil if unresolved.
function hunt_mod.box_pos(ent, c, now)
    if c.is_main then
        local me = GetPlayerEntity()
        if not me then return nil end
        local p = me.Movement.LocalPosition
        return p.X, p.Y
    end
    local ei = c.hunt_eidx or 0
    if ei == 0 or (ent:GetName(ei) or ''):lower() ~= c.name_lower then
        if now - (c.hunt_eidx_t or 0) >= 1.0 then
            c.hunt_eidx_t = now
            ei = 0
            for k = 0, 0x8FF do
                local n = ent:GetName(k)
                if n and n:lower() == c.name_lower then ei = k; break end
            end
            c.hunt_eidx = ei
        else
            ei = c.hunt_eidx or 0
        end
        if ei == 0 then return nil end
    end
    return ent:GetLocalPositionX(ei) or 0, ent:GetLocalPositionY(ei) or 0
end

-- Tell a box to attack a specific entity index. The main acts locally; other
-- boxes route through rdmhelper (SetTarget + /attack on).
function hunt_mod.attack(c, idx)
    if c.is_main then
        local tm = mm:GetTarget()
        if tm then pcall(hunt_mod.set_target_safe, tm, idx) end
        chat:QueueCommand(1, '/attack on')
    else
        qcmd(c.mst_prefix .. '/rdmhelper hunt ' .. idx)
    end
end

function hunt_mod.disengage(c)
    if c.is_main then chat:QueueCommand(1, '/attack off')
    else qcmd(c.mst_prefix .. '/attack off') end
end

hunt_mod.RESEND  = 4.0   -- re-issue an unchanged assignment at most this often
hunt_mod.CMD_GAP = 0.5   -- min spacing between hunt commands to one box
hunt_mod.ENGAGE_DIST2 = 100.0   -- 10y, squared -- box must close to this before /attack on fires

-- Per-character pull distance / fight (leash) range. Both default if the box
-- hasn't been dialed in yet via the Combat panel.
function hunt_mod.pull_dist(c)
    return config.combat.pull_dist[c.name_lower] or 20.0
end
function hunt_mod.fight_range(c)
    return config.combat.fight_range[c.name_lower] or 3.5
end

-- Full hunt pass: rebuild candidate pool (gated), then sticky -> distinct ->
-- highest-HP shared assignment over all hunting boxes.
function hunt_mod.run(party, ent, player, now)
    table.clear(hunt_mod.crew_mask)
    local hunters, hn = nil, 0
    for _, c in ipairs(chars) do
        if c.in_zone and c.pt_data then
            hunt_mod.crew_mask[bit_band(c.pt_data.sId, 0xFFFF)] = true
            local hm = config.combat.huntmode[c.name_lower] or 0
            c.hunt[1]   = (hm > 0)     -- keep bool in sync for any code that reads it
            c.hunt_conv = (hm == 2)    -- converge mode: all boxes focus the same mob
            if hm > 0 then
                hunters = hunters or {}
                hn = hn + 1; hunters[hn] = c
            end
        end
    end

    hunt_mod.eng_n = 0
    if hn == 0 then
        for _, c in ipairs(chars) do
            if c.hunt_engaged then hunt_mod.disengage(c); c.hunt_engaged = false; c.hunt_assigned = 0; c.hunt_pulled = nil end
            if c.run_active   then hunt_mod.stoprun(c);   c.run_idx = nil end
        end
        return
    end

    local radius = (config.combat.radius or 12.0)
    local r2 = radius * radius

    -- Clear movement state for any box that just left the hunt roster (hunt toggled
    -- off while the box was mid-runto). The hn==0 early return handles the all-off
    -- case; this sweep catches individual boxes when at least one box is still hunting.
    for _, c in ipairs(chars) do
        if not c.hunt[1] and c.run_active then
            hunt_mod.stoprun(c); c.run_idx = nil
        end
    end

    -- resolve each hunter's ground position (for per-hunter distance gating)
    for i = 1, hn do
        local c = hunters[i]
        c._hx, c._hy = hunt_mod.box_pos(ent, c, now)
    end

    -- 1. CANDIDATE REBUILD (gated): store mob positions, not main-distance.
    if now >= hunt_mod.next_scan then
        hunt_mod.next_scan = now + hunt_mod.scan_gap
        local cand, cn = hunt_mod.cand, 0
        local hp  = hunt_mod.cand_hp
        local nmc = hunt_mod.cand_name or {}; hunt_mod.cand_name = nmc
        local cx  = hunt_mod.cand_x or {};    hunt_mod.cand_x = cx
        local cy  = hunt_mod.cand_y or {};    hunt_mod.cand_y = cy
        table.clear(hp); table.clear(nmc); table.clear(cx); table.clear(cy)
        for idx = hunt_mod.mob_lo, hunt_mod.mob_hi do
            local nm = hunt_mod.valid(ent, idx)
            if nm then
                cn = cn + 1; cand[cn] = idx
                hp[idx]  = ent:GetHPPercent(idx) or 0
                nmc[idx] = nm
                cx[idx]  = ent:GetLocalPositionX(idx) or 0
                cy[idx]  = ent:GetLocalPositionY(idx) or 0
            end
        end
        for i = #cand, cn + 1, -1 do cand[i] = nil end
    end

    local cand, hp, nmc = hunt_mod.cand, hunt_mod.cand_hp, hunt_mod.cand_name
    local cx, cy = hunt_mod.cand_x, hunt_mod.cand_y
    local taken = hunt_mod.taken; table.clear(taken)

    -- 2. STICKY: keep current target if it's a valid whitelist mob. When already
    --    engaged we skip the radius gate: a mob that momentarily drifts past the
    --    radius edge mid-fight should NOT abort the engagement. Radius is re-enforced
    --    once the mob dies and a fresh assignment is needed.
    for i = 1, hn do
        local c = hunters[i]; c._assign = 0
        local cur = c.is_main and get_target_index(mm:GetTarget())
                    or party:GetMemberTargetIndex(c.pt_data.index)
        if cur and cur > 0 and not taken[cur] and c._hx then
            local nm = hunt_mod.valid(ent, cur)
            if nm and hunt_mod.in_list(hunt_mod.list(c), nm) then
                if c.hunt_engaged then
                    -- committed: mob is alive and whitelisted; hold it
                    c._assign = cur; taken[cur] = true
                else
                    local dx = (ent:GetLocalPositionX(cur) or 0) - c._hx
                    local dy = (ent:GetLocalPositionY(cur) or 0) - c._hy
                    if dx*dx + dy*dy <= r2 then c._assign = cur; taken[cur] = true end
                end
            end
        end
    end

    -- 3. DISTINCT (Hunt mode): idle HUNT hunters take the nearest free in-radius
    --    whitelist mob. Live entity positions are used here instead of the cached
    --    cx/cy from the scan: stale scan positions (up to scan_gap old) caused boxes
    --    to be assigned to mobs that had already walked outside the radius.
    for i = 1, hn do
        local c = hunters[i]
        if c._assign == 0 and c._hx and not c.hunt_conv then
            local L = hunt_mod.list(c)
            local best, bestd = 0, r2
            for k = 1, #cand do
                local idx = cand[k]
                if not taken[idx] and hunt_mod.in_list(L, nmc[idx] or '') then
                    if (ent:GetHPPercent(idx) or 0) > 0 then
                        local mx = ent:GetLocalPositionX(idx) or 0
                        local my = ent:GetLocalPositionY(idx) or 0
                        local dx, dy = mx - c._hx, my - c._hy
                        local d = dx*dx + dy*dy
                        if d <= bestd then best, bestd = idx, d end
                    end
                end
            end
            if best ~= 0 then c._assign = best; taken[best] = true end
        end
    end

    -- 3b. CONVERGE: all converge-mode boxes focus the same highest-HP in-radius
    --     mob (live positions). The mob is chosen relative to the first converge
    --     box with a resolved position and is NOT marked taken, so Hunt boxes
    --     remain fully independent.
    local converge_idx = 0
    do
        local chx, chy = nil, nil
        for i = 1, hn do
            if hunters[i].hunt_conv and hunters[i]._hx then
                chx, chy = hunters[i]._hx, hunters[i]._hy; break
            end
        end
        if chx then
            local besthp = -1
            for k = 1, #cand do
                local idx = cand[k]
                if (ent:GetHPPercent(idx) or 0) > 0 then
                    local mx = ent:GetLocalPositionX(idx) or 0
                    local my = ent:GetLocalPositionY(idx) or 0
                    local dx, dy = mx - chx, my - chy
                    if dx*dx + dy*dy <= r2 then
                        local h = hp[idx] or 0
                        if h > besthp then converge_idx = idx; besthp = h end
                    end
                end
            end
        end
    end
    for i = 1, hn do
        local c = hunters[i]
        if c._assign == 0 and c.hunt_conv then
            c._assign = converge_idx   -- shared target; no taken mark
        end
    end

    -- 4. SHARED FALLBACK: highest-HP taken mob within this hunter's radius
    --    (live positions for same reason as step 3).
    for i = 1, hn do
        local c = hunters[i]
        if c._assign == 0 and c._hx then
            local L, best, besthp = hunt_mod.list(c), 0, -1
            for idx in pairs(taken) do
                if hunt_mod.in_list(L, nmc[idx] or '') then
                    local mx = ent:GetLocalPositionX(idx) or 0
                    local my = ent:GetLocalPositionY(idx) or 0
                    local dx, dy = mx - c._hx, my - c._hy
                    if dx*dx + dy*dy <= r2 then
                        local h = hp[idx] or 0
                        if h > besthp then best, besthp = idx, h end
                    end
                end
            end
            if best ~= 0 then c._assign = best end
        end
    end

    -- 5. DISPATCH + engaged union (RDM multi-target debuffing reads this)
    local eng, en = hunt_mod.engaged, 0
    for i = 1, hn do
        local c = hunters[i]; local idx = c._assign
        local rm = config.combat.retmode[c.name_lower] or 0
        local camp_ok = config.combat.camp_set and not c.is_main
        local prev = c.hunt_prev_mob

        -- DEATH-return: if this box's previous mob just died, open a return-to-
        -- camp window so it heads home before the next pull.
        if rm == 2 and prev and prev ~= idx and (ent:GetHPPercent(prev) or 0) <= 0 and camp_ok then
            c.camp_until = now + 10.0
        end

        if idx ~= 0 then
            en = en + 1; eng[en] = idx

            -- mob's ground position relative to this hunter, used by every distance
            -- gate below (engage range, pull range, leash range, camp-claim range).
            local mx = ent:GetLocalPositionX(idx) or 0
            local my = ent:GetLocalPositionY(idx) or 0
            local mdx = mx - (c._hx or mx)
            local mdy = my - (c._hy or my)
            local mdist2 = c._hx and (mdx * mdx + mdy * mdy) or nil

            -- `changed` tracks the assignment edge (true only on the tick a NEW mob
            -- is acquired) for the pull gate below. hunt_assigned is updated
            -- unconditionally every tick so this stays a true one-tick edge even
            -- though actual /attack on issuance is now gated by engage range
            -- (see in_engage_range) and may lag several ticks behind assignment.
            local changed = (c.hunt_assigned ~= idx)
            c.hunt_assigned = idx

            -- ENGAGE GATE: don't draw weapon / commit to melee until within 10y.
            -- Hunt-mode boxes used to /attack on the instant a mob was assigned,
            -- from any distance -- weapon out, running, swinging at air the whole
            -- approach and broadcasting aggro early. Movement (below) still closes
            -- the gap regardless of this gate; only the actual engage command waits.
            local in_engage_range = mdist2 and mdist2 <= hunt_mod.ENGAGE_DIST2
            if in_engage_range then
                local curtgt = c.is_main and get_target_index(mm:GetTarget())
                               or party:GetMemberTargetIndex(c.pt_data.index)
                local wrong = (curtgt ~= idx)
                local stale = (now - (c.hunt_last_cmd or 0) >= hunt_mod.RESEND)
                if (not c.hunt_engaged or wrong or stale) and (now - (c.hunt_last_cmd or 0) >= hunt_mod.CMD_GAP) then
                    hunt_mod.attack(c, idx)
                    c.hunt_last_cmd = now; c.hunt_engaged = true
                end
            end

            -- pull: fire once, only when within THIS box's pull distance of the
            -- mob. Per-character range (hunt_mod.pull_dist) since different pull
            -- actions (ranged shot vs. a Dia cast vs. a melee Provoke) have very
            -- different practical reach. Guard `not changed`: deferring the pull
            -- to the tick AFTER assignment avoids racing the attack command at
            -- rdmhelper (see longer note in prior revisions).
            local pc = hunt_mod.pull_cmd(c)
            if pc ~= '' and c.hunt_pulled ~= idx and mdist2 and not changed then
                local pd = hunt_mod.pull_dist(c)
                if mdist2 <= pd * pd then
                    hunt_mod.do_pull(c, idx, pc)
                    c.hunt_pulled = idx
                end
            end

            -- MOVEMENT. Camp-return (claim mode once the mob is close, or an
            -- active post-death window) takes priority over everything else.
            -- Otherwise: LEASH -- keep this box within its own configured
            -- fight_range of the mob at all times while assigned. This is what
            -- stops a box from ending up out of melee/WS range (terrain, model
            -- hitbox, knockback, whatever) while the mob can still reach IT.
            -- Movement is enabled whenever the box has no pull command (nothing
            -- else would ever close the gap) or the Run checkbox is explicitly on;
            -- a mage sitting at range with a pull spell configured and Run off
            -- simply never triggers this -- exactly the "stay out of range" case.
            local mob_near = mdist2 and mdist2 <= 36.0  -- within 6y, for Ret:Claim
            local want_camp = camp_ok and ((rm == 1 and mob_near) or (now < (c.camp_until or 0)))
            if want_camp then
                if c.run_idx ~= 'camp' or (now - (c.run_last or 0) >= 4.0) then
                    hunt_mod.goto_camp(c); c.run_idx = 'camp'; c.run_last = now
                end
            elseif not c.is_main and mdist2 and ((c.runto and c.runto[1]) or pc == '') then
                local fr = hunt_mod.fight_range(c)
                if mdist2 > fr * fr then
                    if c.run_idx ~= idx or (now - (c.run_last or 0) >= 4.0) then
                        hunt_mod.runto(c, idx); c.run_idx = idx; c.run_last = now
                    end
                elseif c.run_active and c.run_idx == idx then
                    hunt_mod.stoprun(c); c.run_idx = nil   -- back within leash range; stop
                end
            elseif c.run_active then
                hunt_mod.stoprun(c); c.run_idx = nil
            end
            c.hunt_prev_mob = idx
        else
            -- no assignment: keep heading home if a death window is open.
            if camp_ok and now < (c.camp_until or 0) then
                if c.run_idx ~= 'camp' or (now - (c.run_last or 0) >= 4.0) then
                    hunt_mod.goto_camp(c); c.run_idx = 'camp'; c.run_last = now
                end
            elseif c.run_active then
                -- Stop any in-progress run (mob dead, no camp window). Without this,
                -- a box that arrived at camp (run_idx='camp') would keep run_active=true
                -- and suppress follow indefinitely.
                hunt_mod.stoprun(c); c.run_idx = nil
            end
            if c.hunt_engaged then
                hunt_mod.disengage(c); c.hunt_engaged = false; c.hunt_assigned = 0; c.hunt_pulled = nil
            end
            c.hunt_prev_mob = nil
        end
    end
    hunt_mod.eng_n = en

    for idx in pairs(hunt_mod.diaed) do
        local live = false
        for i = 1, en do if eng[i] == idx then live = true; break end end
        if not live then hunt_mod.diaed[idx] = nil end
    end
end

-- FACE-LOCK dispatch: alts toggle helper-side facing (edge-triggered); the MAIN
-- runs sync not the helper, so its facing is driven by hunt_mod.face_main.
function hunt_mod.facelock(now)
    for _, c in ipairs(chars) do
        local want = c.face[1] and c.in_zone or false
        if c.is_main then
            hunt_mod.main_face = want
        elseif want ~= (c.face_sent or false) then
            if want then
                qcmd(c.mst_prefix .. '/rdmhelper face on ' .. string.format('%.4f', hunt_mod.yaw_off or 0.0))
            else
                qcmd(c.mst_prefix .. '/rdmhelper face off')
            end
            c.face_sent = want
        end
    end
end

-- MAIN self-facing. Resolves the local player's entity index by matching
-- MAIN self-facing. atom0s' method: the local player's RENDERED heading is the
-- actor heading float at ActorPointer + 0x48 (LocalPosition.Yaw is input-driven
-- and gets stomped each frame, which is why struct writes never held). Writing
-- ptr+0x48 every frame turns the body with no camera lock. Direction is
-- -atan2(dy, dx) over the X/Y ground plane (gnubeardo's 'facing'); yaw_off (from
-- /sync faced) absorbs any residual convention. Gated on engaged status so it
-- never fights follow-movement while the box is travelling to the main.
function hunt_mod.face_main(party, ent, targ)
    if not hunt_mod.main_face then return end
    local cur = get_target_index(targ)
    if cur == 0 then return end
    local me = GetPlayerEntity()
    if not me or me.Status ~= 1 then return end
    local ptr = me.ActorPointer
    if not ptr or ptr == 0 then return end
    local tgt = GetEntity(cur)
    if not tgt then return end
    local sp, tp = me.Movement.LocalPosition, tgt.Movement.LocalPosition
    local yaw = -(math.atan2 or math.atan)(tp.Y - sp.Y, tp.X - sp.X) + (hunt_mod.yaw_off or 0.0)
    ashita.memory.write_float(ptr + 0x48, yaw)
end

-- FACE CALIBRATION: with face OFF, manually face a target, target it, run
-- /sync faced. Reads the engine's actual actor heading (ptr+0x48) vs our computed
-- -atan2(dy,dx); the normalized difference is stored as yaw_off and added to every
-- facing write, absorbing this build's heading convention. /sync faced reset clears.
function hunt_mod.calibrate(party, ent, targ, arg)
    if arg == 'reset' or arg == '0' then
        hunt_mod.yaw_off = 0.0
        config.combat.yaw_off = 0.0
        settings.save()
        for _, c in ipairs(chars) do c.face_sent = nil end
        print('[sync] face calibration reset (yaw_off = 0)')
        return
    end
    local cur = get_target_index(targ)
    if cur == 0 then print('[sync] /sync faced: target the mob you are FACING first (with Face OFF)'); return end
    local me = GetPlayerEntity()
    local tgt = GetEntity(cur)
    if not me or not tgt then print('[sync] /sync faced: could not read player/target entity'); return end
    local ptr = me.ActorPointer
    if not ptr or ptr == 0 then print('[sync] /sync faced: no actor pointer'); return end
    local sp, tp = me.Movement.LocalPosition, tgt.Movement.LocalPosition
    local computed = -(math.atan2 or math.atan)(tp.Y - sp.Y, tp.X - sp.X)
    local H = ashita.memory.read_float(ptr + 0x48)
    local off = H - computed
    while off >  math.pi do off = off - 2 * math.pi end
    while off <= -math.pi do off = off + 2 * math.pi end
    hunt_mod.yaw_off = off
    config.combat.yaw_off = off
    settings.save()
    for _, c in ipairs(chars) do c.face_sent = nil end
    print(string.format('[sync] face calibrated: engine=%.3f computed=%.3f -> yaw_off=%.3f (saved)', H, computed, off))
end


-- RDM hunt-mode debuff: pick the first crew-engaged mob not yet Dia'd and cast
-- via the helper. Fires once per mob (cleared on death/disengage). Gated by the
-- caller on rdm.action_lock. Returns true if a cast was issued.
function hunt_mod.rdm_dia(rdm, ent, now)
    local cmd = config.combat.rdm_dia or ''
    if cmd == '' then return false end
    local eng, n = hunt_mod.engaged, hunt_mod.eng_n
    for i = 1, n do
        local midx = eng[i]
        if midx and midx > 0 and (ent:GetHPPercent(midx) or 0) > 5
           and not hunt_mod.diaed[midx] then
            -- Dia each engaged mob ONCE. diaed[idx] is cleared when the mob leaves
            -- the engaged union (death/disengage), so a new mob at that index re-Dias.
            -- route via exec so the raw command (quotes/aliases) reaches the box intact.
            do_action(rdm, '/rdmhelper exec ' .. midx .. ' ' .. cmd, get_cast_delay('Dia III'), now)
            hunt_mod.diaed[midx] = true
            return true
        end
    end
    return false
end

------------------------------------------------------------
-- HOISTED PER-TICK HELPERS
------------------------------------------------------------
-- OPT: these two used to be closures created *inside* logic_loop, so a fresh
-- function object was allocated on every 10Hz tick they were reached (steady GC
-- churn + a logic_loop-scope local each). Parked on existing module tables so
-- they're built once at load: zero per-tick allocation, zero new main-chunk
-- locals (the 200-ceiling is at ~195), and two locals freed back to logic_loop.

-- Blacklist redirect: pcall'd because SetTarget can throw on a stale entity.
function hunt_mod.set_target_safe(tg, idx) tg:SetTarget(idx, false) end

-- RDM charm watch: crew member is charmed (attacking us) and not yet asleep.
function geo_mod.charmed_awake(t)
    if not (t.heal and t.heal[1] and t.in_zone and t.pt_data) then return false end
    local st = t.status or 0
    return bit_band(st, CHARM_BIT) ~= 0 and bit_band(st, SLEEP_BIT) == 0
end

------------------------------------------------------------
-- MAIN LOGIC LOOP
------------------------------------------------------------
ashita.events.register('d3d_present', 'logic_loop', function()
    local now = os_clock()
    if now - lastTick < TICK_ACTION then return end
    lastTick = now

    drain_pending(now)

    local player, party, ent = mm:GetPlayer(), mm:GetParty(), mm:GetEntity()
    if not player or not party or not ent then return end

    if player:GetIsZoning() ~= 0 then
        is_zoning_prev = true
        return
    elseif is_zoning_prev then
        reset_combat_flags()
        config.combat.camp_set = false   -- camp position is zone-specific; force re-set
        guests = {}; debuff_queue = {}
        last_engage_target = 0
        is_zoning_prev = false
    end

    if now - lastScanTick >= TICK_SCAN then
        update_membership_and_zones(party)
        scan_buffs(party, player, now)
        lastScanTick = now
    end

    local rdm       = cached_rdm
    local main_char = cached_main
    local main_idx  = (main_char and main_char.pt_data)
                      and party:GetMemberTargetIndex(main_char.pt_data.index)
                      or  party:GetMemberTargetIndex(0)

    local main_is_attacking = (main_idx > 0 and ent:GetStatus(main_idx) == 1)

    local targ = mm:GetTarget()
    local engageTarget = 0
    if main_is_attacking then
        engageTarget = get_player_target(targ)
        if engageTarget == 0 then
            engageTarget = GetTargetOfTarget(targ, ent)
        end
    end

    if engageTarget ~= last_engage_target then
        debuff_queue = {}
        last_engage_target = engageTarget
    end

    -- COMBAT MODE: radius pack-hunting + face-lock. hunt_mod.run builds the engaged
    -- union used below for RDM multi-target debuffing in hunt mode.
    hunt_mod.run(party, ent, player, now)
    hunt_mod.facelock(now)
    hunt_mod.face_main(party, ent, targ)
    hunt_mod.main_move_tick(now)

    -- BLACKLIST ENFORCEMENT for the main: if the main has targeted a blacklisted
    -- mob (via autotarget / Tab or any other means), immediately redirect to the
    -- current hunt assignment or clear the target. Runs every tick so the game's
    -- native autotarget can't hold a blacklisted mob for more than one frame.
    if main_char and main_char.in_zone then
        local bl_tg  = mm:GetTarget()
        local bl_idx = get_target_index(bl_tg)
        if bl_idx > 0 and bl_tg then
            local bl_nm = ent and ent:GetName(bl_idx)
            if bl_nm and hunt_mod.blacklisted(bl_nm) then
                local next_idx = (main_char._assign and main_char._assign > 0)
                                  and main_char._assign or 0
                pcall(hunt_mod.set_target_safe, bl_tg, next_idx)
            end
        end
    end

    local rdm_in_zone = rdm and rdm.in_zone and rdm.pt_data

    ------------------------------------------------------------
    -- HEALER PASS -- main + backup healers cast concurrently (independent boxes,
    -- independent action_locks). Runs before the RDM block so that if a healer is
    -- also the RDM, casting a heal sets its lock and the buff/debuff block yields.
    ------------------------------------------------------------
    local cfg1 = config.healers[1]
    local cfg2 = config.healers[2]
    local n1   = cfg1 and (cfg1.name or ''):lower() or ''
    local n2   = cfg2 and (cfg2.name or ''):lower() or ''
    local mh = (n1 ~= '') and resolve_healer(n1) or nil
    local bh = (cfg2 and n2 ~= '' and n2 ~= n1) and resolve_healer(n2) or nil

    -- Work gate (mirrors the RDM's rdm_has_work): a healer only acts -- including
    -- popping stances like Light Arts/Addendum/Solace -- when at least one in-zone
    -- member actually has Cure (heal) checked. No recipients => no action.
    local heal_work = false
    for _, c in ipairs(chars)  do if c.heal and c.heal[1] and c.in_zone then heal_work = true; break end end
    if not heal_work then
        for _, g in ipairs(guests) do if g.heal and g.heal[1] and g.in_zone then heal_work = true; break end end
    end

    if heal_work then
        if mh and now > mh.action_lock then
            heal_pass(mh, cfg1, party, player, now, cfg1.na, true)
        end
        if bh and now > bh.action_lock then
            heal_pass(bh, cfg2, party, player, now, cfg2.na, true)
        end

        -- WHM-MAIN EXTRAS pass (Protectra V / Shellra V / Auspice / Boost-X /
        -- Bar-Element / Bar-Status / Accession+Regen). FIX: now gated behind the
        -- same heal_work check as cures/stances, so unchecking Cure suppresses the
        -- proactive WHM buffs too -- no Protectra/Auspice/Regen casts during
        -- downtime when healing is off. Each healer still cycles its own extras
        -- using its own action_lock + cast_reserved_until reservations; the pass
        -- short-circuits at the top when nothing is enabled in that slot.
        -- WHM HASTE monitor (healer-menu toggle) -- runs BEFORE the timer-driven
        -- extras so a missing Haste takes priority over a Protectra/Auspice
        -- refresh. Same action_lock gate => still only one cast per box per tick.
        if mh and now > mh.action_lock then
            geo_mod.haste_pass(mh, cfg1, party, player, now)
        end
        if bh and now > bh.action_lock then
            geo_mod.haste_pass(bh, cfg2, party, player, now)
        end

        if mh and now > mh.action_lock then
            geo_mod.whm_extras_pass(mh, cfg1, party, now)
        end
        if bh and now > bh.action_lock then
            geo_mod.whm_extras_pass(bh, cfg2, party, now)
        end
    end

    ------------------------------------------------------------
    -- RDM DEBUFF MOVEMENT PAUSE
    ------------------------------------------------------------
    if rdm then
        if not rdm_in_zone then
            rdm.debuff_pause = false
        elseif now > rdm.action_lock then
            local pause = false
            if rdm.deb[1] and not rdm.low_mp_mode and engageTarget > 0
            and ent:GetHPPercent(engageTarget) > 5 then
                local q = debuff_queue[engageTarget]
                if not q then
                    pause = true
                else
                    for _, d in ipairs(q) do
                        if not d.done then pause = true; break end
                    end
                end
            end
            if pause and not rdm.debuff_pause then
                rdm.action_lock = now + TIMING.settle
            end
            rdm.debuff_pause = pause
        end
    end

    ------------------------------------------------------------
    -- CHARM SLEEP BOOKKEEPING -- runs every tick the RDM is zoned (independent of
    -- the RDM action_lock) so the per-victim attempt budget and the "sleep is
    -- sticking" timer stay accurate. A Sleep that holds for CHARM_SLEEP_STUCK
    -- refunds the budget; everything resets the instant the member is no longer
    -- charmed. See the cast gate below for how the budget is spent.
    ------------------------------------------------------------
    if rdm_in_zone then
        for _, c in ipairs(chars)  do if not c.is_rdm then sleep_bookkeep(rdm, c, now) end end
        for _, g in ipairs(guests) do sleep_bookkeep(rdm, g, now) end
    end

    ------------------------------------------------------------
    -- RDM LOGIC
    ------------------------------------------------------------
    if rdm_in_zone and now > rdm.action_lock then
        local rdmIdx = rdm.pt_data.index
        local rdmMP  = party:GetMemberMP(rdmIdx) or 0

        -- CHARM CONTROL -- a charmed crew member attacks the party; the RDM keeps
        -- them asleep with Sleep II (re-cast when the sleep wears, while charm
        -- persists). We never cure/wake a charmed member (see heal_pass).
        if rdmMP >= 30 then
            local ca = geo_mod.charmed_awake
            local victim = nil
            for _, c in ipairs(chars)  do if not c.is_rdm and ca(c) then victim = c; break end end
            if not victim then for _, g in ipairs(guests) do if ca(g) then victim = g; break end end end
            if victim then
                local locks = rdm.buff_locks[victim.name]
                if not locks then locks = {}; rdm.buff_locks[victim.name] = locks end
                if (locks.sleep2_n or 0) < CHARM_SLEEP_MAX
                   and now - (locks['sleep2'] or 0) >= CHARM_SLEEP_GAP then
                    locks['sleep2'] = now
                    locks.sleep2_n  = (locks.sleep2_n or 0) + 1
                    do_action(rdm, '/ma "Sleep II" ' .. victim.name, get_cast_delay("Sleep II"), now)
                    goto SKIP_RDM_BUFF
                end
            end
        end

        local rdm_has_work = rdm.deb[1]
        if not rdm_has_work then
            for _, c in ipairs(chars)  do if c.buf and c.buf[1] and c.in_zone then rdm_has_work = true; break end end
        end
        if not rdm_has_work then
            for _, g in ipairs(guests) do if g.buf and g.buf[1] and g.in_zone then rdm_has_work = true; break end end
        end
        if not rdm_has_work then
            rdm.low_mp_mode = false
            rdm.emergency_refresh = false
            goto SKIP_RDM_BUFF
        end

        if rdmMP < 250 then
            if now > (rdm.convert_lock or 0) then
                rdm.convert_lock = now + 600.0
                do_action(rdm, '/ja "Convert" <me>', 1.5, now)
                rdm.emergency_refresh = true
                goto SKIP_RDM_BUFF
            end
            rdm.low_mp_mode = true
        elseif rdmMP >= 450 then
            rdm.low_mp_mode = false
        end

        if rdm.emergency_refresh then
            if rdm.buffs.r then
                rdm.emergency_refresh = false
            else
                rdm.buff_locks[rdm.name] = rdm.buff_locks[rdm.name] or {}
                local last_cast = rdm.buff_locks[rdm.name]['r'] or 0
                
                if now - last_cast >= BUFF_RETRY_GAP then
                    do_action(rdm, '/ma "Refresh III" <me>', get_cast_delay("Refresh III"), now)
                    rdm.buff_locks[rdm.name]['r'] = now
                end
            end
            goto SKIP_RDM_BUFF
        end

        if rdm.low_mp_mode then goto SKIP_RDM_BUFF end

        -- HUNT MODE: cycle Dia III across every crew-engaged mob (logic in
        -- hunt_mod.rdm_dia so logic_loop gains no locals). Returns true when it
        -- fired a cast this tick; falls through to the single-target queue when
        -- no hunt is active.
        if rdm.deb[1] and hunt_mod.eng_n > 0 and hunt_mod.rdm_dia(rdm, ent, now) then
            goto SKIP_RDM_BUFF
        end

        if rdm.deb[1] and engageTarget > 0 and ent:GetHPPercent(engageTarget) > 5 then
            local q = get_debuff_queue(engageTarget, rdm)

            for _, d in ipairs(q) do
                if not d.done then
                    do_action(rdm, '/ma "' .. d.name .. '" [t]', get_cast_delay(d.name), now)
                    d.done = true; goto SKIP_RDM_BUFF
                end
            end
        end

        if now >= rdm_buff_idle_until then
            local bKey, bTarget = nil, nil
            
            for _, key in ipairs(RDM_SELF_FIRST) do
                if rdm.buf and rdm.buf[1] and check_needs(rdm, key, rdm, now) then 
                    bKey, bTarget = key, rdm; goto found 
                end
            end
            
            for _, key in ipairs(BUFF_PRIORITY) do
                for _, t in ipairs(chars)  do 
                    if t.buf and t.buf[1] and check_needs(t, key, rdm, now) then 
                        bKey, bTarget = key, t; goto found 
                    end 
                end
                for _, g in ipairs(guests) do 
                    if g.buf and g.buf[1] and check_needs(g, key, rdm, now) then 
                        bKey, bTarget = key, g; goto found 
                    end 
                end
            end
            ::found::

            if bKey and bTarget and rdmMP > 50 then
                local comp_readable = (rdm.pt_data.index < 6)
                    or (now - (rdm.last_rep_time or 0) < STANCE_READABLE_GAP)
                if rdm.buffs.comp then rdm.comp_seen = now end
                if not rdm.buffs.comp and comp_readable
                   and (now - (rdm.comp_seen or 0)) >= STANCE_LOSS_DEBOUNCE
                   and now > (rdm.comp_lock or 0) then
                    rdm.comp_lock = now + PERMA_STANCE_GUARD
                    do_action(rdm, '/ja "Composure" <me>', 1.5, now)
                    goto SKIP_RDM_BUFF
                end

                local is_self = (bTarget.name_lower == rdm.name_lower)
                local spell = "Haste II"
                if     bKey == 'r'   then spell = "Refresh III"
                elseif bKey == 'p'   then spell = is_self and "Phalanx" or "Phalanx II"
                elseif bKey == 'pro' then spell = "Protect V"
                elseif bKey == 'sh'  then spell = "Shell V" end
                if bKey == 'h' and bTarget.fl and bTarget.fl[1] then spell = "Flurry II" end

                rdm.buff_locks[bTarget.name]       = rdm.buff_locks[bTarget.name] or {}
                rdm.buff_locks[bTarget.name][bKey] = now

                local target_str = is_self and "<me>" or bTarget.name
                do_action(rdm, '/ma "' .. spell .. '" ' .. target_str, get_cast_delay(spell), now)
            else
                rdm_buff_idle_until = now + TICK_SCAN
            end
        end
    end
    ::SKIP_RDM_BUFF::

    ------------------------------------------------------------
    -- GEO SCHEDULER -- fires Indi / Geo / Entrust on the configured GEO box.
    -- Slots tick on duration+jitter (cast fires recast_min..recast_max seconds
    -- BEFORE configured wear-off). All commands are scheduled via mst_prefix
    -- using the existing do_action / queue_cast pipeline; the GEO box's
    -- action_lock prevents stacked casts. config.geo.character == '' or no
    -- matching crew slot -> entire block skipped.
    ------------------------------------------------------------
    do
        local gcfg = config.geo
        if gcfg and gcfg.character and gcfg.character ~= '' and gcfg.active ~= false and now >= geo_mod.next_check then
            geo_mod.next_check = now + geo_mod.tick

            local gname = gcfg.character:lower()
            local gchar = nil
            for _, cc in ipairs(chars) do if cc.name_lower == gname then gchar = cc; break end end

            if gchar and gchar.in_zone and now > gchar.action_lock then
                local fired = false

                -- Helper: time to fire this slot? slot.wear_at is os.clock()
                -- of expected drop. Re-fire when now >= wear_at - jitter (or
                -- wear_at == 0 = never cast). Random jitter is rolled here so
                -- each window is a different point in the recast_min..max band.
                local function due(slot, recmin, recmax)
                    if slot.wear_at == 0 then return true end
                    if slot.jitter == 0 then
                        slot.jitter = math.random(recmin, recmax)
                    end
                    return now >= (slot.wear_at - slot.jitter)
                end
                local function mark_fired(slot, duration)
                    slot.wear_at = now + duration
                    slot.jitter  = 0   -- re-roll next time we evaluate
                end

                -- 1) GEO bubble (with optional BoG pre / EA + Demat post)
                local gs = gcfg.geo
                if not fired and gs and gs.spell and gs.spell ~= '' and due(geo_mod.geo, gs.recast_min, gs.recast_max) then
                    local should_cast = true
                    local cast_target = nil
                    if gs.target_mode == 'mob' then
                        if gs.combat_only and not main_is_attacking then
                            should_cast = false
                        else
                            cast_target = (gs.target ~= '' and gs.target) or '<bt>'
                        end
                    else
                        cast_target = (gs.target ~= '' and gs.target) or '<me>'
                    end

                    if should_cast and cast_target then
                        local ja = gcfg.ja or {}
                        local base = now
                        local geo_cmd  = '/ma "' .. gs.spell .. '" ' .. cast_target
                        local geo_cast = 8.0   -- conservative ETC for a Geo- cast incl. animation lock

                        if ja.bog then
                            -- BoG immediately, then Geo ~1.5s later
                            do_action(gchar, '/ja "Blaze of Glory" <me>', 1.5, base)
                            queue_cast(gchar, geo_cmd, base + 1.5, geo_cast)
                            base = base + 1.5
                        else
                            do_action(gchar, geo_cmd, geo_cast, base)
                        end

                        -- Post-bubble JAs (Ecliptic Attrition, Dematerialize)
                        local post = base + geo_cast + 1.0
                        if ja.ea then
                            queue_cast(gchar, '/ja "Ecliptic Attrition" <me>', post, 1.5)
                            post = post + 1.5
                        end
                        if ja.demat then
                            queue_cast(gchar, '/ja "Dematerialize" <me>', post, 1.5)
                        end

                        mark_fired(geo_mod.geo, gs.duration or 240)
                        fired = true
                    end
                end

                -- 2) Indi (always self-cast)
                local is = gcfg.indi
                if not fired and is and is.spell and is.spell ~= '' and due(geo_mod.indi, is.recast_min, is.recast_max) then
                    do_action(gchar, '/ma "' .. is.spell .. '" <me>', 8.0, now)
                    mark_fired(geo_mod.indi, is.duration or 240)
                    fired = true
                end

                -- 3) Entrust (Indi on a named party member)
                local es = gcfg.entrust
                if not fired and es and es.spell and es.spell ~= '' and es.target and es.target ~= ''
                   and due(geo_mod.entrust, es.recast_min, es.recast_max) then
                    -- Entrust JA first, then the Indi spell on the named target
                    do_action(gchar, '/ja "Entrust" <me>', 1.5, now)
                    queue_cast(gchar, '/ma "' .. es.spell .. '" ' .. es.target, now + 1.5, 8.0)
                    mark_fired(geo_mod.entrust, es.duration or 240)
                end
            end
        end
    end

    ------------------------------------------------------------
    -- BRD SCHEDULER -- cycle-timer bard; songs/JAs fire on the bard box via /mst.
    ------------------------------------------------------------
    geo_mod.brd.tick(now)

    ------------------------------------------------------------
    -- CHARACTER LOGIC
------------------------------------------------------------
    for _, c in ipairs(chars) do
        if not c.is_main then
            local want_follow = c.f[1] and not c.debuff_pause and not ((c.runto and c.runto[1]) or c.run_active)
            if want_follow and c.actual_follow ~= true then
                qcmd(c.cmd_follow_on, true)
                c.actual_follow = true
            elseif not want_follow and c.actual_follow ~= false then
                qcmd(c.cmd_follow_off, true)
                c.actual_follow = false
            end
            
            if c.in_zone and now > c.action_lock then
                local pIdx   = c.pt_data.index
                local entIdx = party:GetMemberTargetIndex(pIdx)
                if entIdx > 0 then
                    local is_attacking = (ent:GetStatus(entIdx) == 1)

                    if c.abs[1] and now > (c.abs_last or 0) + 30 then
                        c.abs_last = now
                        do_action(c, '/ma "Absorb-TP" Aminon', 1.5, now)
                    end

                    if c.e[1] and not c.brd_hold then
                        if main_is_attacking and engageTarget > 0 then
                            local time_since = now - (c.last_engage_time or 0)
                            if (c.last_engage_target ~= engageTarget or not is_attacking)
                                and time_since >= TIMING.engage then
                                local cmd = c.cmd_attack_on
                                chat:QueueCommand(1, cmd)
                                queue_retry(c, cmd, now)
                                c.last_engage_target = engageTarget
                                c.auto_engaged       = true
                                c.last_engage_time   = now
                            end
                        elseif not main_is_attacking and c.auto_engaged then
                            if is_attacking then
                                chat:QueueCommand(1, c.cmd_attack_off)
                            end
                            c.last_engage_target = 0
                            c.auto_engaged       = false
                            c.last_engage_time   = 0
                            c.retry              = nil
                        end
                    else
                        c.auto_engaged = false
                        c.retry        = nil
                    end

                    if is_attacking then
                        local tp = party:GetMemberTP(pIdx)

                        if c.hs[1] and tp >= 350 and not c.buffs.samba then
                            do_action(c, '/ja "Haste Samba" <me>', 1.5, now)
                        end

                        if (c.bs[1] or c.qs[1]) and tp >= 100 and now > (c.step_last or 0) + 10 then
                            local s = (c.bs[1] and c.qs[1])
                                and (c.next_step == "Box Step" and "Quick Step" or "Box Step")
                                or  (c.bs[1] and "Box Step" or "Quick Step")
                            c.next_step, c.step_last = s, now
                            do_action(c, '/ja "' .. s .. '" <t>', 1.5, now)
                        end
                    end

                    process_retry(c, now, party, ent)
                end
            end
        end
    end
end)

------------------------------------------------------------
-- UI & COMMANDS
------------------------------------------------------------
local function draw(t, col, now)
    igTableNextRow(); igTableNextColumn()
    local c = not t.in_zone and COLOR_OFFLINE
        or (t.low_mp_mode and COLOR_RECOVERING)
        or (now <= t.action_lock and COLOR_BUSY or col)
    if c then igTextColored(c, t.disp_name) else igText(t.disp_name) end
    -- Tip on the name cell: full character name + role/status hint.
    if igIsItemHovered() then
        local role = t.is_main and ' (main)' or (t.is_rdm and ' (RDM)' or (col == COLOR_GUEST and ' (guest)' or ''))
        local stat = (not t.in_zone) and ' - offline'
            or (t.low_mp_mode and ' - low MP')
            or (now <= t.action_lock and ' - busy' or '')
        igSetTooltip(t.name .. role .. stat)
    end
    for _, v in ipairs(ui_columns) do
        igTableNextColumn()
        if not (t.is_main and not v.allow_main)
        and not (v.rdm_only and not t.is_rdm)
        and (col ~= COLOR_GUEST or v.key == 'buf' or v.key == 'heal') then
            igCheckbox(t.ui_ids[v.key], t[v.key])
            -- Tip on the live cell: "{Column} - {Character}" so a hovered checkbox
            -- tells you both what column it is and whose row.
            if igIsItemHovered() then igSetTooltip(v.tip .. '  -  ' .. t.name) end
        else igTextDisabled("-") end
    end
end

local function hstat(nm)
    if nm == '' then return nil end
    for _, c in ipairs(chars) do if c.name_lower == nm then return c.in_zone end end
    return false
end

ashita.events.register('d3d_present', 'render_ui', function()
    if not show_ui then return end
    local now = os_clock()
    igSetNextWindowBgAlpha(0.4)
    if igBegin('Sync', SYNC_WINDOW_OPEN, SYNC_WINDOW_FLAGS) then
        do
            local mn = (config.healers[1] and config.healers[1].name or ''):lower()
            local bn = (config.healers[2] and config.healers[2].name or ''):lower()
            local gn = (config.geo and config.geo.character or ''):lower()
            local dn = (config.brd and config.brd.character or ''):lower()
            local mon, bon, gon, don = hstat(mn), hstat(bn), hstat(gn), hstat(dn)
            imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
            imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
            imgui.PushStyleColor(ImGuiCol_Text, COLOR_GUEST)
            if igSmallButton('Heal:##headbtn') then
                show_advanced = not show_advanced
                adv_seeded = false
            end
            imgui.PopStyleColor(4)
            tip('Open Advanced - crew, healer slots, stances, cure/curaga tiers')
            igSameLine(0, 4)
            igTextColored(mon and COLOR_GUEST or COLOR_OFFLINE,
                (mn == '' and '--' or mn:sub(1,3):upper()) .. (mon and '' or '!'))
            if igIsItemHovered() then
                igSetTooltip(mn == '' and 'Primary healer: (unassigned)'
                    or ('Primary healer: ' .. mn .. (mon and '' or ' - offline')))
            end
            igSameLine(0, 6)
            if bn == '' then
                igTextDisabled('+--')
                tip('Backup healer: (unassigned)')
            else
                igTextColored(bon and COLOR_RECOVERING or COLOR_OFFLINE,
                    '+' .. bn:sub(1,3):upper() .. (bon and '' or '!'))
                if igIsItemHovered() then igSetTooltip('Backup healer: ' .. bn .. (bon and '' or ' - offline')) end
            end
            -- GEO identifier: structurally mirrors `Heal: SLO +GOO`. The
            -- `GEO:` button (green text on transparent bg) opens the
            -- Geomancer panel; the 3-char abbreviated name follows as a
            -- separate text label (green when assigned+zoned, red+! when
            -- offline, dim '--' when unassigned).
            igSameLine(0, 10)
            imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
            imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
            imgui.PushStyleColor(ImGuiCol_Text, STYLE_BTN.geo)
            if igSmallButton('GEO:##geobtn') then
                geo_mod.show_panel = not geo_mod.show_panel
            end
            imgui.PopStyleColor(4)
            if igIsItemHovered() then
                igSetTooltip(gn == ''
                    and 'Geomancer scheduler - click to assign a GEO box and configure spells (/sync geo)'
                    or ('Geomancer: ' .. gn .. (gon and '' or ' - offline')
                        .. '  -  click to open panel (/sync geo)'))
            end
            igSameLine(0, 4)
            if gn == '' then
                igTextDisabled('--')
                tip('Geomancer: (unassigned)')
            else
                igTextColored(gon and STYLE_BTN.geo or COLOR_OFFLINE,
                    gn:sub(1,3):upper() .. (gon and '' or '!'))
                if igIsItemHovered() then igSetTooltip('Geomancer: ' .. gn .. (gon and '' or ' - offline')) end
            end
            -- BRD identifier: structurally mirrors `GEO: GOO`. The `BRD:` button
            -- (purple text on transparent bg) toggles the integrated Bard window
            -- (geo_mod.brd.show_window) -- the same window the /sync brd command and
            -- the in-window controls drive. It never touches config.brd.sing (the
            -- Sing checkbox / `/sync sing` that actually starts/stops the playlist).
            igSameLine(0, 10)
            imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
            imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
            imgui.PushStyleColor(ImGuiCol_Text, STYLE_BTN.brd)
            if igSmallButton('BRD:##brdbtn') then
                geo_mod.brd.show_window = not geo_mod.brd.show_window
            end
            imgui.PopStyleColor(4)
            if igIsItemHovered() then
                igSetTooltip(dn == ''
                    and 'Bard song cycle - click to open the Bard window and assign a BRD box (/sync brd)'
                    or ('Bard: ' .. dn .. (don and '' or ' - offline')
                        .. '  -  click to open the Bard window (/sync brd); /sync sing toggles casting'))
            end
            igSameLine(0, 4)
            if dn == '' then
                igTextDisabled('--')
                tip('Bard: (unassigned)')
            else
                igTextColored(don and STYLE_BTN.brd or COLOR_OFFLINE,
                    dn:sub(1,3):upper() .. (don and '' or '!'))
                if igIsItemHovered() then igSetTooltip('Bard: ' .. dn .. (don and '' or ' - offline')) end
            end
            -- Close X: right-justified to the window's right edge so it sits
            -- in the top-right corner regardless of how wide the table grows
            -- below. geo_mod.right_align falls back gracefully if the binding
            -- doesn't expose GetContentRegionAvail in a usable shape.
            geo_mod.right_align(18)
            imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
            imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
            imgui.PushStyleColor(ImGuiCol_Text, COLOR_OFFLINE)
            if igSmallButton('x##mainclose') then show_ui = false end
            imgui.PopStyleColor(4)
            tip('Hide HUD (/sync to toggle back)')
        end
        if igBeginTable('SyncTable', NUM_UI_COLS + 1, 0) then
            igTableSetupColumn('Name', 0, 24)
            for _, col in ipairs(ui_columns) do igTableSetupColumn(col.label, 0, 26) end
            igTableNextRow(); igTableNextColumn()
            if imgui.SetWindowFontScale then imgui.SetWindowFontScale(0.75) end
            for _, col in ipairs(ui_columns) do
                igTableNextColumn()
                if col.key == 'buf' then
                    imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
                    imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
                    imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
                    imgui.PushStyleColor(ImGuiCol_Text, COLOR_RECOVERING)
                    if igSmallButton(col.hdr .. '##bufhdrbtn') then
                        show_buffpanel = not show_buffpanel
                    end
                    imgui.PopStyleColor(4)
                    tip(col.tip)
                elseif col.key == 'deb' then
                    imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
                    imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
                    imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
                    imgui.PushStyleColor(ImGuiCol_Text, COLOR_GUEST)
                    if igSmallButton(col.hdr .. '##debhdrbtn') then
                        show_debuffpanel = not show_debuffpanel
                    end
                    imgui.PopStyleColor(4)
                    tip(col.tip)
                elseif col.key == 'e' then
                    imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
                    imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
                    imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
                    imgui.PushStyleColor(ImGuiCol_Text, COLOR_GUEST)
                    if igSmallButton(col.hdr .. '##enghdrbtn') then
                        hunt_mod.show_panel = not hunt_mod.show_panel
                    end
                    imgui.PopStyleColor(4)
                    tip(col.tip)
                else
                    igText(col.hdr)
                    tip(col.tip)
                end
            end
            if imgui.SetWindowFontScale then imgui.SetWindowFontScale(1.0) end

            for _, c in ipairs(chars) do draw(c, nil, now) end
            if #guests > 0 then
                igTableNextRow()
                igTableNextColumn()
                if igSmallButton(show_guests and 'v' or '>') then
                    show_guests = not show_guests
                end
                tip(show_guests and 'Hide guest rows' or 'Show guest rows')
                for _ = 1, NUM_UI_COLS do igTableNextColumn() end
                if show_guests then
                    for _, g in ipairs(guests) do draw(g, COLOR_GUEST, now) end
                end
            end
            igEndTable()
        end
    end
    igEnd()
end)

------------------------------------------------------------
-- ADVANCED CONFIG WINDOW
------------------------------------------------------------
local ADV_WINDOW_OPEN  = {true}
local ADV_WINDOW_FLAGS = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)
local NUM_INPUT_FLAGS  = bit.bor(ImGuiInputTextFlags_EnterReturnsTrue, ImGuiInputTextFlags_CharsDecimal or 0)

-- Push the live roster to every rdmhelper box so its CREW/MAIN election stays
-- identical to ours (rdmhelper has no UI; it rebuilds from this broadcast).
local function broadcast_roster()
    local names = {}
    for i = 1, #chars do names[i] = chars[i].name end
    chat:QueueCommand(1, '/mss /rdmhelper crew ' .. table.concat(names, ' '))
end

-- Rename a crew SLOT to a different box. Persists, re-inits derived state,
-- rebuilds the known-core set, and re-pushes the roster.
local function rename_crew(idx, newname)
    newname = (newname or ''):gsub('%s', '')
    if newname == '' or chars[idx].name_lower == newname:lower() then return end
    chars[idx].name = newname
    config.crew[idx] = newname
    settings.save()
    init_char_state(chars[idx])
    t_clear(known_cores)
    for _, c in ipairs(chars) do known_cores[c.name_lower] = true end
    broadcast_roster()
end

-- Resolve a typed healer field to a crew name (prefix match), '' for off, or
-- nil if nothing matches (field left unchanged).
local function resolve_healer_field(str)
    str = (str or ''):lower():gsub('%s', '')
    if str == '' or str == 'off' or str == 'none' then return '' end
    for _, c in ipairs(chars) do if c.name_lower:sub(1, #str) == str then return c.name_lower end end
    return nil
end

-- Live (main, sub) job ids for a healer name -- drives which stance toggles are
-- shown. 0 = unknown (out of zone / unread); then both stances are offered.
local function healer_job(nm)
    nm = (nm or ''):lower()
    for _, c in ipairs(chars) do if c.name_lower == nm then return c.job or 0, c.sjob or 0 end end
    return 0, 0
end

-- UI buffers. adv_crew_buf mirrors crew names; adv_h mirrors each healer slot.
local adv_crew_buf = {}
for i = 1, #chars do adv_crew_buf[i] = {chars[i].name} end
local adv_h = {}
for sN = 1, #config.healers do
    local b = { name = {''}, na = {false}, solace = {false}, arts = {false}, majesty = {false}, ds = {false}, dsthresh = {'40'},
                haste1 = {false},
                reraise = {false}, reraisespell = {'Reraise'},
                silence = {false}, silenceitem = {'Echo Drops'}, silencegap = {'15'}, cure = {}, curaga = {} }
    for t = 1, 6 do b.cure[t]   = {'0'} end
    for t = 1, 5 do b.curaga[t] = {'0'} end
    -- WHM-main extras buffers (MM:SS strings + per-spell name where applicable)
    b.extras = {
        protectra_en = {false}, protectra_t = {'28:20'},
        shellra_en   = {false}, shellra_t   = {'28:20'},
        auspice_en   = {false}, auspice_t   = {'2:50'},
        boost_en     = {false}, boost_t     = {'4:40'}, boost_sp = {'Boost-STR'},
        barel_en     = {false}, barel_t     = {'2:50'}, barel_sp = {'Barfire'},
        barst_en     = {false}, barst_t     = {'2:50'}, barst_sp = {'Barsleep'},
        regen_en     = {false}, regen_t     = {'1:30'}, regen_sp = {'Regen IV'},
    }
    adv_h[sN] = b
end

-- (Re)seed every buffer from live config -- on panel open and on settings reload.
local function adv_reseed()
    for i = 1, #chars do if adv_crew_buf[i] then adv_crew_buf[i][1] = chars[i].name end end
    for sN = 1, #config.healers do
        local h, b = config.healers[sN], adv_h[sN]
        if h and b then
            b.name[1]   = h.name or ''
            b.na[1]     = h.na and true or false
            b.solace[1] = h.solace and true or false
            b.arts[1]   = h.arts and true or false
            b.majesty[1]     = h.majesty and true or false
            b.haste1[1]      = h.haste1 and true or false
            b.ds[1]          = h.ds and true or false
            b.dsthresh[1]    = tostring(h.dsthresh or 40)
            b.reraise[1]      = h.reraise and true or false
            b.reraisespell[1] = h.reraisespell or 'Reraise'
            b.silence[1]     = h.silence and true or false
            b.silenceitem[1] = h.silenceitem or 'Echo Drops'
            b.silencegap[1]  = tostring(h.silencegap or 15)
            for t = 1, 6 do b.cure[t][1]   = tostring((h.cure   and h.cure[t])   or 0) end
            for t = 1, 5 do b.curaga[t][1] = tostring((h.curaga and h.curaga[t]) or 0) end
            -- Extras: enabled flags + MM:SS-formatted recasts + spell names.
            -- Missing extras block (legacy config) falls back to defaults so
            -- the UI never sees nil; commit_all writes the structure back.
            local x = h.extras or {}
            local be = b.extras
            local function seed(key, dflt_recast)
                local e = x[key] or {}
                be[key .. '_en'][1] = e.enabled and true or false
                be[key .. '_t'][1]  = geo_mod.fmt_mmss(e.recast or dflt_recast)
                return e
            end
            seed('protectra', 1700)
            seed('shellra',   1700)
            seed('auspice',   170)
            be.boost_sp[1] = (seed('boost', 280).spell) or 'Boost-STR'
            be.barel_sp[1] = (seed('barel', 170).spell) or 'Barfire'
            be.barst_sp[1] = (seed('barst', 170).spell) or 'Barsleep'
            be.regen_sp[1] = (seed('regen', 90).spell)  or 'Regen IV'
        end
    end
    ADV_WINDOW_OPEN[1] = true
end

-- One per-tier numeric cell. Commits on Enter OR when focus leaves the cell;
-- 0 disables the tier. (The Save button also flushes every cell -- see below.)
local function tier_cell(tag, buf, set)
    igSameLine(0, 4); imgui.SetNextItemWidth(40)
    local done = imgui.InputText(tag, buf, 6, NUM_INPUT_FLAGS)
    if not done and imgui.IsItemDeactivatedAfterEdit then done = imgui.IsItemDeactivatedAfterEdit() end
    if done then
        local n = tonumber(buf[1]) or 0
        if n < 0 then n = 0 elseif n > 100 then n = 100 end
        set(n); settings.save(); buf[1] = tostring(n)
    end
end

-- Flush ALL Advanced-panel buffers into config so they can be persisted. Cells
-- normally commit on Enter / focus-loss, but the Save button calls this first so
-- any value typed-but-not-yet-committed is still captured before the file write.
local function adv_commit_all()
    for i = 1, #chars do
        if adv_crew_buf[i] then rename_crew(i, adv_crew_buf[i][1]); adv_crew_buf[i][1] = chars[i].name end
    end
    for sN = 1, #config.healers do
        local h, b = config.healers[sN], adv_h[sN]
        if h and b then
            local r = resolve_healer_field(b.name[1]); if r ~= nil then h.name = r end
            b.name[1] = h.name
            h.na      = b.na[1] and true or false
            h.solace  = b.solace[1] and true or false
            h.arts    = b.arts[1] and true or false
            h.majesty = b.majesty[1] and true or false
            h.haste1  = b.haste1[1] and true or false
            h.ds      = b.ds[1] and true or false
            local dt = tonumber(b.dsthresh[1]); if dt then if dt < 0 then dt = 0 elseif dt > 100 then dt = 100 end h.dsthresh = dt end
            b.dsthresh[1] = tostring(h.dsthresh or 40)
            h.reraise = b.reraise[1] and true or false
            h.reraisespell = (b.reraisespell[1] ~= '' and b.reraisespell[1]) or 'Reraise'
            b.reraisespell[1] = h.reraisespell
            h.silence = b.silence[1] and true or false
            h.silenceitem = (b.silenceitem[1] ~= '' and b.silenceitem[1]) or 'Echo Drops'
            b.silenceitem[1] = h.silenceitem
            local g = tonumber(b.silencegap[1]); if g and g >= 0 then h.silencegap = g end
            b.silencegap[1] = tostring(h.silencegap or 15)
            for t = 1, 6 do
                local n = tonumber(b.cure[t][1])
                if n then if n < 0 then n = 0 elseif n > 100 then n = 100 end h.cure[t] = n end
                b.cure[t][1] = tostring(h.cure[t] or 0)
            end
            for t = 1, 5 do
                local n = tonumber(b.curaga[t][1])
                if n then if n < 0 then n = 0 elseif n > 100 then n = 100 end h.curaga[t] = n end
                b.curaga[t][1] = tostring(h.curaga[t] or 0)
            end
            -- Extras flush. Ensure the structure exists (legacy configs).
            h.extras = h.extras or T{}
            local function flush(key, dflt_recast, spell_default)
                h.extras[key] = h.extras[key] or T{}
                local be, e = b.extras, h.extras[key]
                e.enabled = be[key .. '_en'][1] and true or false
                local secs = geo_mod.parse_mmss(be[key .. '_t'][1])
                if secs and secs >= 0 then e.recast = secs end
                be[key .. '_t'][1] = geo_mod.fmt_mmss(e.recast or dflt_recast)
                if spell_default then
                    local sp_buf = be[key .. '_sp']
                    if sp_buf then
                        local nm = (sp_buf[1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
                        e.spell = (nm ~= '' and nm) or spell_default
                        sp_buf[1] = e.spell
                    end
                end
            end
            flush('protectra', 1700, nil)
            flush('shellra',   1700, nil)
            flush('auspice',   170,  nil)
            flush('boost',     280, 'Boost-STR')
            flush('barel',     170, 'Barfire')
            flush('barst',     170, 'Barsleep')
            flush('regen',     90,  'Regen IV')
        end
    end
end

local ROMAN = {'I','II','III','IV','V','VI'}

ashita.events.register('d3d_present', 'render_advanced', function()
    if not show_advanced then return end
    if not adv_seeded then adv_reseed(); adv_seeded = true end

    igSetNextWindowBgAlpha(0.65)
    if igBegin('Sync - Advanced', ADV_WINDOW_OPEN, ADV_WINDOW_FLAGS) then
        igTextColored(COLOR_GUEST, 'Crew / Healing')
        tip('Crew roster + per-healer kit. Hover any field for details.')
        geo_mod.right_align(18)
        imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
        imgui.PushStyleColor(ImGuiCol_Text, COLOR_OFFLINE)
        if igSmallButton('x##advclose') then show_advanced = false; adv_seeded = false end
        imgui.PopStyleColor(4)
        tip('Close (or click Heal: in the main HUD)')
        igTextDisabled('Enter commits text fields; Save flushes all & writes settings.')
        imgui.Separator()
        igText('Crew')
        tip('Box names by slot. Slot 1 is the main (running sync); slot 2 owns the RDM.')
        for i = 1, #chars do
            local role = chars[i].is_main and ' (main)' or (chars[i].is_rdm and ' (rdm)' or '')
            imgui.SetNextItemWidth(120)
            if imgui.InputText('slot ' .. i .. role .. '##crew' .. i, adv_crew_buf[i], 32, ImGuiInputTextFlags_EnterReturnsTrue) then
                rename_crew(i, adv_crew_buf[i][1])
                adv_crew_buf[i][1] = chars[i].name
            end
            tip('Crew slot ' .. i .. role .. ' - character name (press Enter to commit)')
        end

        imgui.Separator()
        igTextDisabled('BRD box: configure in the Bard window (click "BRD:" in the main HUD, or /sync brd).')

        if igSmallButton('Combat##opencombat') then hunt_mod.show_panel = not hunt_mod.show_panel end
        tip('Open the Combat panel: per-box face-lock + radius pack-hunting (/sync combat)')

        for sN = 1, #config.healers do
            local h, b = config.healers[sN], adv_h[sN]
            imgui.Separator()
            igText((sN == 1 and 'Primary' or 'Backup') .. ' healer')
            tip(sN == 1
                and 'Primary healer slot - any healing-capable crew box.'
                or  'Backup healer slot - runs concurrently with the primary; cross-claim prevents double-curing the same target.')
            imgui.SetNextItemWidth(110)
            if imgui.InputText('name##h' .. sN, b.name, 32, ImGuiInputTextFlags_EnterReturnsTrue) then
                local r = resolve_healer_field(b.name[1])
                if r ~= nil then h.name = r; settings.save() end
                b.name[1] = h.name
            end
            tip('Healer character (prefix match against crew). Type "off" to disable this slot.')
            igSameLine(0, 12)
            if igCheckbox('-na##na' .. sN, b.na) then h.na = b.na[1]; settings.save() end
            tip('Status removal: cast Poisona / Paralyna / Blindna / Silena / Stona / Viruna / Cursna / Erase as needed.')

            local mj, sj = healer_job(h.name)
            local hl = (h.name or ''):lower()
            local show_solace  = (mj == 0 or mj == JOB_WHM)
            local show_arts    = (mj == 0 or mj == JOB_SCH or sj == JOB_SCH)
            local show_majesty = (mj == 0 or mj == JOB_PLD)
            local show_ds = (mj == 0 or mj == JOB_WHM or sj == JOB_WHM)
            local show_reraise = (mj == 0) or (mj == JOB_WHM) or (mj == JOB_SCH) or (sj == JOB_WHM) or (sj == JOB_SCH)
            local show_haste1  = (mj == 0 or mj == JOB_WHM)   -- WHM Haste monitor (healer-menu toggle, not a WHM extra)
            local shown = false
            if show_solace then
                if igCheckbox('Solace##sol' .. sN, b.solace) then
                    h.solace = b.solace[1]; settings.save()
                    if not h.solace then for _, c in ipairs(chars) do if c.name_lower == hl then c.solace_lock = 0 end end end
                end
                tip('Afflatus Solace - WHM cure-potency stance. Maintained while up.')
                shown = true
            end
            if show_arts then
                if shown then igSameLine(0, 12) end
                if igCheckbox('Arts##art' .. sN, b.arts) then
                    h.arts = b.arts[1]; settings.save()
                    if not h.arts then for _, c in ipairs(chars) do if c.name_lower == hl then c.larts_lock = 0; c.addw_lock = 0 end end end
                end
                tip('Light Arts + Addendum: White - /SCH white-magic gate (required for /SCH -na and Reraise).')
                shown = true
            end
            if show_majesty then
                if shown then igSameLine(0, 12) end
                if igCheckbox('Majesty##maj' .. sN, b.majesty) then
                    h.majesty = b.majesty[1]; settings.save()
                    if not h.majesty then for _, c in ipairs(chars) do if c.name_lower == hl then c.majesty_lock = 0; c.majesty_cast = 0 end end end
                end
                tip('PLD Majesty - 180s Cure potency + AoE stance. Refreshed automatically.')
                shown = true
            end
            if show_ds then
                if shown then igSameLine(0, 12) end
                if igCheckbox('D.Seal##ds' .. sN, b.ds) then
                    h.ds = b.ds[1]; settings.save()
                    if not h.ds then for _, c in ipairs(chars) do if c.name_lower == hl then c.ds_lock = 0 end end end
                end
                tip('Divine Seal - WHM cure-potency burst (any WHM source). Pops at the HP prcnt to the right.')
                if h.ds then
                    tier_cell('HP%##dsth' .. sN, b.dsthresh, function(n) h.dsthresh = n end)
                    tip('Divine Seal trigger: worst-HP-prcnt at-or-below this number fires DS + the boosted heal.')
                end
                shown = true
            end
            if show_haste1 then
                if shown then igSameLine(0, 12) end
                if igCheckbox('Haste##h1' .. sN, b.haste1) then
                    h.haste1 = b.haste1[1]; settings.save()
                end
                tip('Cast Haste on any Cure-flagged member missing it. Haste/Haste II share the same buff, so an already-hasted member is skipped. Gated like cures (per-target gap + cross-healer claim).')
                shown = true
            end

            if igCheckbox('Silena##sil' .. sN, b.silence) then h.silence = b.silence[1]; settings.save() end
            tip('Self-silence recovery via an item (default Echo Drops). Used when this healer is silenced and cannot cast.')
            igSameLine(0, 8); imgui.SetNextItemWidth(110)
            if imgui.InputText('item##silitem' .. sN, b.silenceitem, 32, ImGuiInputTextFlags_EnterReturnsTrue) then
                h.silenceitem = b.silenceitem[1]; settings.save()
            end
            tip('Item name to use when silenced (must match the inventory item exactly).')
            igSameLine(0, 8); imgui.SetNextItemWidth(46)
            if imgui.InputText('gap##silgap' .. sN, b.silencegap, 6, NUM_INPUT_FLAGS) then
                local n = tonumber(b.silencegap[1]) or 15
                if n < 0 then n = 0 end
                h.silencegap = n; settings.save(); b.silencegap[1] = tostring(n)
            end
            tip('Retry delay between Silence-recovery item uses (seconds).')

            if show_reraise then
                if igCheckbox('Reraise##rr' .. sN, b.reraise) then
                    h.reraise = b.reraise[1]; settings.save()
                    if not h.reraise then for _, c in ipairs(chars) do if c.name_lower == hl then c.reraise_lock = 0; c.reraise_fails = 0 end end end
                end
                tip('Auto-cast Reraise on self when missing. /SCH waits for Addendum: White.')
                igSameLine(0, 8); imgui.SetNextItemWidth(90)
                if imgui.InputText('spell##rrsp' .. sN, b.reraisespell, 24, ImGuiInputTextFlags_EnterReturnsTrue) then
                    h.reraisespell = (b.reraisespell[1] ~= '' and b.reraisespell[1]) or 'Reraise'
                    settings.save(); b.reraisespell[1] = h.reraisespell
                    for _, c in ipairs(chars) do if c.name_lower == hl then c.reraise_fails = 0 end end
                end
                tip('Reraise spell name (Reraise / Reraise II / Reraise III / Reraise IV).')
            end

            igText('Cure')
            tip('Per-tier HP% trigger for Cure I-VI. 0 disables that tier. Highest enabled tier also acts as the heal-gate.')
            for t = 1, 6 do
                tier_cell('##h' .. sN .. 'cu' .. t, b.cure[t], function(n) h.cure[t] = n end)
                tip('Cure ' .. ROMAN[t] .. ' - fires when target HP% <= this. 0 = off.')
            end
            igText('Curaga')
            tip('Per-tier HP% trigger for Curaga I-V. Curaga only heals the caster\'s own party. 0 disables a tier.')
            for t = 1, 5 do
                tier_cell('##h' .. sN .. 'cg' .. t, b.curaga[t], function(n) h.curaga[t] = n end)
                tip('Curaga ' .. ROMAN[t] .. ' - fires when worst-HP% in caster\'s party <= this. 0 = off.')
            end
            -- min injured-in-party targets to prefer Curaga over single Cure (per-healer, 2..6)
            igSameLine(0, 12); igText('min')
            tip('Minimum injured party members required before Curaga is preferred over single Cure.')
            igSameLine(0, 3)
            if igSmallButton('-##cgm' .. sN) then
                local v = (h.curagamin or 2); if v > 2 then h.curagamin = v - 1; settings.save() end
            end
            tip('Decrease min injured (2-6)')
            igSameLine(0, 3); igText(tostring(h.curagamin or 2))
            igSameLine(0, 3)
            if igSmallButton('+##cgm' .. sN) then
                local v = (h.curagamin or 2); if v < 6 then h.curagamin = v + 1; settings.save() end
            end
            tip('Increase min injured (2-6)')

            -- WHM-MAIN PROACTIVE EXTRAS (Protectra V / Shellra V / Auspice /
            -- Boost-X / Bar-Element / Bar-Status / Accession+Regen monitor).
            -- Only rendered when the slot's main job is WHM (or unread = 0;
            -- lets you set things up before the box loads). Each row is one
            -- checkbox + an MM:SS interval; the 4 spell-name rows add a text
            -- field. The fire pipeline lives in geo_mod.whm_extras_pass.
            if h.extras and (mj == JOB_WHM or mj == 0) then
                imgui.Separator()
                igTextColored(COLOR_GUEST, 'WHM extras (timer-driven)')
                tip('Proactive party buffs + AoE Regen monitor. WHM main only. Each row fires at most one cast per cycle; the interval is the MM:SS gap between auto-casts (set under each buff\'s natural wear-off to refresh in time).')
                local be = b.extras

                -- Reusable inline cells for this block. They commit on Enter
                -- OR focus-loss so values land without needing the Save button.
                local function ck(label, key, tip_str)
                    if igCheckbox(label .. '##wx' .. sN .. key, be[key .. '_en']) then
                        h.extras[key] = h.extras[key] or T{}
                        h.extras[key].enabled = be[key .. '_en'][1] and true or false
                        settings.save()
                    end
                    if tip_str then tip(tip_str) end
                end
                local function mmss(key, dflt_recast, tip_str)
                    igSameLine(0, 6); igText('every'); igSameLine(0, 4)
                    imgui.SetNextItemWidth(50)
                    local tag = '##wx' .. sN .. key .. 't'
                    local done = imgui.InputText(tag, be[key .. '_t'], 8, ImGuiInputTextFlags_EnterReturnsTrue)
                    if not done and imgui.IsItemDeactivatedAfterEdit then done = imgui.IsItemDeactivatedAfterEdit() end
                    if done then
                        local secs = geo_mod.parse_mmss(be[key .. '_t'][1]) or dflt_recast
                        if secs < 0 then secs = 0 end
                        h.extras[key] = h.extras[key] or T{}
                        h.extras[key].recast = secs
                        settings.save()
                        be[key .. '_t'][1] = geo_mod.fmt_mmss(secs)
                    end
                    if tip_str then tip(tip_str) end
                end
                local function spell_field(key, dflt_spell, w, tip_str)
                    igSameLine(0, 6); imgui.SetNextItemWidth(w or 110)
                    local tag = '##wx' .. sN .. key .. 'sp'
                    if imgui.InputText(tag, be[key .. '_sp'], 32, ImGuiInputTextFlags_EnterReturnsTrue) then
                        local nm = (be[key .. '_sp'][1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
                        h.extras[key] = h.extras[key] or T{}
                        h.extras[key].spell = (nm ~= '' and nm) or dflt_spell
                        settings.save()
                        be[key .. '_sp'][1] = h.extras[key].spell
                        -- reset last-cast so a new spell fires next cycle
                        for _, c in ipairs(chars) do
                            if c.name_lower == (h.name or ''):lower() and c.extra_last then
                                c.extra_last[key] = 0
                            end
                        end
                    end
                    if tip_str then tip(tip_str) end
                end

                ck('Protectra V', 'protectra', 'Cast Protectra V on self (party-AoE Protect V).')
                mmss('protectra', 1700, 'Recast interval (MM:SS). 28:20 default refreshes the 30min buff before it drops.')

                ck('Shellra V',   'shellra',   'Cast Shellra V on self (party-AoE Shell V).')
                mmss('shellra',   1700, 'Recast interval (MM:SS). 28:20 default refreshes the 30min buff before it drops.')

                ck('Auspice',     'auspice',   'Cast Auspice on self (party-AoE Subtle Blow / Light damage on attacks, ~3min).')
                mmss('auspice',   170,  'Recast interval (MM:SS). 2:50 default refreshes the 3min buff before it drops.')

                ck('Boost-stat',  'boost',     'Cast a Boost-X spell on self (5min self stat boost).')
                mmss('boost',     280,  'Recast interval (MM:SS). 4:40 default refreshes the 5min buff before it drops.')
                spell_field('boost', 'Boost-STR', 110, 'Spell name (e.g. Boost-STR, Boost-MND, Boost-DEX). Edits commit on Enter.')

                ck('Bar-Element', 'barel',     'Cast a Bar-Element spell (Barfira, Barblizzara, ...). Use the -ra tier for party-AoE.')
                mmss('barel',     170,  'Recast interval (MM:SS). 2:50 default refreshes the 3min buff before it drops.')
                spell_field('barel', 'Barfire', 110, 'Spell name (e.g. Barfira, Barblizzara, Barthundra). Edits commit on Enter.')

                ck('Bar-Status',  'barst',     'Cast a Bar-Status spell (Barsleepra, Barpoisonra, ...). Use the -ra tier for party-AoE.')
                mmss('barst',     170,  'Recast interval (MM:SS). 2:50 default refreshes the 3min buff before it drops.')
                spell_field('barst', 'Barsleep', 110, 'Spell name (e.g. Barsleepra, Barparalyzra, Barsilencera). Edits commit on Enter.')

                ck('Regen monitor', 'regen',   'Accession + Regen on cycle (party-AoE Regen via Accession). Reserves the healer for the cast so a normal Cure cannot consume the Accession charge.')
                mmss('regen',     90,   'Cycle interval (MM:SS) between Accession+Regen pulses. 1:30 default.')
                spell_field('regen', 'Regen IV', 90, 'Regen tier (Regen II / III / IV / V). Edits commit on Enter.')
            end
        end

        imgui.Separator()
        if imgui.Button('Save config to file') then
            adv_commit_all(); settings.save(); broadcast_roster()
            print('[sync] config saved to file')
        end
        tip('Flush every text field into config and write the settings file (also re-pushes the crew roster to rdmhelper boxes).')
    end
    igEnd()

    if not ADV_WINDOW_OPEN[1] then show_advanced = false; adv_seeded = false end
end)

------------------------------------------------------------
-- RDM BUFF CONTROLS PANEL
------------------------------------------------------------
-- Per-member control surface for every buff the RDM can cast. Each row's master
-- 'Buff' is the same session gate as the HUD Buff column (wiped on zone, re-armed
-- by /sync on); the per-buff checkboxes are durable preferences layered under it.
-- Haste and Flurry share one slot and are mutually exclusive - checking one clears the other.
-- Cross-party members simply won't receive party-only spells (Refresh III / Phalanx) until co-partied.
-- GUESTS (non-crew rows) only show Buff / Haste / Flurry - Refresh / Protect /
-- Shell / Phalanx are '-' for them (party-only or long-cycle, user handles manually).
-- UNREADABLE targets (cross-party + no rdmhelper report) get a 6min retry gap
-- instead of 15s so the buff cycle isn't spammed at a target we can't verify.
local BUFF_PANEL_OPEN  = {true}
local BUFF_PANEL_FLAGS = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)
local BUFF_TBL_FLAGS   = bit.bor(ImGuiTableFlags_SizingFixedFit or 0,
                                 ImGuiTableFlags_BordersInnerV  or 0,
                                 ImGuiTableFlags_RowBg          or 0)

local function buff_row(t, col)
    igTableNextRow(); igTableNextColumn()
    local nc = (not t.in_zone) and COLOR_OFFLINE or col
    if nc then igTextColored(nc, t.disp_name) else igText(t.disp_name) end
    if igIsItemHovered() then
        local role = t.is_main and ' (main)' or (t.is_rdm and ' (RDM)' or (col == COLOR_GUEST and ' (guest)' or ''))
        igSetTooltip(t.name .. role .. (t.in_zone and '' or ' - offline'))
    end

    igTableNextColumn(); igCheckbox(t.buff_ids.buf, t.buf)
    if igIsItemHovered() then
        igSetTooltip('Master gate - cast ANY buff on this member (session flag, wiped on zone).  -  ' .. t.name)
    end

    -- Haste / Flurry: enforce mutual exclusivity and lock RDM Haste
    igTableNextColumn()
    if t.is_rdm then
        t.bh[1] = true
        if igBeginDisabled then igBeginDisabled(true) end
        igCheckbox(t.buff_ids.bh, t.bh)
        if igEndDisabled then igEndDisabled() end
    else
        if igCheckbox(t.buff_ids.bh, t.bh) then
            if t.bh[1] and t.fl then t.fl[1] = false end
        end
    end
    if igIsItemHovered() then
        igSetTooltip('Cast Haste II on this member (Haste / Flurry are mutually exclusive).  -  '
            .. t.name .. (t.is_rdm and ' (RDM: forced ON)' or ''))
    end

    igTableNextColumn()
    if igCheckbox(t.buff_ids.fl, t.fl) then
        if t.fl[1] and t.bh then t.bh[1] = false end
    end
    if igIsItemHovered() then
        igSetTooltip('Cast Flurry II on this member (Haste / Flurry are mutually exclusive).  -  ' .. t.name)
    end
	
    local is_guest = (col == COLOR_GUEST)

    -- Refresh
    igTableNextColumn()
    if is_guest then
        igTextDisabled("-")
        if igIsItemHovered() then igSetTooltip('Refresh - not cast on guests (party-only spell, manual if needed).  -  ' .. t.name) end
    elseif t.is_rdm then
        t.ref[1] = true
        if igBeginDisabled then igBeginDisabled(true) end
        igCheckbox(t.buff_ids.ref, t.ref)
        if igEndDisabled then igEndDisabled() end
        if igIsItemHovered() then
            igSetTooltip('Cast Refresh III on this member (same-party only; RDM is forced ON).  -  '
                .. t.name .. ' (RDM: forced ON)')
        end
    else
        igCheckbox(t.buff_ids.ref, t.ref)
        if igIsItemHovered() then
            igSetTooltip('Cast Refresh III on this member (same-party only).  -  ' .. t.name)
        end
    end

    -- Protect
    igTableNextColumn()
    if is_guest then
        igTextDisabled("-")
        if igIsItemHovered() then igSetTooltip('Protect - not cast on guests (long-cycle buff handled manually if needed).  -  ' .. t.name) end
    else
        igCheckbox(t.buff_ids.bpro, t.bpro)
        if igIsItemHovered() then igSetTooltip('Cast Protect V on this member.  -  ' .. t.name) end
    end

    -- Shell
    igTableNextColumn()
    if is_guest then
        igTextDisabled("-")
        if igIsItemHovered() then igSetTooltip('Shell - not cast on guests (long-cycle buff handled manually if needed).  -  ' .. t.name) end
    else
        igCheckbox(t.buff_ids.bsh, t.bsh)
        if igIsItemHovered() then igSetTooltip('Cast Shell V on this member.  -  ' .. t.name) end
    end

    -- Phalanx
    igTableNextColumn()
    if is_guest then
        igTextDisabled("-")
        if igIsItemHovered() then igSetTooltip('Phalanx - not cast on guests (party-only spell, manual if needed).  -  ' .. t.name) end
    else
        igCheckbox(t.buff_ids.bp, t.bp)
        if igIsItemHovered() then igSetTooltip('Cast Phalanx / Phalanx II on this member.  -  ' .. t.name) end
    end
end

------------------------------------------------------------
-- COMBAT PANEL (face-lock + radius pack-hunting)
------------------------------------------------------------
-- Per-box Face / Hunt toggles plus a mob whitelist per box. Empty whitelist =>
-- that box hunts ANY valid mob inside the radius; pack-hunting spreads the crew
-- across distinct mobs and only doubles up (on the highest-HP mob) when there
-- are fewer mobs than hunters. Radius + whitelists persist; Face/Hunt reset on
-- zone with the other combat flags.
local function combat_addbuf(nl)
    local b = hunt_mod.addbuf[nl]
    if not b then b = { '' }; hunt_mod.addbuf[nl] = b end
    return b
end

ashita.events.register('d3d_present', 'render_combatpanel', function()
    if not hunt_mod.show_panel then return end
    igSetNextWindowBgAlpha(0.65)
    hunt_mod.open[1] = true
    if igBegin('Sync - Combat', hunt_mod.open, hunt_mod.flags) then
        igTextColored(COLOR_GUEST, 'Combat / Hunt')
        tip('Per-box face-lock + radius pack-hunting. Empty whitelist = any mob in radius.')
        geo_mod.right_align(18)
        imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
        imgui.PushStyleColor(ImGuiCol_Text, COLOR_OFFLINE)
        if igSmallButton('x##combatclose') then hunt_mod.show_panel = false end
        imgui.PopStyleColor(4)
        tip('Close (or /sync combat)')

        imgui.SetNextItemWidth(140)
        if imgui.SliderFloat('radius (yalms)##cradius', hunt_mod.radius_buf, 3.0, 30.0, '%.0f') then
            config.combat.radius = hunt_mod.radius_buf[1]
            settings.save()
        end
        tip('Acquisition radius (per box). Mobs beyond this are ignored.')
        igTextDisabled('Pull distance and fight (leash) range are now PER-CHARACTER -- set below, per box.')

        if not hunt_mod.rdiabuf then hunt_mod.rdiabuf = { config.combat.rdm_dia or '' } end
        imgui.SetNextItemWidth(240)
        local rdia_done = imgui.InputText('RDM hunt-debuff##rdmdia', hunt_mod.rdiabuf, 64, ImGuiInputTextFlags_EnterReturnsTrue)
        if not rdia_done and imgui.IsItemDeactivatedAfterEdit then rdia_done = imgui.IsItemDeactivatedAfterEdit() end
        if rdia_done then
            config.combat.rdm_dia = hunt_mod.rdiabuf[1] or ''
            settings.save()
        end
        tip('Command the RDM casts once on each newly-engaged mob. Use <t>, e.g. /ma \"Dia III\" <t> or an alias like //dia3 <t>. Empty = off.')
        imgui.Separator()

        if igSmallButton('Set Camp##campset') then hunt_mod.camp_set() end
        tip('Save the main\'s current position as the campsite (/sync camp set).')
        igSameLine(0, 6)
        if igSmallButton('Return##campgo') then hunt_mod.camp_go() end
        tip('Send the crew back to the saved campsite (/sync camp). Experimental movement.')
        if config.combat.camp_set then
            igSameLine(0, 8)
            igTextDisabled(string.format('(%.0f, %.0f)', config.combat.camp_x or 0, config.combat.camp_y or 0))
        end
        if (hunt_mod.yaw_off or 0) ~= 0 then
            igSameLine(0, 8)
            igTextDisabled(string.format('face yaw: %.3f', hunt_mod.yaw_off))
            tip('Saved face-calibration offset (persists across reloads). /sync faced reset to clear.')
        end

        igText('Blacklist (never hunt):')
        tip('Mob names here are never hunted by any box.')
        local BL = config.combat.blacklist
        if #BL > 0 then
            for i = #BL, 1, -1 do
                if igSmallButton('x##bl' .. i) then
                    t_remove(BL, i); settings.save()
                else
                    igSameLine(0, 4); igTextDisabled(BL[i]); igSameLine(0, 10)
                end
            end
            igText('')
        end
        imgui.SetNextItemWidth(150)
        if imgui.InputText('##bladd', hunt_mod.blbuf, 48, ImGuiInputTextFlags_EnterReturnsTrue) then
            local nm = (hunt_mod.blbuf[1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
            if nm ~= '' then t_insert(BL, nm); settings.save() end
            hunt_mod.blbuf[1] = ''
        end
        tip('Add a mob name to the global blacklist (Enter).')
        imgui.Separator()

        for _, c in ipairs(chars) do
            local role = c.is_main and ' (main)' or (c.is_rdm and ' (rdm)' or '')
            igText(c.disp_name .. role)
            tip('Box: ' .. c.name)
            igSameLine(0, 10)
            if igCheckbox('Face##face' .. c.name_lower, c.face) then c.face_sent = nil end
            tip('Face-lock: turn this box to face its target while engaged (writes actor heading).')
            igSameLine(0, 8)
            local hm_cur = config.combat.huntmode[c.name_lower] or 0
            local hm_lbl = (hm_cur == 2 and 'Converge') or (hm_cur == 1 and 'Hunt') or 'Hunt:Off'
            if igSmallButton(hm_lbl .. '##hm' .. c.name_lower) then
                local nxt = (hm_cur + 1) % 3
                config.combat.huntmode[c.name_lower] = nxt
                c.hunt[1] = (nxt > 0)
                settings.save()
            end
            tip('Hunt mode -- click to cycle: Hunt:Off / Hunt (box picks its own distinct mob) / Converge (all Converge boxes share the same highest-HP mob in radius). Mix Hunt + Converge freely per box.')
            if not c.is_main then
                igSameLine(0, 8)
                igCheckbox('Run##run' .. c.name_lower, c.runto)
                tip('Run to mob: move this box to its assigned mob (suppresses follow). Experimental.')
                local rm = config.combat.retmode[c.name_lower] or 0
                local rlbl = (rm == 1 and 'Ret:Claim') or (rm == 2 and 'Ret:Death') or 'Ret:Off'
                igSameLine(0, 8)
                if igSmallButton(rlbl .. '##ret' .. c.name_lower) then
                    config.combat.retmode[c.name_lower] = (rm + 1) % 3
                    settings.save()
                end
                tip('Return to camp -- click to cycle: Off / Claim (drag each claimed mob back to camp) / Death (return to camp after the mob dies). Needs a campsite set.')
            end

            local pb = hunt_mod.pullbuf[c.name_lower]
            if not pb then pb = { hunt_mod.pull_cmd(c) }; hunt_mod.pullbuf[c.name_lower] = pb end
            imgui.SetNextItemWidth(220)
            -- FIX: EnterReturnsTrue alone only commits if the user presses Enter
            -- while the field is focused. Clicking away (e.g. straight to the Hunt
            -- mode button) silently discarded whatever was typed -- pull_cmd kept
            -- returning '' forever, so the pull condition (pc ~= '') never passed
            -- and the configured pull command never fired. IsItemDeactivatedAfterEdit
            -- also commits on focus-loss after an edit, closing that gap.
            local pull_done = imgui.InputText('pull##pull' .. c.name_lower, pb, 64, ImGuiInputTextFlags_EnterReturnsTrue)
            if not pull_done and imgui.IsItemDeactivatedAfterEdit then pull_done = imgui.IsItemDeactivatedAfterEdit() end
            if pull_done then
                config.combat.pull[c.name_lower] = pb[1] or ''
                settings.save()
            end
            tip('Pull action fired once per newly-acquired mob to draw it into range. Use <t>, e.g. /ma \"Dia III\" <t>  |  /ra <t>  |  /ja \"Sic\" <t>. Empty = none.\nMust be a command this box\'s OWN client recognizes -- a personal alias (e.g. /dia2) only works if that alias is defined on this box\'s Ashita install.')

            local pdb = hunt_mod.pulldistbuf[c.name_lower]
            if not pdb then pdb = { config.combat.pull_dist[c.name_lower] or 20.0 }; hunt_mod.pulldistbuf[c.name_lower] = pdb end
            imgui.SetNextItemWidth(150)
            if imgui.SliderFloat('pull dist##pulldist' .. c.name_lower, pdb, 3.0, 30.0, '%.0f') then
                config.combat.pull_dist[c.name_lower] = pdb[1]
                settings.save()
            end
            tip('This box only fires its pull command when within this many yalms of the mob.')

            if not c.is_main then
                local frb = hunt_mod.frangbuf[c.name_lower]
                if not frb then frb = { config.combat.fight_range[c.name_lower] or 3.5 }; hunt_mod.frangbuf[c.name_lower] = frb end
                imgui.SameLine(0, 12)
                imgui.SetNextItemWidth(150)
                if imgui.SliderFloat('fight range##frange' .. c.name_lower, frb, 1.0, 25.0, '%.1f') then
                    config.combat.fight_range[c.name_lower] = frb[1]
                    settings.save()
                end
                tip('Max yalms this box will let the mob drift before walking back in. Set tight (~3.5-4.9y) for melee so it never falls out of WS/melee range. Set generously for ranged/mages so they hold position instead of closing in.')
            end

            local L = hunt_mod.list(c)
            if #L > 0 then
                for i = #L, 1, -1 do
                    if igSmallButton('x##del' .. c.name_lower .. i) then
                        t_remove(L, i); settings.save()
                    else
                        igSameLine(0, 4); igTextDisabled(L[i]); igSameLine(0, 10)
                    end
                end
                igText('')
            end

            local b = combat_addbuf(c.name_lower)
            imgui.SetNextItemWidth(150)
            if imgui.InputText('##add' .. c.name_lower, b, 48, ImGuiInputTextFlags_EnterReturnsTrue) then
                local nm = (b[1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
                if nm ~= '' then t_insert(L, nm); settings.save() end
                b[1] = ''
            end
            tip('Add a mob name to this box\'s whitelist (Enter). Leave the list empty to hunt anything.')
            imgui.Separator()
        end
    end
    igEnd()
    if not hunt_mod.open[1] then hunt_mod.show_panel = false end
end)

ashita.events.register('d3d_present', 'render_buffpanel', function()
    if not show_buffpanel then return end
    igSetNextWindowBgAlpha(0.55)
    BUFF_PANEL_OPEN[1] = true
    if igBegin('RDM Buff Controls', BUFF_PANEL_OPEN, BUFF_PANEL_FLAGS) then
        igTextColored(COLOR_GUEST, 'RDM Buff Controls')
        tip('Per-member RDM buff toggles. Hover any cell for what it does.')
        geo_mod.right_align(18)
        imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
        imgui.PushStyleColor(ImGuiCol_Text, COLOR_OFFLINE)
        if igSmallButton('x##buffclose') then show_buffpanel = false end
        imgui.PopStyleColor(4)
        tip('Close (or click "buf" in the main HUD, or /sync panel)')
        if igBeginTable('RdmBuffTable', 8, BUFF_TBL_FLAGS) then
            igTableSetupColumn('Member',  0, 0)
            igTableSetupColumn('Buff',    0, 0)
            igTableSetupColumn('Haste',   0, 0)
            igTableSetupColumn('Flurry',  0, 0)
            igTableSetupColumn('Refresh', 0, 0)
            igTableSetupColumn('Protect', 0, 0)
            igTableSetupColumn('Shell',   0, 0)
            igTableSetupColumn('Phalanx', 0, 0)
            imgui.TableHeadersRow()
            for _, c in ipairs(chars)  do buff_row(c, nil) end
            for _, g in ipairs(guests) do buff_row(g, COLOR_GUEST) end
            igEndTable()
        end
    end
    igEnd()
    if not BUFF_PANEL_OPEN[1] then show_buffpanel = false end
end)

------------------------------------------------------------
-- RDM DEBUFF CONTROLS PANEL
------------------------------------------------------------
-- Which debuffs the RDM lands on whatever mob the MAIN engages. The HUD 'D' column
-- is the master gate (session-armed by /sync on); these toggles pick WHICH debuffs
-- run under it. Cast order is fixed and matches the live queue: Silence (if checked)
-- -> Dia III -> Frazzle III -> Distract III. Toggles are durable (not wiped on zone);
-- a change takes effect on the next mob (the per-target queue is built once on engage).
local DEBUFF_PANEL_OPEN  = {true}
local DEBUFF_PANEL_FLAGS = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)

ashita.events.register('d3d_present', 'render_debuffpanel', function()
    if not show_debuffpanel then return end
    igSetNextWindowBgAlpha(0.55)
    DEBUFF_PANEL_OPEN[1] = true
    if igBegin('RDM Debuffs', DEBUFF_PANEL_OPEN, DEBUFF_PANEL_FLAGS) then
        igTextColored(COLOR_GUEST, 'RDM Debuffs')
        tip("Cast on the main's engaged target. Order: Silence > Dia III > Frazzle III > Distract III.")
        geo_mod.right_align(18)
        imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
        imgui.PushStyleColor(ImGuiCol_Text, COLOR_OFFLINE)
        if igSmallButton('x##debclose') then show_debuffpanel = false end
        imgui.PopStyleColor(4)
        tip('Close (or click "deb" in the main HUD, or /sync dpanel)')

        local r = cached_rdm
        if not r then
            igTextDisabled('No RDM in crew.')
        else
            igCheckbox('Silence'      .. r.debuff_ids.sil,  r.sil)
            tip('Cast Silence on the main\'s engaged target (first in the debuff queue when enabled).')
            igCheckbox('Dia III'      .. r.debuff_ids.dia,  r.dia)
            tip('Cast Dia III on the main\'s engaged target (Defense Down + slip damage).')
            igCheckbox('Frazzle III'  .. r.debuff_ids.fraz, r.fraz)
            tip('Cast Frazzle III on the main\'s engaged target (magic accuracy / evasion down).')
            igCheckbox('Distract III' .. r.debuff_ids.dist, r.dist)
            tip('Cast Distract III on the main\'s engaged target (evasion down).')
        end
    end
    igEnd()
    if not DEBUFF_PANEL_OPEN[1] then show_debuffpanel = false end
end)

------------------------------------------------------------
-- GEOMANCER PANEL (Indi / Geo / Entrust scheduler config)
------------------------------------------------------------
-- Singer-style spell-set "playlist" picker plus per-slot spell + duration +
-- recast jitter. All buffers + panel state live under geo_mod to keep this
-- under LuaJIT's 200-local ceiling. Inputs commit on Enter OR focus-loss
-- (matches the Advanced panel's tier_cell idiom); the bottom Save button
-- flushes everything and writes settings.
geo_mod.open = {true}
geo_mod.flags = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)
geo_mod.seeded = false
geo_mod.buf = {
    character   = {''},
    active      = {true},
    -- indi
    indi_dur    = {'240'}, indi_rmin = {'30'}, indi_rmax = {'60'},
    indi_idx    = {0},   -- selected index into geo_mod.indi_spells
    -- geo bubble
    geo_dur     = {'240'}, geo_rmin  = {'30'}, geo_rmax  = {'60'},
    geo_idx     = {0},
    geo_party   = {true},  -- radio state mirror; geo_mob = not geo_party
    geo_mob     = {false},
    geo_target  = {''},
    geo_combat  = {true},
    -- entrust
    en_dur      = {'240'}, en_rmin   = {'30'}, en_rmax   = {'60'},
    en_idx      = {0},
    en_target   = {''},
    -- JAs
    bog         = {false}, ea       = {false}, demat = {false},
    -- spell sets
    set_idx     = {0},
    set_save_nm = {''},
}

function geo_mod.find_spell_idx(list, name)
    for i = 1, #list do if list[i] == name then return i - 1 end end
    return 0
end

function geo_mod.set_names()
    local out = {}
    local sets = config.geo and config.geo.sets or {}
    for i = 1, #sets do out[i] = sets[i].name or '' end
    return out
end

function geo_mod.reseed()
    local g = config.geo or {}
    local b = geo_mod.buf
    b.character[1] = g.character or ''
    b.active[1]    = g.active ~= false
    local is = g.indi or {}
    b.indi_dur[1]  = tostring(is.duration or 240)
    b.indi_rmin[1] = tostring(is.recast_min or 30)
    b.indi_rmax[1] = tostring(is.recast_max or 60)
    b.indi_idx[1]  = geo_mod.find_spell_idx(geo_mod.indi_spells, is.spell or '')
    local gs = g.geo or {}
    b.geo_dur[1]   = tostring(gs.duration or 240)
    b.geo_rmin[1]  = tostring(gs.recast_min or 30)
    b.geo_rmax[1]  = tostring(gs.recast_max or 60)
    b.geo_idx[1]   = geo_mod.find_spell_idx(geo_mod.geo_spells, gs.spell or '')
    b.geo_party[1] = (gs.target_mode ~= 'mob')
    b.geo_mob[1]   = (gs.target_mode == 'mob')
    b.geo_target[1] = gs.target or ''
    b.geo_combat[1] = gs.combat_only and true or false
    local es = g.entrust or {}
    b.en_dur[1]    = tostring(es.duration or 240)
    b.en_rmin[1]   = tostring(es.recast_min or 30)
    b.en_rmax[1]   = tostring(es.recast_max or 60)
    b.en_idx[1]    = geo_mod.find_spell_idx(geo_mod.indi_spells, es.spell or '')
    b.en_target[1] = es.target or ''
    local ja = g.ja or {}
    b.bog[1]   = ja.bog and true or false
    b.ea[1]    = ja.ea and true or false
    b.demat[1] = ja.demat and true or false
end

-- Flush all panel buffers into config.geo and reset the scheduler so the
-- new durations/jitters take effect on the next slot evaluation.
function geo_mod.commit_all()
    local g = config.geo
    if not g then return end
    local b = geo_mod.buf
    g.character = (b.character[1] or ''):gsub('%s', ''):lower()
    g.active    = b.active[1] and true or false
    -- indi
    local function clamp_num(s, dflt, lo, hi)
        local n = tonumber(s) or dflt
        if lo and n < lo then n = lo end
        if hi and n > hi then n = hi end
        return n
    end
    g.indi.spell      = geo_mod.indi_spells[b.indi_idx[1] + 1] or g.indi.spell
    g.indi.duration   = clamp_num(b.indi_dur[1],  240, 1, 7200)
    g.indi.recast_min = clamp_num(b.indi_rmin[1],  30, 0, 600)
    g.indi.recast_max = clamp_num(b.indi_rmax[1],  60, g.indi.recast_min, 600)
    -- geo bubble
    g.geo.spell       = geo_mod.geo_spells[b.geo_idx[1] + 1] or g.geo.spell
    g.geo.duration    = clamp_num(b.geo_dur[1],   240, 1, 7200)
    g.geo.recast_min  = clamp_num(b.geo_rmin[1],   30, 0, 600)
    g.geo.recast_max  = clamp_num(b.geo_rmax[1],   60, g.geo.recast_min, 600)
    g.geo.target_mode = b.geo_party[1] and 'party' or 'mob'
    g.geo.target      = (b.geo_target[1] or ''):gsub('%s', '')
    g.geo.combat_only = b.geo_combat[1] and true or false
    -- entrust
    g.entrust.spell      = geo_mod.indi_spells[b.en_idx[1] + 1] or g.entrust.spell
    g.entrust.duration   = clamp_num(b.en_dur[1],  240, 1, 7200)
    g.entrust.recast_min = clamp_num(b.en_rmin[1],  30, 0, 600)
    g.entrust.recast_max = clamp_num(b.en_rmax[1],  60, g.entrust.recast_min, 600)
    g.entrust.target     = (b.en_target[1] or ''):gsub('%s', '')
    -- JAs
    g.ja.bog   = b.bog[1]   and true or false
    g.ja.ea    = b.ea[1]    and true or false
    g.ja.demat = b.demat[1] and true or false
    -- Reset scheduler timers so the new cadence kicks in immediately.
    geo_mod.indi.wear_at = 0;    geo_mod.indi.jitter = 0
    geo_mod.geo.wear_at  = 0;    geo_mod.geo.jitter  = 0
    geo_mod.entrust.wear_at = 0; geo_mod.entrust.jitter = 0
end

-- Apply a saved spell set to the live slots (and the panel buffers).
function geo_mod.load_set(idx)
    local s = config.geo and config.geo.sets and config.geo.sets[idx]
    if not s then return end
    config.geo.indi.spell    = s.indi    or config.geo.indi.spell
    config.geo.geo.spell     = s.geo     or config.geo.geo.spell
    config.geo.entrust.spell = s.entrust or config.geo.entrust.spell
    config.geo.ja.bog   = s.bog   and true or false
    config.geo.ja.ea    = s.ea    and true or false
    config.geo.ja.demat = s.demat and true or false
    settings.save()
    geo_mod.reseed()
    geo_mod.indi.wear_at = 0; geo_mod.geo.wear_at = 0; geo_mod.entrust.wear_at = 0
end

-- Snapshot the current live slots as a new named set.
function geo_mod.save_set(name)
    name = (name or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' or not config.geo then return end
    local sets = config.geo.sets
    local g = config.geo
    local entry = T{
        name    = name,
        indi    = g.indi.spell,
        geo     = g.geo.spell,
        entrust = g.entrust.spell,
        bog     = g.ja.bog   and true or false,
        ea      = g.ja.ea    and true or false,
        demat   = g.ja.demat and true or false,
    }
    -- If a set of this name exists, replace it; else append.
    for i = 1, #sets do
        if (sets[i].name or '') == name then sets[i] = entry; settings.save(); return end
    end
    sets[#sets + 1] = entry
    settings.save()
end

function geo_mod.delete_set(idx)
    if not (config.geo and config.geo.sets and config.geo.sets[idx]) then return end
    table.remove(config.geo.sets, idx)
    settings.save()
end

-- One numeric text cell. Same commit-on-Enter / commit-on-deactivate pattern
-- as Advanced's tier_cell. Returns nothing; updates buf[1] in-place on commit.
function geo_mod.num_cell(tag, buf, w, on_done)
    imgui.SetNextItemWidth(w or 50)
    local done = imgui.InputText(tag, buf, 8, NUM_INPUT_FLAGS)
    if not done and imgui.IsItemDeactivatedAfterEdit then done = imgui.IsItemDeactivatedAfterEdit() end
    if done then on_done() end
end

function geo_mod.text_cell(tag, buf, w, on_done)
    imgui.SetNextItemWidth(w or 110)
    -- FIX: match num_cell's commit-on-focus-loss (was Enter-only -- clicking
    -- away from the field silently discarded whatever was typed, same bug
    -- class already fixed for the Combat panel's pull field).
    local done = imgui.InputText(tag, buf, 32, ImGuiInputTextFlags_EnterReturnsTrue)
    if not done and imgui.IsItemDeactivatedAfterEdit then done = imgui.IsItemDeactivatedAfterEdit() end
    if done then
        on_done()
    end
end

-- Right-justify the next ImGui item to the window's right edge. Defensive:
-- Ashita v4's binding returns ImVec2 either as separate (x,y) values or as a
-- userdata/table with .x / [1]. Probe all three shapes and fall back to a
-- modest SameLine(0, 12) gap if nothing works -- the cursor still advances.
-- OPT: hoisted so right_align (called every frame in render_ui) never builds a
-- closure on the userdata-ImVec2 binding path; r1 is passed as an arg instead.
function geo_mod._probe_x(v) return v.x end
function geo_mod.right_align(item_width)
    imgui.SameLine()
    local avail_x = nil
    local r1, r2 = imgui.GetContentRegionAvail()
    if type(r1) == 'number' then
        avail_x = r1
    elseif r1 ~= nil then
        local ok, v = pcall(geo_mod._probe_x, r1)
        if ok and v then avail_x = v
        elseif type(r1) == 'table' then avail_x = r1[1] end
    end
    if avail_x and avail_x > (item_width + 4) then
        local cx = imgui.GetCursorPosX()
        if cx then imgui.SetCursorPosX(cx + (avail_x - item_width)) end
    end
end

function geo_mod.spell_combo(tag, list, idx_buf, on_change, width)
    imgui.SetNextItemWidth(width or 150)
    local cur_label = list[idx_buf[1] + 1] or ''
    if imgui.BeginCombo(tag, cur_label) then
        for k = 1, #list do
            local is_sel = (idx_buf[1] == k - 1)
            if imgui.Selectable(list[k], is_sel) then
                idx_buf[1] = k - 1
                on_change()
            end
            if is_sel then imgui.SetItemDefaultFocus() end
        end
        imgui.EndCombo()
    end
end

------------------------------------------------------------
-- WHM-MAIN PROACTIVE EXTRAS (timer-driven; no rdmhelper buff plumbing)
------------------------------------------------------------
-- Attached to geo_mod because LuaJIT's 200-local ceiling is full at module
-- scope. geo_mod is the multi-feature container.

-- "MM:SS" or "M:SS" or bare-seconds parser. Returns nil on garbage.
function geo_mod.parse_mmss(s)
    if not s then return nil end
    s = tostring(s):gsub('^%s+', ''):gsub('%s+$', '')
    local m, sec = s:match('^(%d+):(%d+)$')
    if m then return tonumber(m) * 60 + tonumber(sec) end
    local n = tonumber(s)
    return n
end

function geo_mod.fmt_mmss(n)
    n = tonumber(n) or 0
    if n < 0 then n = 0 end
    n = math.floor(n)
    return ('%d:%02d'):format(math.floor(n / 60), n % 60)
end

------------------------------------------------------------
-- BRD methods (cycle / casting / playlists)
------------------------------------------------------------
function geo_mod.brd.reset_cycle()
    local c = geo_mod.brd.cycle
    c.idx = 1; c.phase = 'casting'; c.start = os.time(); c.ann60 = false; c.ann30 = false
    c.ja_done = c.ja_done or {}
    c.ja_done.soul_voice  = false
    c.ja_done.nightingale = false
    c.ja_done.troubadour  = false
    c.ja_done.clarion     = false
    c.row_idx = 0; c.row_marcato = false; c.row_pianissimo = false
end

function geo_mod.brd.song_from_command(str)
    if not str or str == '' then return nil end
    return geo_mod.brd.song_lookup[(str:gsub('[%s%p]', '')):lower()]
end

-- Returns the canonical cast name if `name` is a known song, else nil.
function geo_mod.brd.song_valid(name)
    if not name then return nil end
    return geo_mod.brd.song_lookup[(name:gsub('[%s%p]', '')):lower()]
end

function geo_mod.brd.find_bard()
    local nm = (config.brd and config.brd.character or ''):lower()
    if nm == '' then return nil end
    for _, c in ipairs(chars) do if c.name_lower == nm then return c end end
    return nil
end

function geo_mod.brd.set_sing(on)
    config.brd.sing = on and true or false
    geo_mod.brd.reset_cycle()
    settings.save()
end

-- Marcato is a single across the whole playlist (checking it on one row clears
-- it on the others). Marcato and Pianissimo are NOT mutually exclusive on a
-- row: both may be checked so a single-target (Pianissimo) song can also be
-- Marcato-boosted. The check_song cascade fires Marcato, then Pianissimo, then
-- the ST song, so no runtime change is needed.
function geo_mod.brd.set_marcato(i, on)
    local e = config.brd.songs[i]; if not e then return end
    if on then
        for j, other in ipairs(config.brd.songs) do if j ~= i then other.marcato = false end end
        e.marcato = true
    else
        e.marcato = false
    end
    settings.save()
end

function geo_mod.brd.set_pianissimo(i, on)
    local e = config.brd.songs[i]; if not e then return end
    if on then e.pianissimo = true else e.pianissimo = false end
    settings.save()
end

-- Per-row (enabled/marcato/pianissimo/target) checkbox + text buffers for one
-- playlist entry, created once per distinct song name and reused every frame
-- -- same idiom as the Combat panel's combat_addbuf/pullbuf lazy buffers.
-- en/m/p are resynced from the entry every frame by the caller (cheap, and
-- keeps external changes -- e.g. /sync brd marcato -- reflected live); the
-- target text buffer is seeded ONCE from e.target here and only advances on
-- commit, matching every other text field's Enter/focus-loss idiom in this
-- file (continuously reseeding a text buffer would fight in-progress typing).
function geo_mod.brd.row_buf(e)
    local r = geo_mod.brd.buf.row[e.name]
    if not r then
        r = { en = {false}, m = {false}, p = {false}, t = { e.target or '' } }
        geo_mod.brd.buf.row[e.name] = r
    end
    return r
end

function geo_mod.brd.clone_entries(src)
    local out = T{}
    for _, e in ipairs(src) do
        out[#out + 1] = T{
            name = e.name, enabled = e.enabled ~= false,
            marcato = e.marcato or false, pianissimo = e.pianissimo or false,
            target = e.target or '',
        }
    end
    return out
end

function geo_mod.brd.save_playlist(name)
    name = (name or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then return end
    config.brd.playlists[name] = T{
        entries = geo_mod.brd.clone_entries(config.brd.songs),
        ja = T{
            nightingale = config.brd.nightingale == true,
            troubadour  = config.brd.troubadour  == true,
            soul_voice  = config.brd.soul_voice  == true,
            clarion     = config.brd.clarion     == true,
        },
    }
    config.brd.current_playlist = name
    settings.save()
    print(('[sync] BRD playlist saved: %s (%d songs)'):format(name, #config.brd.songs))
end

function geo_mod.brd.load_playlist(name)
    local p = config.brd.playlists[name]
    if not p then print('[sync] BRD: no playlist named "' .. tostring(name) .. '"'); return end
    config.brd.songs = geo_mod.brd.clone_entries(p.entries or {})
    if p.ja then
        config.brd.nightingale = p.ja.nightingale == true
        config.brd.troubadour  = p.ja.troubadour  == true
        config.brd.soul_voice  = p.ja.soul_voice  == true
        config.brd.clarion     = p.ja.clarion     == true
    end
    config.brd.current_playlist = name
    settings.save()
    -- NOTE: cycle intentionally NOT reset on load (mirrors Singer) so swapping a
    -- playlist mid-cycle doesn't trigger an immediate re-sing.
    print(('[sync] BRD playlist loaded: %s (%d songs)'):format(name, #config.brd.songs))
end

function geo_mod.brd.delete_playlist(name)
    if not config.brd.playlists[name] then print('[sync] BRD: no playlist named "' .. tostring(name) .. '"'); return end
    config.brd.playlists[name] = nil
    if config.brd.current_playlist == name then config.brd.current_playlist = '' end
    settings.save()
    print('[sync] BRD playlist deleted: ' .. name)
end

function geo_mod.brd.playlist_names()
    local out = {}
    for n in pairs(config.brd.playlists) do out[#out + 1] = n end
    table.sort(out)
    return out
end

----------------------------------------------------------------------------------------------------
-- check_song: one tick of the cycle, fired remotely on the bard box `c`. Walks
-- from cycle.idx; skips disabled / unknown / Pianissimo-without-target. Each
-- enabled JA is ATTEMPTED ONCE (global JAs once per cycle; Marcato/Pianissimo
-- once per row) -- no recast/buff monitoring. If the JA is on cooldown the game
-- ignores the command; we've flagged it attempted, so the cascade just proceeds
-- to the next JA and then the song. Phase flips to 'waiting' at the playlist end.
----------------------------------------------------------------------------------------------------
function geo_mod.brd.check_song(c, now)
    local b = config.brd
    local entries = b.songs
    if #entries == 0 then return end
    local cyc = geo_mod.brd.cycle
    local done = cyc.ja_done
    local function fire(cmd) do_action(c, cmd, geo_mod.brd.ja_lock, now) end

    while cyc.idx <= #entries do
        -- New row? reset the per-row JA one-shots.
        if cyc.row_idx ~= cyc.idx then
            cyc.row_idx = cyc.idx; cyc.row_marcato = false; cyc.row_pianissimo = false
        end
        local e = entries[cyc.idx]
        if not e.enabled then
            cyc.idx = cyc.idx + 1
        else
            local enl = geo_mod.brd.song_valid(e.name)
            if not enl then
                cyc.idx = cyc.idx + 1
            elseif e.pianissimo and (not e.target or e.target == '') then
                cyc.idx = cyc.idx + 1   -- Pianissimo row with no target: skip
            else
                -- Global JAs -- one attempt per cycle, in cascade order.
                if b.soul_voice and not done.soul_voice then
                    done.soul_voice = true; fire('/ja "Soul Voice" <me>'); return
                end
                if b.nightingale and not done.nightingale then
                    done.nightingale = true; fire('/ja "Nightingale" <me>'); return
                end
                if b.troubadour and not done.troubadour then
                    done.troubadour = true; fire('/ja "Troubadour" <me>'); return
                end
                if b.clarion and not done.clarion then
                    done.clarion = true; fire('/ja "Clarion Call" <me>'); return
                end
                -- Per-row JAs -- one attempt for THIS row.
                if e.marcato and not cyc.row_marcato then
                    cyc.row_marcato = true; fire('/ja "Marcato" <me>'); return
                end
                if e.pianissimo and not cyc.row_pianissimo then
                    cyc.row_pianissimo = true; fire('/ja "Pianissimo" <me>'); return
                end
                -- Cast the song (Pianissimo'd -> ST at the row target, else <me>).
                local tgt = (e.pianissimo and e.target ~= '') and e.target or '<me>'
                do_action(c, ('/ma "%s" %s'):format(enl, tgt), (b.delay or 2.0) + geo_mod.brd.song_cast, now)
                cyc.idx = cyc.idx + 1
                return
            end
        end
    end
    cyc.phase = 'waiting'   -- walked off the end; restart on interval
end

----------------------------------------------------------------------------------------------------
-- tick: scheduler entry, called once per logic_loop frame. Cycle restart,
-- pre-restart announces, opt-in engage-lock, and action_lock-paced song casting.
----------------------------------------------------------------------------------------------------
function geo_mod.brd.tick(now)
    local b = config.brd
    if not b or not b.sing or not b.character or b.character == '' then
        local hc = geo_mod.brd.find_bard()
        if hc and hc.brd_hold then hc.brd_hold = false end
        return
    end
    if now < geo_mod.brd.next_check then return end
    geo_mod.brd.next_check = now + (geo_mod.brd.poll or 0.1)

    local c = geo_mod.brd.find_bard()
    if not c or not c.in_zone then return end
    local cyc = geo_mod.brd.cycle
    local iv  = b.interval or 240

    if cyc.phase == 'waiting' then
        local elapsed = os.time() - cyc.start
        if elapsed >= iv then
            geo_mod.brd.reset_cycle()
        elseif b.announce then
            local rem = iv - elapsed
            if not cyc.ann60 and iv > 60 and rem <= 60 and rem > 0 then
                cyc.ann60 = true
                qcmd('/msp /echo ~~~*singing in 1min*~~~')
            end
            if not cyc.ann30 and iv > 30 and rem <= 30 and rem > 0 then
                cyc.ann30 = true
                qcmd('/msp /echo ~~~~~~~***singing in 30seconds***~~~~~~~')
            end
        end
    end

    -- Engage-lock (opt-in): disengaged while casting, released while waiting so
    -- sync's normal engage tracking can re-engage. do_action bumps action_lock,
    -- so we return and let the disengage settle before any song fires.
    if b.engagelock then
        local want_hold = (cyc.phase == 'casting')
        if want_hold and not c.brd_hold then
            do_action(c, '/attack off', 1.0, now)
            c.brd_hold = true
            return
        elseif (not want_hold) and c.brd_hold then
            c.brd_hold = false
        end
    end

    if cyc.phase == 'waiting' then return end
    if now <= c.action_lock then return end
    geo_mod.brd.check_song(c, now)
end

function geo_mod.brd.reseed()
    geo_mod.brd.buf.character[1] = (config.brd and config.brd.character) or ''
end

-- Cheap any-enabled gate: skip the entire extras evaluation when nothing in
-- the slot wants firing. Called once per healer per tick.
function geo_mod.whm_any_enabled(cfg)
    if not cfg or not cfg.extras then return false end
    local x = cfg.extras
    if x.protectra and x.protectra.enabled then return true end
    if x.shellra   and x.shellra.enabled   then return true end
    if x.auspice   and x.auspice.enabled   then return true end
    if x.boost     and x.boost.enabled     then return true end
    if x.barel     and x.barel.enabled     then return true end
    if x.barst     and x.barst.enabled     then return true end
    if x.regen     and x.regen.enabled     then return true end
    return false
end

-- Per-healer extras pass. Runs only when the healer's main job is WHM (or
-- unread = 0; lets the panel configure offline). Fires at most ONE extra per
-- tick (priority order: Protectra > Shellra > Auspice > Boost > Bar-El >
-- Bar-St > Regen). Each gate is `now - extra_last[key] >= recast`; the cast
-- itself uses do_action (lock-respecting) or queue_cast (Accession + Regen).
-- FIX(extras cadence): minimum spacing between two CONSECUTIVE WHM extras on one
-- healer. Without it, several checked extras fired within a few ticks and the
-- later /ma lines were rejected on the remote box (still mid-cast / animation
-- lock) -- yet their per-spell recast timers had already advanced, so they were
-- silently skipped for a full cycle. This floor lets each cast COMMIT before the
-- next is attempted. Tunable (bump if a slow cast still drops).
geo_mod.extras_min_gap = 6.0
function geo_mod.whm_extras_pass(h, cfg, party, now)
    if not h or not cfg or now <= h.action_lock then return end
    if now - (h.last_extra_cast or 0) < geo_mod.extras_min_gap then return end
    if h.job ~= 0 and h.job ~= JOB_WHM then return end   -- WHM main only (0 = unread)
    if not geo_mod.whm_any_enabled(cfg) then return end

    local x = cfg.extras
    local L = h.extra_last
    if not L then
        L = { protectra=0, shellra=0, auspice=0, boost=0, barel=0, barst=0, regen=0 }
        h.extra_last = L
    end

    -- MP read (best effort; if unavailable, skip MP gating)
    local mp = 9999
    if h.pt_data and h.pt_data.index then
        mp = party:GetMemberMP(h.pt_data.index) or 9999
    end

    local function fire_ma(spell, key, cast_t, mp_cost)
        if mp < (mp_cost or 0) then return false end
        do_action(h, '/ma "' .. spell .. '" <me>', cast_t or 3.0, now)
        L[key] = now
        h.last_extra_cast = now
        return true
    end

    if x.protectra and x.protectra.enabled and now - L.protectra >= (x.protectra.recast or 1700) then
        if fire_ma('Protectra V', 'protectra', 3.0, 60) then return end
    end
    if x.shellra and x.shellra.enabled and now - L.shellra >= (x.shellra.recast or 1700) then
        if fire_ma('Shellra V', 'shellra', 3.0, 60) then return end
    end
    if x.auspice and x.auspice.enabled and now - L.auspice >= (x.auspice.recast or 170) then
        if fire_ma('Auspice', 'auspice', 3.0, 24) then return end
    end
    if x.boost and x.boost.enabled and x.boost.spell and x.boost.spell ~= ''
       and now - L.boost >= (x.boost.recast or 280) then
        if fire_ma(x.boost.spell, 'boost', 2.0, 5) then return end
    end
    if x.barel and x.barel.enabled and x.barel.spell and x.barel.spell ~= ''
       and now - L.barel >= (x.barel.recast or 170) then
        if fire_ma(x.barel.spell, 'barel', 2.5, 24) then return end
    end
    if x.barst and x.barst.enabled and x.barst.spell and x.barst.spell ~= ''
       and now - L.barst >= (x.barst.recast or 170) then
        if fire_ma(x.barst.spell, 'barst', 2.5, 24) then return end
    end
    -- Regen: Accession + Regen on cycle (party-AoE via Accession). Reserves
    -- the healer for the whole window so a routine Cure can't preempt and
    -- consume the Accession charge before the Regen lands.
    if x.regen and x.regen.enabled and x.regen.spell and x.regen.spell ~= ''
       and now - L.regen >= (x.regen.recast or 90) and mp >= 50 then
        local rcast = get_cast_delay(x.regen.spell)
        do_action(h, '/ja "Accession" <me>', 1.0, now)
        h.cast_reserved_until = now + 1.0 + rcast + 0.5
        queue_cast(h, '/ma "' .. x.regen.spell .. '" <me>', now + 1.0, rcast)
        L.regen = now
        h.last_extra_cast = now
        return
    end
end

-- Per-healer WHM HASTE monitor. Lives in the HEALER menu (cfg.haste1), NOT the
-- WHM-extras block: it is a buff MONITOR (reads the live buff state) rather than a
-- blind timer. When on, and the healer's live job can cast Haste (WHM main, or
-- /WHM>=40), it casts Haste on any Cure-flagged member that is MISSING the Haste
-- buff -- covering the RDM's Haste when no RDM is up. Haste / Haste II / RDM Haste
-- all share buff id 33, so a member already hasted (by Goomy or anyone) reads
-- buffs.h = true and is skipped: no double-cast.
--
-- Gated exactly like cures: the cross-healer heal claim (two healers never haste
-- the same target, and a pending cure-claim defers a haste) plus a per-target
-- retry gap. Only READABLE targets are considered (own party via the memory scan,
-- or a fresh rdmhelper report) so an unverifiable cross-party member can't be
-- spammed. Same action-lock + cast-reservation gates as the extras/heal passes,
-- so it fires at most one cast per tick and never overlaps a cure.
geo_mod.haste_retry_gap = 15.0
function geo_mod.haste_pass(h, cfg, party, player, now)
    if not h or not cfg or not cfg.haste1 then return end
    if now <= (h.action_lock or 0) then return end
    if now < (h.cast_reserved_until or 0) then return end

    local mj, sj, sjlvl = healer_jobs(h, party, player)
    if not ((mj == JOB_WHM) or (sj == JOB_WHM and (sjlvl or 0) >= 40)) then return end

    -- MP floor (own party only; cross-party MP is unreadable -> don't gate).
    if h.pt_data and h.pt_data.index and h.pt_data.index < 6 then
        if (party:GetMemberMP(h.pt_data.index) or 0) < CURE_MIN_MP then return end
    end

    local cast = get_cast_delay('Haste')
    local gap  = geo_mod.haste_retry_gap
    local function consider(t)
        if not (t.heal and t.heal[1] and t.in_zone and t.pt_data) then return false end
        if bit_band(t.status or 0, CHARM_BIT) ~= 0 then return false end   -- never haste a charmed member
        if t.buffs and t.buffs.h then return false end                     -- already hasted (incl. RDM Haste/II)
        local readable = (t.pt_data.index < 6) or (now - (t.last_rep_time or 0) < REPORT_BUFF_TTL)
        if not readable then return false end                              -- unverifiable -> don't spam
        if heal_claimed_by_other(h, t.name, now) then return false end
        local locks = h.buff_locks[t.name]
        if now - ((locks and locks['haste']) or 0) < gap then return false end
        if not locks then locks = {}; h.buff_locks[t.name] = locks end
        locks['haste'] = now
        claim_heal(h, t.name, now, cast + HEAL_LAND_MARGIN)
        local tstr = (t.name_lower == h.name_lower) and '<me>' or t.name
        do_action(h, '/ma "Haste" ' .. tstr, cast, now)
        return true
    end

    for _, t in ipairs(chars)  do if consider(t) then return end end
    for _, t in ipairs(guests) do if consider(t) then return end end
end

ashita.events.register('d3d_present', 'render_geopanel', function()
    if not geo_mod.show_panel then return end
    if not geo_mod.seeded then geo_mod.reseed(); geo_mod.seeded = true end

    igSetNextWindowBgAlpha(0.65)
    geo_mod.open[1] = true
    if igBegin('Sync - Geomancer', geo_mod.open, geo_mod.flags) then
        igTextColored(STYLE_BTN.geo, 'Geomancer')
        tip('Indi / Geo bubble / Entrust scheduler. character = "" disables the whole block (no wasted ticks).')
        geo_mod.right_align(18)
        imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
        imgui.PushStyleColor(ImGuiCol_Text, COLOR_OFFLINE)
        if igSmallButton('x##geoclose') then
            geo_mod.show_panel = false; geo_mod.seeded = false
        end
        imgui.PopStyleColor(4)
        tip('Close (or click "GEO:" in the main HUD, or /sync geo)')
        igTextDisabled('Enter commits text fields; Save flushes all & writes settings.')
        imgui.Separator()

        -- Character
        igText('GEO box')
        tip('Crew name of the GEO box. Empty disables the scheduler entirely.')
        igSameLine(0, 8); imgui.SetNextItemWidth(110)
        if imgui.InputText('##geochar', geo_mod.buf.character, 32, ImGuiInputTextFlags_EnterReturnsTrue) then
            config.geo.character = (geo_mod.buf.character[1] or ''):gsub('%s', ''):lower()
            settings.save()
            geo_mod.buf.character[1] = config.geo.character
        end
        tip('Character name of the GEO box (must match a crew slot). Press Enter to commit.')
        igSameLine(0, 12)
        if igCheckbox('Active##geoactive', geo_mod.buf.active) then
            config.geo.active = geo_mod.buf.active[1] and true or false
            settings.save()
            print('[sync] geo casting ' .. (config.geo.active and 'enabled' or 'disabled'))
        end
        tip('Master on/off for GEO spell casting. Uncheck to pause all casts without clearing the character name. (/sync geo on | /sync geo off)')

        imgui.Separator()

        -- Spell sets (Singer-style playlist combo)
        local names = geo_mod.set_names()
        igText('Set:')
        tip('Saved spell sets (each captures Indi + Geo + Entrust spells + the three JA toggles).')
        igSameLine(0, 6)
        if #names == 0 then
            igTextDisabled('(none saved)')
        else
            if geo_mod.buf.set_idx[1] >= #names then geo_mod.buf.set_idx[1] = 0 end
            geo_mod.spell_combo('##geoset', names, geo_mod.buf.set_idx, function() end, 130)
            igSameLine(0, 6)
            if igSmallButton('Load##geoset') then
                geo_mod.load_set(geo_mod.buf.set_idx[1] + 1)
            end
            tip('Load the selected set - REPLACES current Indi / Geo / Entrust spells and JA toggles.')
            igSameLine(0, 4)
            if igSmallButton('Del##geoset') then
                geo_mod.delete_set(geo_mod.buf.set_idx[1] + 1)
            end
            tip('Delete the selected set.')
        end
        igText('Save as:')
        tip('Save the current spells + JA toggles as a named set. Same name = overwrite.')
        igSameLine(0, 6); imgui.SetNextItemWidth(130)
        if imgui.InputText('##geosetsave', geo_mod.buf.set_save_nm, 32, ImGuiInputTextFlags_EnterReturnsTrue) then
            local n = (geo_mod.buf.set_save_nm[1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
            if n ~= '' then geo_mod.save_set(n); geo_mod.buf.set_save_nm[1] = '' end
        end
        igSameLine(0, 6)
        if igSmallButton('Save##geosetsave') then
            local n = (geo_mod.buf.set_save_nm[1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
            if n ~= '' then geo_mod.save_set(n); geo_mod.buf.set_save_nm[1] = '' end
        end

        imgui.Separator()

        -- Indi slot (always self-cast)
        igTextColored(COLOR_GUEST, 'Indi  (self)')
        tip('Indi-X spell - always cast on the GEO box (<me>).')
        geo_mod.spell_combo('##geoindisp', geo_mod.indi_spells, geo_mod.buf.indi_idx, function()
            config.geo.indi.spell = geo_mod.indi_spells[geo_mod.buf.indi_idx[1] + 1] or config.geo.indi.spell
            settings.save()
            geo_mod.indi.wear_at = 0
        end, 150)
        tip('Pick the Indi-X spell to maintain.')
        igSameLine(0, 8); igText('dur')
        tip('Configured wear-off duration in seconds (used as the recast timer base).')
        igSameLine(0, 4)
        geo_mod.num_cell('##geoidur', geo_mod.buf.indi_dur, 56, function()
            local n = tonumber(geo_mod.buf.indi_dur[1]) or 240
            if n < 1 then n = 1 elseif n > 7200 then n = 7200 end
            config.geo.indi.duration = n; settings.save()
            geo_mod.buf.indi_dur[1] = tostring(n); geo_mod.indi.wear_at = 0
        end)
        igSameLine(0, 8); igText('recast')
        tip('Recast window - fires randomly between (dur - max) and (dur - min) seconds before wear-off.')
        igSameLine(0, 4)
        geo_mod.num_cell('##geoirmin', geo_mod.buf.indi_rmin, 40, function()
            local n = tonumber(geo_mod.buf.indi_rmin[1]) or 30
            if n < 0 then n = 0 elseif n > 600 then n = 600 end
            config.geo.indi.recast_min = n; settings.save()
            geo_mod.buf.indi_rmin[1] = tostring(n); geo_mod.indi.jitter = 0
        end)
        igSameLine(0, 2); igText('-')
        igSameLine(0, 2)
        geo_mod.num_cell('##geoirmax', geo_mod.buf.indi_rmax, 40, function()
            local n = tonumber(geo_mod.buf.indi_rmax[1]) or 60
            if n < (config.geo.indi.recast_min or 0) then n = config.geo.indi.recast_min or 0 end
            if n > 600 then n = 600 end
            config.geo.indi.recast_max = n; settings.save()
            geo_mod.buf.indi_rmax[1] = tostring(n); geo_mod.indi.jitter = 0
        end)

        imgui.Separator()

        -- Geo bubble (party-target OR mob-target)
        igTextColored(COLOR_GUEST, 'Geo bubble')
        tip('Geo-X spell - bubble dropped on a party member or on the engaged mob.')
        geo_mod.spell_combo('##geogeosp', geo_mod.geo_spells, geo_mod.buf.geo_idx, function()
            config.geo.geo.spell = geo_mod.geo_spells[geo_mod.buf.geo_idx[1] + 1] or config.geo.geo.spell
            settings.save()
            geo_mod.geo.wear_at = 0
        end, 150)
        tip('Pick the Geo-X bubble spell.')
        igSameLine(0, 8); igText('dur')
        igSameLine(0, 4)
        geo_mod.num_cell('##geogdur', geo_mod.buf.geo_dur, 56, function()
            local n = tonumber(geo_mod.buf.geo_dur[1]) or 240
            if n < 1 then n = 1 elseif n > 7200 then n = 7200 end
            config.geo.geo.duration = n; settings.save()
            geo_mod.buf.geo_dur[1] = tostring(n); geo_mod.geo.wear_at = 0
        end)
        igSameLine(0, 8); igText('recast')
        igSameLine(0, 4)
        geo_mod.num_cell('##geogrmin', geo_mod.buf.geo_rmin, 40, function()
            local n = tonumber(geo_mod.buf.geo_rmin[1]) or 30
            if n < 0 then n = 0 elseif n > 600 then n = 600 end
            config.geo.geo.recast_min = n; settings.save()
            geo_mod.buf.geo_rmin[1] = tostring(n); geo_mod.geo.jitter = 0
        end)
        igSameLine(0, 2); igText('-')
        igSameLine(0, 2)
        geo_mod.num_cell('##geogrmax', geo_mod.buf.geo_rmax, 40, function()
            local n = tonumber(geo_mod.buf.geo_rmax[1]) or 60
            if n < (config.geo.geo.recast_min or 0) then n = config.geo.geo.recast_min or 0 end
            if n > 600 then n = 600 end
            config.geo.geo.recast_max = n; settings.save()
            geo_mod.buf.geo_rmax[1] = tostring(n); geo_mod.geo.jitter = 0
        end)

        -- Target mode (party | mob), name field, combat_only (mob-only)
        if igCheckbox('party##geogmp', geo_mod.buf.geo_party) then
            if geo_mod.buf.geo_party[1] then
                geo_mod.buf.geo_mob[1] = false
                config.geo.geo.target_mode = 'party'; settings.save()
            else
                geo_mod.buf.geo_party[1] = true   -- can't both be off; force one
            end
        end
        tip('Bubble target = a party member by name (entered to the right).')
        igSameLine(0, 6)
        if igCheckbox('mob##geogmm', geo_mod.buf.geo_mob) then
            if geo_mod.buf.geo_mob[1] then
                geo_mod.buf.geo_party[1] = false
                config.geo.geo.target_mode = 'mob'; settings.save()
            else
                geo_mod.buf.geo_mob[1] = true
            end
        end
        tip('Bubble target = the current engaged mob (target name field overrides; empty = <bt>).')
        igSameLine(0, 8); igText('target')
        tip('Party member name (party mode) or mob name (mob mode; empty = <bt>).')
        igSameLine(0, 4)
        geo_mod.text_cell('##geogtarg', geo_mod.buf.geo_target, 100, function()
            config.geo.geo.target = (geo_mod.buf.geo_target[1] or ''):gsub('%s', '')
            settings.save()
            geo_mod.buf.geo_target[1] = config.geo.geo.target
        end)
        igSameLine(0, 8)
        if igCheckbox('only when engaged##geogco', geo_mod.buf.geo_combat) then
            config.geo.geo.combat_only = geo_mod.buf.geo_combat[1] and true or false
            settings.save()
        end
        tip('Mob mode only: skip Geo-X casts unless the main is currently attacking.')

        imgui.Separator()

        -- Entrust slot
        igTextColored(COLOR_GUEST, 'Entrust')
        tip('Entrust JA + Indi-X cast on a named party member.')
        geo_mod.spell_combo('##geoensp', geo_mod.indi_spells, geo_mod.buf.en_idx, function()
            config.geo.entrust.spell = geo_mod.indi_spells[geo_mod.buf.en_idx[1] + 1] or config.geo.entrust.spell
            settings.save()
            geo_mod.entrust.wear_at = 0
        end, 150)
        tip('Pick the Indi-X spell to entrust on the target.')
        igSameLine(0, 8); igText('dur')
        igSameLine(0, 4)
        geo_mod.num_cell('##geoedur', geo_mod.buf.en_dur, 56, function()
            local n = tonumber(geo_mod.buf.en_dur[1]) or 240
            if n < 1 then n = 1 elseif n > 7200 then n = 7200 end
            config.geo.entrust.duration = n; settings.save()
            geo_mod.buf.en_dur[1] = tostring(n); geo_mod.entrust.wear_at = 0
        end)
        igSameLine(0, 8); igText('recast')
        igSameLine(0, 4)
        geo_mod.num_cell('##geoermin', geo_mod.buf.en_rmin, 40, function()
            local n = tonumber(geo_mod.buf.en_rmin[1]) or 30
            if n < 0 then n = 0 elseif n > 600 then n = 600 end
            config.geo.entrust.recast_min = n; settings.save()
            geo_mod.buf.en_rmin[1] = tostring(n); geo_mod.entrust.jitter = 0
        end)
        igSameLine(0, 2); igText('-')
        igSameLine(0, 2)
        geo_mod.num_cell('##geoermax', geo_mod.buf.en_rmax, 40, function()
            local n = tonumber(geo_mod.buf.en_rmax[1]) or 60
            if n < (config.geo.entrust.recast_min or 0) then n = config.geo.entrust.recast_min or 0 end
            if n > 600 then n = 600 end
            config.geo.entrust.recast_max = n; settings.save()
            geo_mod.buf.en_rmax[1] = tostring(n); geo_mod.entrust.jitter = 0
        end)
        igText('target')
        tip('Party member name to entrust the Indi-X spell on. Empty = entrust slot disabled.')
        igSameLine(0, 4)
        geo_mod.text_cell('##geoentarg', geo_mod.buf.en_target, 100, function()
            config.geo.entrust.target = (geo_mod.buf.en_target[1] or ''):gsub('%s', '')
            settings.save()
            geo_mod.buf.en_target[1] = config.geo.entrust.target
        end)

        imgui.Separator()

        -- Job abilities (BoG pre-Geo, EA + Demat post-bubble)
        igTextColored(COLOR_GUEST, 'Job Abilities')
        tip('JAs fired around each Geo bubble cast.')
        if igCheckbox('Blaze of Glory##geobog', geo_mod.buf.bog) then
            config.geo.ja.bog = geo_mod.buf.bog[1] and true or false; settings.save()
        end
        tip('Fired immediately BEFORE the Geo bubble cast.')
        igSameLine(0, 12)
        if igCheckbox('Ecliptic Attrition##geoea', geo_mod.buf.ea) then
            config.geo.ja.ea = geo_mod.buf.ea[1] and true or false; settings.save()
        end
        tip('Fired AFTER the Geo bubble lands (anchored on the luopan).')
        igSameLine(0, 12)
        if igCheckbox('Dematerialize##geodemat', geo_mod.buf.demat) then
            config.geo.ja.demat = geo_mod.buf.demat[1] and true or false; settings.save()
        end
        tip('Fired AFTER the Geo bubble lands (anchored on the luopan).')

        imgui.Separator()
        if imgui.Button('Save config to file') then
            geo_mod.commit_all(); settings.save()
            print('[sync] geo config saved to file')
        end
        tip('Flush every text field into config and write the settings file.')
    end
    igEnd()
    if not geo_mod.open[1] then geo_mod.show_panel = false; geo_mod.seeded = false end
end)

-- Re-apply persisted config to live state on a character switch / settings reload.
local function apply_config()
    for i = 1, #chars do
        local nm = config.crew[i]
        if nm and nm ~= '' and chars[i].name_lower ~= nm:lower() then
            chars[i].name = nm
            init_char_state(chars[i])
        end
    end
    t_clear(known_cores)
    for _, c in ipairs(chars) do known_cores[c.name_lower] = true end
    adv_reseed()
    geo_mod.seeded = false
    geo_mod.indi.wear_at = 0;    geo_mod.indi.jitter = 0
    geo_mod.geo.wear_at  = 0;    geo_mod.geo.jitter  = 0
    geo_mod.entrust.wear_at = 0; geo_mod.entrust.jitter = 0
    broadcast_roster()
end

settings.register('settings', 'sync_settings_update', function(s)
    if s ~= nil then config = s end
    apply_config()
end)

local function set_flag(entry, cmd, state)
    if not (entry and entry[cmd]) then return end
    if state == nil then
        entry[cmd][1] = not entry[cmd][1]
    else
        entry[cmd][1] = state
    end
end

local function find_target(tr)
    for _, c in ipairs(chars)  do if c.name_lower:sub(1, #tr) == tr then return c end end
    for _, g in ipairs(guests) do if g.name_lower:sub(1, #tr) == tr then return g end end
    return nil
end

local function apply_command(cmd, tr, state)
    if not cmd then return end
    if tr == 'all' then
        local zone_gated = (cmd ~= 'f')
        local function affected(entry) return entry[cmd] and (not zone_gated or entry.in_zone) end

        local new_state = state
        if new_state == nil then
            for _, c in ipairs(chars)  do if affected(c) then new_state = not c[cmd][1]; break end end
            if new_state == nil then
                for _, g in ipairs(guests) do if affected(g) then new_state = not g[cmd][1]; break end end
            end
        end

        if new_state ~= nil then
            for _, c in ipairs(chars)  do if affected(c) then c[cmd][1] = new_state end end
            for _, g in ipairs(guests) do if affected(g) then g[cmd][1] = new_state end end
        end
    else
        set_flag(find_target(tr), cmd, state)
    end
end

ashita.events.register('d3d_present', 'render_brdwindow', function()
    if not geo_mod.brd.show_window then return end
    if not geo_mod.brd.seeded then geo_mod.brd.reseed(); geo_mod.brd.seeded = true end
    local b = config.brd

    igSetNextWindowBgAlpha(0.65)
    geo_mod.brd.open[1] = true
    if igBegin('Sync - Bard', geo_mod.brd.open, geo_mod.brd.flags) then
        igTextColored(STYLE_BTN.brd, 'Bard')
        tip('Bard song cycle. Walks the playlist one cast per tick on the bard box (/mst <character>); restarts every Cycle interval. Songs/JAs fire remotely, paced by action-lock -- the main cannot read the bard recasts, so JA timing uses local estimates.')
        do
            local dn = (b.character or ''):lower()
            local don = nil
            if dn ~= '' then for _, c in ipairs(chars) do if c.name_lower == dn then don = c.in_zone; break end end end
            igSameLine(0, 8)
            if dn == '' then
                igTextDisabled('(no box)')
            else
                igTextColored(don and STYLE_BTN.brd or COLOR_OFFLINE, dn:sub(1,3):upper() .. (don and '' or '!'))
            end
        end
        geo_mod.right_align(18)
        imgui.PushStyleColor(ImGuiCol_Button,        STYLE_BTN.bg)
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, STYLE_BTN.hover)
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  STYLE_BTN.active)
        imgui.PushStyleColor(ImGuiCol_Text, COLOR_OFFLINE)
        if igSmallButton('x##brdclose') then geo_mod.brd.show_window = false; geo_mod.brd.seeded = false end
        imgui.PopStyleColor(4)
        tip('Close (or click "BRD:" in the main HUD, or /sync brd)')
        imgui.Separator()

        -- BRD box + master Sing toggle
        igText('BRD box')
        tip('Crew name of the bard. Empty disables the scheduler entirely.')
        igSameLine(0, 8); imgui.SetNextItemWidth(110)
        -- FIX: Enter-only commit silently discarded a typed name on click-away
        -- (e.g. straight to the Sing checkbox) -- config.brd.character stayed
        -- '', find_bard() never resolved, and singing just never started with
        -- no error anywhere. Same bug class already fixed on the Combat panel's
        -- pull field; add the IsItemDeactivatedAfterEdit fallback here too.
        local brdchar_done = imgui.InputText('##brdchar', geo_mod.brd.buf.character, 32, ImGuiInputTextFlags_EnterReturnsTrue)
        if not brdchar_done and imgui.IsItemDeactivatedAfterEdit then brdchar_done = imgui.IsItemDeactivatedAfterEdit() end
        if brdchar_done then
            b.character = (geo_mod.brd.buf.character[1] or ''):gsub('%s', ''):lower()
            settings.save()
            geo_mod.brd.buf.character[1] = b.character
        end
        tip('Character name of the bard box (must match a crew slot). Press Enter to commit.')
        igSameLine(0, 12)
        do
            local ref = geo_mod.brd.buf.sing_ref; ref[1] = b.sing
            if igCheckbox('Sing##brdsing', ref) then geo_mod.brd.set_sing(ref[1]) end
            tip('Master on/off. Toggling EITHER direction resets the cycle timer.')
        end

        -- Status line
        do
            local n_songs = #b.songs
            local lock_str = ''
            local bc = geo_mod.brd.find_bard()
            if bc and bc.brd_hold then lock_str = '  [atk off]' end
            if not b.sing then
                igText(('Status: 0:00 / %s  [idle]%s'):format(geo_mod.fmt_mmss(b.interval), lock_str))
            else
                local cyc = geo_mod.brd.cycle
                local elapsed = math.min(os.time() - cyc.start, b.interval)
                local phase_str
                if cyc.phase == 'waiting' then
                    local rem = math.max(0, b.interval - (os.time() - cyc.start))
                    phase_str = ('waiting %s'):format(geo_mod.fmt_mmss(rem))
                else
                    local cur = cyc.idx; if cur > n_songs then cur = n_songs end; if cur < 1 then cur = 1 end
                    phase_str = ('casting %d/%d'):format(cur, math.max(1, n_songs))
                end
                igText(('Status: %s / %s  [%s]%s'):format(geo_mod.fmt_mmss(elapsed), geo_mod.fmt_mmss(b.interval), phase_str, lock_str))
            end
            tip('Elapsed since the cycle began / cycle length, plus the current phase. [atk off] shows while the engage-lock holds the bard disengaged.')
        end
        imgui.Separator()

        -- JA toggles
        do local r = geo_mod.brd.buf.nightingale_ref; r[1] = b.nightingale
           if igCheckbox('Nightingale##brd', r) then b.nightingale = r[1]; settings.save() end
           tip('Nightingale -- bypasses song recast. Attempted once per cycle; if on cooldown the cycle just moves on.') end
        igSameLine(0, 12)
        do local r = geo_mod.brd.buf.troubadour_ref; r[1] = b.troubadour
           if igCheckbox('Troubadour##brd', r) then b.troubadour = r[1]; settings.save() end
           tip('Troubadour -- doubles song duration. Attempted once per cycle; if on cooldown the cycle just moves on.') end
        do local r = geo_mod.brd.buf.soul_voice_ref; r[1] = b.soul_voice
           if igCheckbox('Soul Voice##brd', r) then b.soul_voice = r[1]; settings.save() end
           tip('Soul Voice (2hr). Attempted once per cycle while enabled; ignored by the game when on cooldown.') end
        igSameLine(0, 12)
        do local r = geo_mod.brd.buf.clarion_ref; r[1] = b.clarion
           if igCheckbox('Clarion Call##brd', r) then b.clarion = r[1]; settings.save() end
           tip('Clarion Call -- +1 song slot. Attempted once per cycle while enabled; ignored when on cooldown.') end
        imgui.Separator()

        -- Cycle interval + delay + announce + engagelock
        igText(('Cycle: %s'):format(geo_mod.fmt_mmss(b.interval)))
        tip('Playlist restart period. When this elapses since the cycle began, the playlist replays from song 1.')
        igSameLine(0, 4)
        if igSmallButton('-m##brdcyc') then b.interval = math.max(15, b.interval - 60); settings.save() end
        tip('-1 minute')
        igSameLine(0, 4)
        if igSmallButton('+m##brdcyc') then b.interval = math.min(3600, b.interval + 60); settings.save() end
        tip('+1 minute')
        igSameLine(0, 4)
        if igSmallButton('-s##brdcyc') then b.interval = math.max(15, b.interval - 5); settings.save() end
        tip('-5 seconds')
        igSameLine(0, 4)
        if igSmallButton('+s##brdcyc') then b.interval = math.min(3600, b.interval + 5); settings.save() end
        tip('+5 seconds')

        igSameLine(0, 16)
        igText(('Delay: %.1fs'):format(b.delay))
        tip('Extra pause folded into each song action-lock. Raise if songs land before the previous cast resolves.')
        igSameLine(0, 4)
        if igSmallButton('-##brddelay') then b.delay = math.max(0, b.delay - 0.5); settings.save() end
        igSameLine(0, 4)
        if igSmallButton('+##brddelay') then b.delay = math.min(12, b.delay + 0.5); settings.save() end

        do local r = geo_mod.brd.buf.announce_ref; r[1] = b.announce
           if igCheckbox('Announce##brd', r) then b.announce = r[1]; settings.save() end
           tip('/msp /echo party reminders 1 minute and 30 seconds before the playlist restarts.') end
        igSameLine(0, 12)
        do local r = geo_mod.brd.buf.engagelock_ref; r[1] = b.engagelock
           if igCheckbox('Engage-lock##brd', r) then b.engagelock = r[1]; settings.save() end
           tip('Opt-in: /attack off the bard while the playlist casts, releasing it to sync normal engage tracking once the cycle is waiting. Off by default so it never fights your combat flags.') end
        imgui.Separator()

        -- Playlists
        local names = geo_mod.brd.playlist_names()
        igText('Playlist:')
        tip('Save / load named playlists. Each captures the song list (per-row M/P/target) AND the four JA toggles.')
        igSameLine(0, 6)
        if #names == 0 then
            igTextDisabled('(none saved)')
        else
            if b.current_playlist ~= geo_mod.brd.buf.last_pl then
                geo_mod.brd.buf.last_pl = b.current_playlist
                local cur = b.current_playlist or ''
                if cur ~= '' then for k, n in ipairs(names) do if n == cur then geo_mod.brd.buf.pl_idx[1] = k - 1; break end end end
            end
            if geo_mod.brd.buf.pl_idx[1] >= #names then geo_mod.brd.buf.pl_idx[1] = 0 end
            geo_mod.spell_combo('##brdpl', names, geo_mod.brd.buf.pl_idx, function() end, 150)
            igSameLine(0, 6)
            if igSmallButton('Load##brdpl') then
                local pn = names[geo_mod.brd.buf.pl_idx[1] + 1]; if pn then geo_mod.brd.load_playlist(pn) end
            end
            tip('Load the selected playlist -- REPLACES the current song list AND JA toggles.')
            igSameLine(0, 4)
            if igSmallButton('Del##brdpl') then
                local pn = names[geo_mod.brd.buf.pl_idx[1] + 1]; if pn then geo_mod.brd.delete_playlist(pn) end
            end
            tip('Delete the selected playlist.')
        end
        igText('Save as:')
        igSameLine(0, 6); imgui.SetNextItemWidth(150)
        -- FIX: same click-away discard as the bard box field above. Lower risk
        -- here since the 'Save' button next to it is an alternate commit path,
        -- but fixing for consistency with num_cell/tier_cell/pull's idiom.
        local brdpl_done = imgui.InputText('##brdplsave', geo_mod.brd.buf.pl_save, 64, ImGuiInputTextFlags_EnterReturnsTrue)
        if not brdpl_done and imgui.IsItemDeactivatedAfterEdit then brdpl_done = imgui.IsItemDeactivatedAfterEdit() end
        if brdpl_done then
            local n = (geo_mod.brd.buf.pl_save[1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
            if n ~= '' then geo_mod.brd.save_playlist(n); geo_mod.brd.buf.pl_save[1] = '' end
        end
        tip('Type a name + Enter (or Save) to snapshot the current playlist + JA toggles.')
        igSameLine(0, 6)
        if igSmallButton('Save##brdplsave') then
            local n = (geo_mod.brd.buf.pl_save[1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
            if n ~= '' then geo_mod.brd.save_playlist(n); geo_mod.brd.buf.pl_save[1] = '' end
        end
        imgui.Separator()

        -- Songs (rows: en | name | M | P | target | ^ | v | x)
        igText(('Songs (%d):'):format(#b.songs))
        local remove_idx, swap_up_idx, swap_dn_idx
        for i, e in ipairs(b.songs) do
            local rb = geo_mod.brd.row_buf(e)
            rb.en[1] = e.enabled ~= false
            if igCheckbox(('##brden%d'):format(i), rb.en) then e.enabled = rb.en[1]; settings.save() end
            tip('Skip this song in the playlist when unchecked.')
            igSameLine(0, 6); igText(e.name)
            igSameLine(0, 12)
            rb.m[1] = e.marcato == true
            if igCheckbox(('M##brdm%d'):format(i), rb.m) then geo_mod.brd.set_marcato(i, rb.m[1]) end
            tip('Marcato (one song only across the playlist) -- fired before this song.')
            igSameLine(0, 4)
            rb.p[1] = e.pianissimo == true
            if igCheckbox(('P##brdp%d'):format(i), rb.p) then geo_mod.brd.set_pianissimo(i, rb.p[1]) end
            tip('Pianissimo -- fired before this song so it single-targets the name in the box to the right.')
            igSameLine(0, 4)
            imgui.SetNextItemWidth(90)
            -- FIX: was flags=0, committing (and settings.save()-ing) on every
            -- keystroke -- the only field in the file that didn't wait for
            -- Enter/focus-loss. Matches num_cell/text_cell/pull's idiom now.
            local tgt_done = imgui.InputText(('##brdt%d'):format(i), rb.t, 16, ImGuiInputTextFlags_EnterReturnsTrue)
            if not tgt_done and imgui.IsItemDeactivatedAfterEdit then tgt_done = imgui.IsItemDeactivatedAfterEdit() end
            if tgt_done then e.target = rb.t[1] or ''; settings.save() end
            tip('Pianissimo single-target name (used only when P is checked).')
            igSameLine(0, 4)
            if igSmallButton(('^##brdup%d'):format(i)) then swap_up_idx = i end
            tip('Move up.')
            igSameLine(0, 2)
            if igSmallButton(('v##brddn%d'):format(i)) then swap_dn_idx = i end
            tip('Move down.')
            igSameLine(0, 4)
            if igSmallButton(('x##brdrm%d'):format(i)) then remove_idx = i end
            tip('Remove from playlist.')
        end
        if swap_up_idx and swap_up_idx > 1 then
            local a, c2 = b.songs[swap_up_idx - 1], b.songs[swap_up_idx]
            b.songs[swap_up_idx - 1], b.songs[swap_up_idx] = c2, a; settings.save()
        end
        if swap_dn_idx and swap_dn_idx < #b.songs then
            local a, c2 = b.songs[swap_dn_idx], b.songs[swap_dn_idx + 1]
            b.songs[swap_dn_idx], b.songs[swap_dn_idx + 1] = c2, a; settings.save()
        end
        if remove_idx then table.remove(b.songs, remove_idx); settings.save() end

        imgui.SetNextItemWidth(160)
        -- FIX: same click-away discard as the bard box field. No alternate
        -- 'Add' button exists for this one, so this was a fully silent failure
        -- mode -- type a song, click the JA row right below it, song never added.
        local brdadd_done = imgui.InputText('##brdaddsong', geo_mod.brd.buf.song_input, 64, ImGuiInputTextFlags_EnterReturnsTrue)
        if not brdadd_done and imgui.IsItemDeactivatedAfterEdit then brdadd_done = imgui.IsItemDeactivatedAfterEdit() end
        if brdadd_done then
            local s = geo_mod.brd.song_from_command((geo_mod.brd.buf.song_input[1] or ''):gsub('%s+$', ''))
            if s then
                local dup = false
                for _, ex in ipairs(b.songs) do if ex.name == s then dup = true; break end end
                if not dup then
                    b.songs[#b.songs + 1] = T{ name = s, enabled = true, marcato = false, pianissimo = false, target = '' }
                    settings.save()
                end
            end
            geo_mod.brd.buf.song_input[1] = ''
        end
        tip('Type a song name and press Enter to add (fuzzy: case/punctuation insensitive).')
        igSameLine(0, 6); igText('(type a song, Enter to add)')
    end
    igEnd()
    if not geo_mod.brd.open[1] then geo_mod.brd.show_window = false; geo_mod.brd.seeded = false end
end)

ashita.events.register('command', 'sync_rdmhelper_listener', function(e)
    local cmd = e.command:lower()
    
    if not cmd:find('/rdmhelper rep', 1, true) then return end
    
    local _, _, name, flags_str, st_str, mj_str, sj_str, sl_str = cmd:find('/rdmhelper rep (%S+) (%d+)%s*(%d*)%s*(%d*)%s*(%d*)%s*(%d*)')
    if name and flags_str then
        e.blocked = true
        local flags = tonumber(flags_str) or 0
        if cached_main and name == cached_main.name_lower then return end
        
        local t = nil
        for _, c in ipairs(chars)  do if c.name_lower == name then t = c; break end end
        if not t then for _, g in ipairs(guests) do if g.name_lower == name then t = g; break end end end

        if t then
            local nowc = os_clock()
            t.last_rep_time = nowc
            local rb = t.rep_buffs
            if not rb then rb = blank_buffs(); t.rep_buffs = rb end
            rb.h       = (bit_band(flags, 1) > 0)
            rb.fl      = (bit_band(flags, 2) > 0)
            rb.r       = (bit_band(flags, 4) > 0)
            rb.p       = (bit_band(flags, 8) > 0)
            rb.pro     = (bit_band(flags, 16) > 0)
            rb.sh      = (bit_band(flags, 32) > 0)
            rb.comp    = (bit_band(flags, 64) > 0)
            rb.larts   = (bit_band(flags, 128) > 0)
            rb.addw    = (bit_band(flags, 256) > 0)
            rb.solace  = (bit_band(flags, 512) > 0)
            rb.majesty = (bit_band(flags, 1024) > 0)
            rb.reraise = (bit_band(flags, 2048) > 0)
            if st_str ~= '' then
                t.status = tonumber(st_str) or 0
                t.last_status_time = nowc
            end
            if mj_str ~= '' then t.job  = tonumber(mj_str) or 0 end
            if sj_str ~= '' then t.sjob = tonumber(sj_str) or 0 end
            if sl_str ~= '' then t.sjlvl = tonumber(sl_str) or 0 end
        end
    end
end)

local COMMAND_LABELS = {
    e   = 'Engage Tracking',
    deb = 'Debuffs',
    buf = 'Buffs',
    heal = 'Cure & Status Removal',
    qs  = 'Quick Step',
    bs  = 'Box Step',
    abs = 'Absorb-TP',
    hs  = 'Haste Samba',
    fl  = 'Flurry II',
    ref = 'Refresh III',
    sil  = 'Silence',
    dist = 'Distract III',
    fraz = 'Frazzle III',
    dia  = 'Dia III',
    face = 'Face-lock'
}

local function log_command_state(cmd, tr)
    local label = COMMAND_LABELS[cmd]
    if not label then return end 

    if tr == 'all' then
        local found_state = "UNKNOWN"
        for _, c in ipairs(chars) do
            if c[cmd] then found_state = c[cmd][1] and 'ON' or 'OFF'; break end
        end
        print(string.format('[sync] %s globally updated to: %s for all active characters.', label, found_state))
    else
        local t = find_target(tr)
        if t and t[cmd] then
            print(string.format('[sync] %s for target character [%s] updated to: %s', label, t.disp_name, (t[cmd][1] and 'ON' or 'OFF')))
        end
    end
end

-- Resolve a preset target token to a live crew name without hardcoding any
-- character name: 'all' passes through, a number is a 1-based crew slot, and
-- 'rdm'/'main' resolve by role from the live roster.
local function preset_target(spec)
    if spec == 'all' then return 'all' end
    if type(spec) == 'number' then return chars[spec] and chars[spec].name_lower or nil end
    if spec == 'rdm'  then return cached_rdm  and cached_rdm.name_lower  or nil end
    if spec == 'main' then return cached_main and cached_main.name_lower or nil end
    return spec
end

-- Preset targets use role/slot tokens (resolved by preset_target) rather than
-- character names: 'all' = everyone, 'rdm' = the RDM box, a number = that crew
-- slot. Keeps presets free of character names.
--

local presets = {
    on = {
        { 'buf', 'all', true },
        { 'deb', 'rdm', true },
        { 'e',   'all', true },
        { 'bs',  3, true },
        { 'hs',  3, true },
        { 'heal','all', true },
        -- Raw commands fired (in order) AFTER the flag toggles above. These go
        -- straight to the chat queue verbatim, so they can drive other addons
        -- (e.g. /mst relays). {rdm}/{main}/{N-slot} tokens resolve to live crew
        -- names; literal names pass through unchanged. Edit freely.
        cmds = {
            '/mst dreepy /roller on',
        },
    },
    off = {
        { 'buf', 'all', false },
        { 'deb', 'rdm', false },
        { 'e',   'all', false },
        { 'bs',  3, false },
        { 'hs',  3, false },
        { 'heal','all', false },
        cmds = {
            '/mst dreepy /roller off',
        },
    },
	cb = {
		{ 'buf', 'all' },
		{ 'heal', 'all' },
	},
	bc = {
		{ 'buf', 'all' },
		{ 'heal', 'all' },
	},
}

ashita.events.register('command', 'cmd_logic', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/sync' then return end
    e.blocked = true
    if #args == 1 then show_ui = not show_ui; return end

    local preset = presets[args[2]:lower()]
    if preset then
        print('[sync] Preset loaded: ' .. args[2]:upper())
        for _, p in ipairs(preset) do
            local tr = preset_target(p[2])
            if tr then
                apply_command(p[1], tr, p[3])
                log_command_state(p[1], tr)
            end
        end
        -- Raw passthrough commands attached to the preset (preset.cmds). Fired
        -- AFTER the flag toggles, verbatim, via the chat queue. {token} markers
        -- resolve through preset_target so presets can stay name-free: {rdm},
        -- {main}, or {N} (1-based crew slot). Unknown tokens / literal names are
        -- left as-is.
        if preset.cmds then
            for _, raw in ipairs(preset.cmds) do
                local out = raw:gsub('{(%w+)}', function(tok)
                    local r = preset_target(tonumber(tok) or tok)
                    return r or ('{' .. tok .. '}')
                end)
                chat:QueueCommand(1, out)
            end
        end
        return
    end

    local a2, a3, a4 = args[2]:lower(), args[3] and args[3]:lower(), args[4] and args[4]:lower()

    if a2 == 'ui' then
        show_ui = (a3 == 'on') or (a3 ~= 'off' and not show_ui)
        return
    end

    if a2 == 'panel' then
        show_buffpanel = (a3 == 'on') or (a3 ~= 'off' and not show_buffpanel)
        return
    end

    if a2 == 'dpanel' then
        show_debuffpanel = (a3 == 'on') or (a3 ~= 'off' and not show_debuffpanel)
        return
    end

    -- /sync combat [on|off]   open/close the Combat panel
    if a2 == 'combat' then
        hunt_mod.show_panel = (a3 == 'on') or (a3 ~= 'off' and not hunt_mod.show_panel)
        return
    end

    -- /sync radius <yalms>    set the hunt acquisition radius
    if a2 == 'radius' then
        local r = tonumber(a3)
        if r and r > 0 then
            config.combat.radius = r
            hunt_mod.radius_buf[1] = r
            settings.save()
            print('[sync] hunt radius = ' .. r .. ' yalms')
        else
            print('[sync] hunt radius = ' .. (config.combat.radius or 12.0) .. ' yalms (usage: /sync radius <n>)')
        end
        return
    end

    -- /sync hunt <name|all> [on|off]   set Hunt mode (distinct-mob pack hunting)
    -- for one or every in-zone box. Converge is panel-only (3-state cycle button
    -- on /sync combat) since this command is a binary on/off.
    -- FIX: this command used to fall through to the generic apply_command path,
    -- which writes c.hunt[1] directly. hunt_mod.run() unconditionally rederives
    -- c.hunt[1] FROM config.combat.huntmode every tick (the real, panel-driven
    -- source of truth), so that write was silently overwritten within one tick
    -- and the command had no lasting effect -- compounded by COMMAND_LABELS
    -- having no 'hunt' entry, so log_command_state printed nothing either.
    -- This now writes config.combat.huntmode directly, same as the panel button.
    if a2 == 'hunt' then
        local tr = a3 or 'all'
        local want
        if a4 == 'on' then want = 1 elseif a4 == 'off' then want = 0 end
        if tr == 'all' then
            if want == nil then
                -- Mirror apply_command's bare-toggle convention: peek at the
                -- first in-zone box's current mode and apply that flipped state
                -- to everyone, rather than each box toggling off its own state.
                for _, c in ipairs(chars) do
                    if c.in_zone then
                        want = ((config.combat.huntmode[c.name_lower] or 0) > 0) and 0 or 1
                        break
                    end
                end
                want = want or 1
            end
            for _, c in ipairs(chars) do
                if c.in_zone then
                    config.combat.huntmode[c.name_lower] = want
                    c.hunt[1] = (want > 0)
                end
            end
            settings.save()
            print('[sync] hunt mode (all) -> ' .. (want > 0 and 'Hunt' or 'Off') .. '  (Converge: cycle via the Combat panel button)')
        else
            local t = find_target(tr)
            if not t then print('[sync] hunt: no target matching "' .. tr .. '"'); return end
            if want == nil then want = ((config.combat.huntmode[t.name_lower] or 0) > 0) and 0 or 1 end
            config.combat.huntmode[t.name_lower] = want
            t.hunt[1] = (want > 0)
            settings.save()
            print('[sync] hunt mode [' .. t.disp_name .. '] -> ' .. (want > 0 and 'Hunt' or 'Off'))
        end
        return
    end

    -- /sync faced [reset]   calibrate facing to this build's heading convention
    if a2 == 'faced' then
        hunt_mod.calibrate(mm:GetParty(), mm:GetEntity(), mm:GetTarget(), a3)
        return
    end

    -- /sync sing [on|off]   master bard toggle (resets the cycle on either edge)
    if a2 == 'sing' then
        local target
        if a3 == 'on' then target = true
        elseif a3 == 'off' then target = false
        else target = not config.brd.sing end
        geo_mod.brd.set_sing(target)
        print('[sync] BRD singing ' .. (config.brd.sing and 'on' or 'off'))
        return
    end

    -- /sync brd ...   bard window + playlist + config (Singer folded into sync).
    --   bare              toggle the Bard window
    --   box <name>        set the bard box (also bare /sync brd <name>)
    --   add <song> | remove <n|song> | clear | move <n|song> up|down
    --   marcato <n|song> [on|off] | pianissimo <n|song> [target|off] | target <n|song> <name>
    --   nightingale|troubadour|soul_voice|clarion|announce|engagelock [on|off]
    --   delay <s> | interval <MM:SS|s> | playlist save|load|delete|list [name]
    --   reset | save
    if a2 == 'brd' then
        if not a3 then geo_mod.brd.show_window = not geo_mod.brd.show_window; return end
        local function joinfrom(i)
            local t = {} for k = i, #args do t[#t+1] = args[k] end return table.concat(t, ' ')
        end
        local function resolve_idx(arg)
            local n = tonumber(arg)
            if n and config.brd.songs[n] then return n end
            local s = geo_mod.brd.song_from_command(arg)
            if s then for i, e in ipairs(config.brd.songs) do if e.name == s then return i end end end
        end
        -- FIX: move/marcato/pianissimo/target used to resolve_idx(args[4]) alone,
        -- i.e. only the FIRST WORD of the song reference -- but almost every BRD
        -- song name contains a space or apostrophe ("Mage's Ballad", "Hunter's
        -- Prelude", "Valor Minuet"...), so by-name lookups on these four
        -- subcommands silently failed for virtually any real song (the numeric
        -- index was the only thing that actually worked). This tries the longest
        -- possible join first (args[from..#args]) and peels one trailing token
        -- (direction / on-off / target name) off the end until a song matches.
        -- Returns idx, trailing (trailing is nil if nothing was left over).
        local function resolve_idx_trailing(from)
            for cut = #args, from, -1 do
                local idx = resolve_idx(table.concat(args, ' ', from, cut))
                if idx then
                    local trailing = (cut < #args) and table.concat(args, ' ', cut + 1, #args) or nil
                    return idx, trailing
                end
            end
            return nil, nil
        end
        local jatoggles = { nightingale = true, troubadour = true, soul_voice = true,
                            clarion = true, announce = true, engagelock = true, debug = true }

        if a3 == 'box' then
            config.brd.character = (args[4] or ''):gsub('%s', ''):lower()
            if config.brd.character == 'off' or config.brd.character == 'none' then config.brd.character = '' end
            geo_mod.brd.buf.character[1] = config.brd.character
            settings.save()
            print('[sync] BRD box = ' .. (config.brd.character == '' and '(disabled)' or config.brd.character))

        elseif a3 == 'reset' then
            geo_mod.brd.reset_cycle(); print('[sync] BRD cycle reset')

        elseif a3 == 'save' then
            settings.save(); print('[sync] BRD saved')

        elseif jatoggles[a3] then
            if a4 == 'on' then config.brd[a3] = true
            elseif a4 == 'off' then config.brd[a3] = false
            else config.brd[a3] = not config.brd[a3] end
            settings.save()
            print(('[sync] BRD %s %s'):format(a3, config.brd[a3] and 'on' or 'off'))

        elseif a3 == 'delay' and args[4] then
            local n = tonumber(args[4])
            if n then config.brd.delay = n; settings.save(); print(('[sync] BRD delay %.1f'):format(n)) end

        elseif (a3 == 'interval' or a3 == 'cycle') and args[4] then
            local n = geo_mod.parse_mmss(args[4])
            if n and n >= 15 and n <= 3600 then
                config.brd.interval = n; settings.save()
                print('[sync] BRD cycle interval ' .. geo_mod.fmt_mmss(n))
            else
                print('[sync] BRD interval: <MM:SS> or seconds (15..3600)')
            end

        elseif a3 == 'add' and args[4] then
            local s = geo_mod.brd.song_from_command(joinfrom(4))
            if not s then print('[sync] BRD: invalid song "' .. joinfrom(4) .. '"'); return end
            for _, ex in ipairs(config.brd.songs) do
                if ex.name == s then print('[sync] BRD: already in playlist: ' .. s); return end
            end
            config.brd.songs[#config.brd.songs + 1] = T{ name = s, enabled = true, marcato = false, pianissimo = false, target = '' }
            settings.save(); print('[sync] BRD added ' .. s)

        elseif a3 == 'remove' and args[4] then
            local idx = resolve_idx(joinfrom(4))
            if idx then
                local nm = config.brd.songs[idx].name
                table.remove(config.brd.songs, idx); settings.save(); print('[sync] BRD removed ' .. nm)
            else
                print('[sync] BRD: not in playlist: ' .. joinfrom(4))
            end

        elseif a3 == 'clear' then
            for i = #config.brd.songs, 1, -1 do config.brd.songs[i] = nil end
            settings.save(); print('[sync] BRD playlist cleared')

        elseif a3 == 'move' and args[4] then
            local idx, trailing = resolve_idx_trailing(4)
            if not idx then print('[sync] BRD: not in playlist: ' .. joinfrom(4)); return end
            local dir = trailing and trailing:lower() or ''
            local songs = config.brd.songs
            if dir == 'up' and idx > 1 then
                songs[idx - 1], songs[idx] = songs[idx], songs[idx - 1]; settings.save(); print('[sync] BRD moved up')
            elseif dir == 'down' and idx < #songs then
                songs[idx], songs[idx + 1] = songs[idx + 1], songs[idx]; settings.save(); print('[sync] BRD moved down')
            else
                print('[sync] BRD move: <n|song> up|down (already at edge?)')
            end

        elseif a3 == 'marcato' and args[4] then
            local idx, trailing = resolve_idx_trailing(4)
            if not idx then print('[sync] BRD: not in playlist: ' .. joinfrom(4)); return end
            local on
            if trailing then on = (trailing:lower() == 'on') else on = not config.brd.songs[idx].marcato end
            geo_mod.brd.set_marcato(idx, on)
            print(('[sync] BRD Marcato %s on %s'):format(on and 'on' or 'off', config.brd.songs[idx].name))

        elseif a3 == 'pianissimo' and args[4] then
            local idx, trailing = resolve_idx_trailing(4)
            if not idx then print('[sync] BRD: not in playlist: ' .. joinfrom(4)); return end
            if trailing and trailing:lower() == 'off' then
                geo_mod.brd.set_pianissimo(idx, false)
                print('[sync] BRD Pianissimo off on ' .. config.brd.songs[idx].name)
            else
                local tgt = trailing or config.brd.songs[idx].target or ''
                geo_mod.brd.set_pianissimo(idx, true)
                config.brd.songs[idx].target = tgt; settings.save()
                print(('[sync] BRD Pianissimo on %s -> %s'):format(config.brd.songs[idx].name, tgt))
            end

        elseif a3 == 'target' and args[4] then
            local idx, trailing = resolve_idx_trailing(4)
            if not idx or not trailing then
                print('[sync] BRD: not in playlist (or missing target name): ' .. joinfrom(4))
            else
                config.brd.songs[idx].target = trailing; settings.save()
                print(('[sync] BRD target on %s -> %s'):format(config.brd.songs[idx].name, trailing))
            end

        elseif a3 == 'playlist' then
            local sub = a4
            if sub == 'save' and args[5] then geo_mod.brd.save_playlist(joinfrom(5))
            elseif sub == 'load' and args[5] then geo_mod.brd.load_playlist(joinfrom(5))
            elseif sub == 'delete' and args[5] then geo_mod.brd.delete_playlist(joinfrom(5))
            else
                local n = geo_mod.brd.playlist_names()
                if #n == 0 then print('[sync] BRD: no saved playlists')
                else print('[sync] BRD playlists: ' .. table.concat(n, ', ')) end
            end

        else
            -- bare /sync brd <name>: treat an unrecognised first token as a box name.
            config.brd.character = a3:gsub('%s', ''):lower()
            if config.brd.character == 'off' or config.brd.character == 'none' then config.brd.character = '' end
            geo_mod.brd.buf.character[1] = config.brd.character
            settings.save()
            print('[sync] BRD box = ' .. (config.brd.character == '' and '(disabled)' or config.brd.character))
        end
        return
    end

    -- /sync camp [set|clear]   campsite return
    --   /sync camp set    save the main's current position as the campsite
    --   /sync camp        send the crew back to the saved campsite
    --   /sync camp clear  forget the saved campsite
    if a2 == 'camp' then
        if a3 == 'set' then
            hunt_mod.camp_set()
        elseif a3 == 'clear' then
            config.combat.camp_set = false; settings.save(); print('[sync] campsite cleared')
        else
            hunt_mod.camp_go()
        end
        return
    end

    -- /sync tname   print the current target's EXACT name + index (copy into the
    -- whitelist/blacklist verbatim -- in-game display can differ on apostrophes).
    if a2 == 'tname' then
        local ti = get_target_index(mm:GetTarget())
        if ti == 0 then print('[sync] no target'); return end
        local em = mm:GetEntity()
        print(string.format('[sync] target: "%s"  (idx %d)', em:GetName(ti) or '?', ti))
        return
    end

    -- /sync bl [add <name> | rm <n> | clear]   manage the global blacklist.
    -- Bare /sync bl lists what is stored so you can verify exact spelling.
    if a2 == 'bl' then
        local B = config.combat.blacklist
        if a3 == 'add' then
            local nm = e.command:match('^/sync%s+bl%s+add%s+(.+)$')
            nm = nm and nm:gsub('%s+$', '') or ''
            if nm ~= '' then table.insert(B, nm); settings.save(); print('[sync] blacklisted: ' .. nm) end
        elseif a3 == 'rm' then
            local n = tonumber(a4)
            if n and B[n] then local g = B[n]; table.remove(B, n); settings.save(); print('[sync] removed: ' .. g) end
        elseif a3 == 'clear' then
            for i = #B, 1, -1 do B[i] = nil end; settings.save(); print('[sync] blacklist cleared')
        else
            if #B == 0 then print('[sync] blacklist empty')
            else
                print('[sync] blacklist (' .. #B .. '):')
                for i = 1, #B do print(string.format('  %d. %s', i, B[i])) end
            end
        end
        return
    end


    -- /sync geo ...   GEO scheduler controls (mirror of the panel).
    --   /sync geo                  toggle the Geomancer panel
    --   /sync geo on|off           bring panel up/down
    --   /sync geo char <name>      set the GEO box ('' / off = disable)
    --   /sync geo indi <spell>     set Indi-X (suffix only, e.g. "haste")
    --   /sync geo geo  <spell>     set Geo-X
    --   /sync geo en   <spell>     set entrust Indi-X
    --   /sync geo entarg <name>    set entrust target (party member name)
    --   /sync geo gtarg <name>     set Geo bubble target (party or mob name)
    --   /sync geo gmode party|mob  switch Geo bubble target mode
    --   /sync geo bog|ea|demat on|off
    --   /sync geo set <name>       load a saved spell set
    --   /sync geo save <name>      snapshot current slots as a named set
    --   /sync geo sets             list saved set names
    if a2 == 'geo' then
        local g = config.geo
        if not g then return end
        if not a3 then
            geo_mod.show_panel = not geo_mod.show_panel
            return
        end
        if a3 == 'on'  then
            config.geo.active = true
            geo_mod.buf.active[1] = true
            settings.save()
            print('[sync] geo casting enabled')
            return
        end
        if a3 == 'off' then
            config.geo.active = false
            geo_mod.buf.active[1] = false
            settings.save()
            print('[sync] geo casting disabled')
            return
        end

        local a5 = args[5] and args[5]:lower() or nil

        if a3 == 'char' then
            g.character = (args[4] or ''):gsub('%s', ''):lower()
            if g.character == 'off' or g.character == 'none' then g.character = '' end
            settings.save(); geo_mod.seeded = false
            print('[sync] geo char = ' .. (g.character == '' and '(disabled)' or g.character))
            return
        end

        local slot_key = ({indi='indi', geo='geo', en='entrust', entrust='entrust'})[a3]
        if slot_key and a4 then
            local list = (slot_key == 'geo') and geo_mod.geo_spells or geo_mod.indi_spells
            local prefix = (slot_key == 'geo') and 'Geo-' or 'Indi-'
            -- Accept either "haste" (suffix) or "Indi-Haste" (full).
            local query = args[4]
            local target = nil
            local q_lower = query:lower()
            for i = 1, #list do
                local nm = list[i]
                if nm:lower() == q_lower or nm:lower() == (prefix .. query):lower()
                   or nm:sub(#prefix + 1):lower() == q_lower then
                    target = nm; break
                end
            end
            if target then
                g[slot_key].spell = target
                settings.save()
                geo_mod[slot_key].wear_at = 0
                geo_mod.seeded = false
                print(('[sync] geo %s = %s'):format(slot_key, target))
            else
                print('[sync] geo: unknown ' .. slot_key .. ' spell "' .. query .. '"')
            end
            return
        end

        if a3 == 'entarg' then
            g.entrust.target = (args[4] or ''):gsub('%s', '')
            settings.save(); geo_mod.seeded = false
            print('[sync] geo entrust target = '
                  .. (g.entrust.target == '' and '(none)' or g.entrust.target))
            return
        end
        if a3 == 'gtarg' then
            g.geo.target = (args[4] or ''):gsub('%s', '')
            settings.save(); geo_mod.seeded = false
            print('[sync] geo bubble target = '
                  .. (g.geo.target == '' and '(default <bt>/<me>)' or g.geo.target))
            return
        end
        if a3 == 'gmode' and (a4 == 'party' or a4 == 'mob') then
            g.geo.target_mode = a4
            settings.save(); geo_mod.seeded = false; geo_mod.geo.wear_at = 0
            print('[sync] geo bubble mode = ' .. a4)
            return
        end

        local ja_key = ({bog='bog', ea='ea', demat='demat'})[a3]
        if ja_key then
            local on  = (a4 == 'on')
            local off = (a4 == 'off')
            if on or off then g.ja[ja_key] = on else g.ja[ja_key] = not g.ja[ja_key] end
            settings.save(); geo_mod.seeded = false
            print(('[sync] geo %s = %s'):format(ja_key, g.ja[ja_key] and 'on' or 'off'))
            return
        end

        if a3 == 'set' and a4 then
            local q = args[4]:lower()
            for i = 1, #(g.sets or {}) do
                if (g.sets[i].name or ''):lower() == q then
                    geo_mod.load_set(i)
                    print('[sync] geo set loaded: ' .. g.sets[i].name)
                    return
                end
            end
            print('[sync] geo: no set named "' .. args[4] .. '"')
            return
        end
        if a3 == 'save' and a4 then
            geo_mod.save_set(args[4])
            print('[sync] geo set saved: ' .. args[4])
            return
        end
        if a3 == 'sets' then
            local names = geo_mod.set_names()
            if #names == 0 then
                print('[sync] geo: no saved sets')
            else
                print('[sync] geo sets: ' .. table.concat(names, ', '))
            end
            return
        end

        print('[sync] geo: unknown subcommand "' .. a3 .. '" (try: char/indi/geo/en/entarg/gtarg/gmode/bog/ea/demat/set/save/sets)')
        return
    end

	-- /sync regen -- one-shot stratagem combos on the main healer. The
    -- healer is reserved for the whole window so a routine Cure can't consume the
    -- Accession charge before the buffed spell lands.
    -- regen: Accession, ~1.0s, Regen IV <me> (AoE party Regen IV).
    if a2 == 'r4' then
        local h = resolve_healer((config.healers[1] and config.healers[1].name or ''):lower())
        if not h then
            print('[sync]: main healer not available (in zone + partied required)')
            return
        end
        
        local now = os_clock()
        local rd  = get_cast_delay("Regen IV")
        do_action(h, '/ja "Accession" <me>', 1.0, now)
        h.cast_reserved_until = now + 1.0 + rd + 0.5
        queue_cast(h, '/ma "Regen IV" <me>', now + 1.0, rd)
        print(('[sync] %s -> Accession + Regen IV (party)'):format(h.disp_name))
        
        return
    end

    ------------------------------------------------------------
    -- DISENGAGE MECHANISM
    ------------------------------------------------------------
    if a2 == 'dis' then
        local tr = a3 or 'all'
        if tr == 'all' then
            print('[sync] Command Execution: Halting auto-engage tracking across ALL instances.')
            for _, c in ipairs(chars) do
                if not c.is_main then
                    c.e[1]               = false -- Unconditionally clean tracking flag states
                    c.auto_engaged       = false
                    c.last_engage_target = 0
                    c.last_engage_time   = 0
                    c.retry              = nil

                    -- Triple command burst to fight past animation lock states.
                    -- FIX: was coroutine.sleep(0.15) between each QueueCommand --
                    -- the only coroutine.sleep in the whole file, and a blocking
                    -- call here would stall the event thread for up to ~1.2s
                    -- across a full crew (4 alts x 0.3s). Queued through the
                    -- existing pending_casts pipeline (drained every logic tick)
                    -- instead, matching every other timed sequence in this file.
                    chat:QueueCommand(1, c.cmd_attack_off)
                    queue_cast(c, '/attack off', os_clock() + 0.15)
                    queue_cast(c, '/attack off', os_clock() + 0.30)
                end
            end
            print('[sync] Action Verified: Disengage signals issued; internal auto-engage flags wiped clean.')
        else
            local t = find_target(tr)
            if t and not t.is_main then
                print(string.format('[sync] Command Execution: Disengaging target window [%s].', t.disp_name))
                t.e[1]               = false
                t.auto_engaged       = false
                t.last_engage_target = 0
                t.last_engage_time   = 0
                t.retry              = nil

                chat:QueueCommand(1, t.cmd_attack_off)
                queue_cast(t, '/attack off', os_clock() + 0.15)
                queue_cast(t, '/attack off', os_clock() + 0.30)
                print(string.format('[sync] Action Verified: [%s] disengage burst queued; tracking reset.', t.disp_name))
            else
                print('[sync] Warning: Specified character target to disengage was missing or invalid.')
            end
        end
        return
    end

    local DEBUFF_TOGGLES = { silence='sil', sil='sil', distract='dist', dist='dist', frazzle='fraz', fraz='fraz', dia='dia' }
    local dtog = DEBUFF_TOGGLES[a2]
    if dtog then
        local rdmc = cached_rdm
        if rdmc then
            local on  = (a3 == 'on')  or (a4 == 'on')
            local off = (a3 == 'off') or (a4 == 'off')
            local state = on and true or (off and false or nil)
            apply_command(dtog, rdmc.name_lower, state)
            log_command_state(dtog, rdmc.name_lower)
        end
        return
    end

    local cmds = { f='f', e='e', d='deb', buf='buf', b='buf', qs='qs', bs='bs',
                   abs='abs', hs='hs', fl='fl', ref='ref', heal='heal', c='heal',
                   face='face' }
    local cmd, tr, st
    if cmds[a2] then cmd, tr, st = cmds[a2], a3 or 'all', a4 else cmd, tr, st = a3 and cmds[a3], a2, a4 end

    local state = (st == 'on') and true or ((st == 'off') and false or nil)
    apply_command(cmd, tr, state)
    
    log_command_state(cmd, tr)
end)

ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on', true)
    qcmd('/mso /ms follow on', true)
    qcmd('/mss /addon load rdmhelper', true)
end)

ashita.events.register('unload', 'sync_unload', function()
    qcmd('/ms followme off', true)
    qcmd('/mso /ms follow off', true)
    qcmd('/mss /addon unload rdmhelper', true)
end)