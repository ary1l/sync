addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '1.8'
addon.desc    = 'sync'

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- LUA / API OPTIMIZATIONS
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

local COLOR_OFFLINE = {1.0, 0.2, 0.2, 1.0}
local COLOR_BUSY    = {1.0, 0.8, 0.0, 1.0}
local COLOR_GUEST   = {0.6, 0.9, 1.0, 1.0}
local COLOR_RECOVERING = {0.4, 0.6, 1.0, 1.0}

local SYNC_WINDOW_FLAGS = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)

local SYNC_WINDOW_OPEN  = {true}

------------------------------------------------------------
-- CONFIGURATION & DICTIONARIES
------------------------------------------------------------
local show_ui = true
local show_guests = true
-- NOTE(healers): both cast concurrently. main_healer does routine healing +
-- status removal; backup_healer is a safety net with a lower cure threshold
-- (and only takes over status removal when main is down/silenced). Set ''/'off'
-- to disable backup. Switch with `/sync healer <name>` and `/sync backup <name>`.
local main_healer   = 'slowpoke'   -- WHM (Yagrush)
local backup_healer = 'goomy'      -- RDM fallback
local rep_dbg = false   -- toggle with /sync dbg (prints incoming /rdmhelper rep)
local heal_dbg = false  -- toggle with /sync hdbg (dumps heal HP% + raw status ids)

local ENGAGE_RETRY_GAP = 0.5
local RETRY_DELAY      = 0.7
local FOLLOW_SETTLE    = 0.5

local BUFF_IDS = {
    HASTE = 33, PROTECT = 40, SHELL = 41, REFRESH = 43,
    PHALANX = 116, FLURRY = 265, HASTE_SAMBA = 370, COMPOSURE = 419,
    LIGHT_ARTS = 358, ADDENDUM_WHITE = 401, AFFLATUS_SOLACE = 417
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
}

local chars = {
    { name='shaymin',  is_main=true, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, heal={false}, fl={false}, ref={false} },
    { name='goomy',    is_rdm=true,  f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, heal={false}, fl={false}, ref={false} },
    { name='muunch',                 f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, heal={false}, fl={false}, ref={false} },
    { name='slowpoke',               f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, heal={false}, fl={false}, ref={false} },
    { name='dreepy',                 f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, heal={false}, fl={false}, ref={false} },
}

local BUFF_PRIORITY = {"h","r","pro","sh","p"}
local RDM_SELF_FIRST = {"h","r"}
local COMBAT_FLAG_KEYS = {'e', 'hs', 'bs', 'qs', 'abs', 'deb', 'buf', 'heal', 'fl', 'ref'}

local guests = {}
local current_active = {}
local known_cores = {}
local debuff_queue = {}
local slot_addr = {}

local cached_rdm  = nil
local cached_main = nil

local last_engage_target = 0

local ui_columns = {
    { label = 'F', key = 'f',   allow_main = false, rdm_only = false },
    { label = 'E', key = 'e',   allow_main = false, rdm_only = false },
    { label = 'H', key = 'hs',  allow_main = false, rdm_only = false },
    { label = 'B', key = 'bs',  allow_main = false, rdm_only = false },
    { label = 'Q', key = 'qs',  allow_main = false, rdm_only = false },
    { label = 'A', key = 'abs', allow_main = false, rdm_only = false },
    { label = 'D', key = 'deb', allow_main = false, rdm_only = true  },
    { label = 'B', key = 'buf', allow_main = true,  rdm_only = false },
    { label = 'C', key = 'heal', allow_main = true, rdm_only = false }
}

local NUM_UI_COLS = #ui_columns

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function blank_buffs()
    return { h=false, r=false, p=false, fl=false, comp=false, pro=false, sh=false, samba=false,
             larts=false, addw=false, solace=false }
end

local function get_debuff_queue(targetIdx, rdm)
    if not targetIdx or targetIdx == 0 then return {} end
    if not debuff_queue[targetIdx] then
        local q = {}
        if rdm and rdm.sil  and rdm.sil[1]  then t_insert(q, { name="Silence",      done=false }) end
        t_insert(q, { name="Dia III", done=false })
        if rdm and rdm.fraz and rdm.fraz[1] then t_insert(q, { name="Frazzle III",  done=false }) end
        if rdm and rdm.dist and rdm.dist[1] then t_insert(q, { name="Distract III", done=false }) end
        debuff_queue[targetIdx] = q
    end
    return debuff_queue[targetIdx]
end

local BUFF_RETRY_GAP = 15.0
local RDM_FAST_CAST  = 0.50
local ANIMATION_LOCK = 2.75

local SPELL_CAST_TIMES = {
    ["Refresh III"] = 3.0,   ["Distract III"] = 3.0,
    ["Haste II"] = 3.0,      ["Phalanx II"] = 3.0,
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
    c.retry = { cmd = cmd, time = now + RETRY_DELAY, is_attack = cmd:find('/attack', 1, true) ~= nil }
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
    c.job              = 0
    c.sjob             = 0
    c.sjlvl            = 0
    c._kit_mj          = -1
    c._kit_sj          = -1
    c.buff_locks   = {}
    c.low_mp_mode  = false
    c.emergency_refresh = false
    c.in_zone      = false
    c.actual_follow = nil
    c.buffs = blank_buffs()
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
    if c.is_rdm then
        c.sil  = c.sil  or {false}
        c.dist = c.dist or {false}
        c.fraz = c.fraz or {false}
    end
    for _, col in ipairs(ui_columns) do
        c.ui_ids[col.key] = '##' .. col.key .. '_' .. c.name_lower
    end
    if c.is_rdm  then cached_rdm  = c end
    if c.is_main then cached_main = c end
end

for _, c in ipairs(chars) do init_char_state(c); known_cores[c.name_lower] = true end

------------------------------------------------------------
-- RDM HELPER FUNCTIONS
------------------------------------------------------------
local function check_needs(t, key, rdm, now)
    if not t or not t.in_zone or not t.pt_data or not t.buf or not t.buf[1] then return false end

    local is_self = (t.name_lower == rdm.name_lower)

    if key == 'comp' and rdm.buffs.comp then return false end

    if (key == 'r' or key == 'p') and not is_self then
        if not rdm.pt_data or not t.pt_data then return false end
        
        local rdm_party_group = math_floor(rdm.pt_data.index / 6)
        local t_party_group   = math_floor(t.pt_data.index / 6)
        
        if rdm_party_group ~= t_party_group then
            return false
        end
    end

    local want = key
    if key == 'h' and t.fl and t.fl[1] then want = 'fl' end
    
    if t.buffs and t.buffs[want] then return false end

    if key == 'r' and not is_self and not (t.ref and t.ref[1]) then return false end

    local locks = rdm.buff_locks[t.name]
    if not locks then locks = {}; rdm.buff_locks[t.name] = locks end
    if now - (locks[key] or 0) < BUFF_RETRY_GAP then return false end

    return true
end

------------------------------------------------------------
-- HEAL (CURE + CURAGA + STATUS REMOVAL)
-- `heal` is a RECIPIENT flag (like `buf`): healers cure / -na any in-zone member
-- that has it set. Two healers run concurrently (see main_healer/backup_healer):
--   main   -> full kit (Curaga, Divine Seal, status removal) at CURE_THRESHOLD
--   backup -> safety net at BACKUP_CURE_THRESHOLD; -na only if main is unavailable
--
-- Cures use party HP% (alliance-wide, near real-time) so they cross parties.
-- Curaga only heals the CASTER's own party, so it is gated to the healer's party
-- group. Status removal reads each recipient's `t.status` bitfield (rdmhelper
-- reports; main reads its own locally) and -na ignores party lines.
--
-- WHM specifics: Cure->Cure V, Curaga->Curaga V, Divine Seal (potency burst),
-- Afflatus Solace (cure stance). RDM caps at Cure IV and has no Curaga/JAs.
------------------------------------------------------------
-- NOTE: cure thresholds (mutable via `/sync thr main|backup <pct>`).
local CURE_THRESHOLD        = 87.5
local BACKUP_CURE_THRESHOLD = 70
local EMERGENCY_PCT  = 40    -- NOTE: at/below this the main WHM pops Divine Seal
local CURE_MIN_MP    = 40    -- NOTE: skip cures below this when MP is readable
local CURE_RETRY_GAP = 5.0   -- NOTE: per-target re-cure guard (HP table latency)
local WAKE_MIN_MP    = 12    -- NOTE: waking a sleeper is urgent; keep this low so a
                             -- wake is NOT blocked by the routine CURE_MIN_MP floor.
local NA_MIN_MP      = 12
local NA_RETRY_GAP   = 4.0   -- NOTE: per-(target,status) re-cast guard
local CHARM_SLEEP_GAP = 8.0  -- NOTE: RDM Sleep II re-cast guard on a charmed member
local CHARM_SLEEP_MAX   = 3    -- NOTE: max Sleep II attempts per charm episode before the RDM
                               -- gives up. A member that resists every cast, or is woken
                               -- instantly by a DoT, can't be kept down -- stop cycling Sleep.
local CHARM_SLEEP_STUCK = 8.0  -- NOTE: a Sleep that HOLDS this long is treated as working and
                               -- refunds the attempt budget, so a long charm keeps getting
                               -- re-slept on each natural wake. Sits above the DoT tick (~3s)
                               -- and below Sleep II's duration.
local CURAGA_MIN_TARGETS = 2 -- NOTE: injured same-party members to prefer Curaga
local DIVINE_SEAL_RECAST = 240.0  -- NOTE: tune to your merited DS recast
local USE_AFFLATUS_SOLACE = true  -- NOTE: WHM healers maintain Solace stance (/sync solace)
local USE_SCH_STANCES     = true  -- NOTE: /SCH healers maintain Light Arts + Addendum: White
                                  -- (/sync arts). Turning this OFF also disables /SCH -na,
                                  -- which requires Addendum: White to be up.
local STANCE_GUARD        = 8.0   -- NOTE: recast-suppression after a stance cast -- covers JA
                                  -- animation + buff registration so we never re-fire mid-land.
local STANCE_READABLE_GAP = 5.0   -- NOTE: cross-party report freshness for stance gating
local STANCE_LOSS_DEBOUNCE = 4.0  -- FIX: a stance must read ABSENT continuously for this long
                                  -- (since it was last SEEN up) before it is re-cast, so an
                                  -- already-up stance is never re-used on a transient read /
                                  -- report miss. Only a genuine loss (or a zone) re-fires it.
local SILENCE_ITEM     = "Echo Drops"  -- NOTE: or "Remedy"
local SILENCE_ITEM_GAP = 15.0          -- NOTE: medicine recast guard

-- Cap-based spell selection: tier picked by HP% then clamped to the job's max.
local CURE_NAME   = { [1]="Cure", [2]="Cure II", [3]="Cure III", [4]="Cure IV", [5]="Cure V", [6]="Cure VI" }
local CURAGA_NAME = { [1]="Curaga", [2]="Curaga II", [3]="Curaga III", [4]="Curaga IV", [5]="Curaga V" }

-- NOTE(cure tiers): per-tier HP% breakpoints. The FIRST row whose pct >= the
-- target's current HP% wins, so lower (more-damaged) rows take precedence. Edit
-- the pct column to tune where each tier kicks in; the spell tier is then clamped
-- to the caster's job cap. Rows MUST stay ordered low pct -> high pct.
local CURE_TIERS = {   -- { at_or_below_HP%, cure tier }
    {  45, 6 },        -- <= 45% -> Cure VI  (flat enmity, biggest heal)
    {  55, 5 },        -- <= 55% -> Cure V
    {  70, 4 },        -- <= 70% -> Cure IV
    {  77.5, 3 },        -- <= 77.5% -> Cure III
    {  82.5, 2 },        -- <= 82.5%    -> Cure II
	{ 100, 1 }           -- else cure1
}
local CURAGA_TIERS = { -- { at_or_below_HP%, curaga tier }
    {  40, 5 },        -- <= 40% -> Curaga V
    {  50, 4 },        -- <= 50% -> Curaga IV
    {  65, 3 },        -- <= 65% -> Curaga III
    {  80, 2 },        -- <= 75% -> Curaga II
	{ 82.5, 1 },       -- <= 82.5% -> Curaga I
}

-- Pick the tier for a HP%, clamped to [1, cap]. cap is the job's max tier.
local function tier_for(tiers, pct, cap)
    local n = tiers[#tiers][2]
    for _, row in ipairs(tiers) do
        if pct <= row[1] then n = row[2]; break end
    end
    if n > cap then n = cap end
    if n < 1   then n = 1   end
    return n
end

local function cure_spell_for(pct, cap)
    return CURE_NAME[tier_for(CURE_TIERS, pct, cap)]
end

local function curaga_spell_for(pct, cap)
    return CURAGA_NAME[tier_for(CURAGA_TIERS, pct, cap)]
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
        ds      = (m and m.ds) or false,
        solace  = (m and m.solace) or false,
        na_now  = na_now,
        na_arts = na_arts,
        sch     = (mj == JOB_SCH) or (sj == JOB_SCH),  -- needs Light Arts + Addendum
        accession = (mj == JOB_SCH) or (sj == JOB_SCH and (sjlvl or 0) >= 40),  -- SCH Accession (lv40)
    }
end

-- NOTE(status ids): MUST stay identical to rdmhelper's copy.
-- Bits 1..128 are the dedicated -na ailments; bit 256 is the aggregate "an
-- Erase-removable effect is present" (Erase removes one detrimental effect,
-- so we only need to know at least one exists).
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

-- Resolve a healer's (main job, sub job, sub level). main box reads itself;
-- others come from rdmhelper reports, with a guarded party-API fast path. The
-- sub LEVEL is what makes access Master-Level-aware (ML raises the sub cap).
local function healer_jobs(healer, party, player)
    if healer == cached_main then
        return player:GetMainJob() or 0, player:GetSubJob() or 0, player:GetSubJobLevel() or 0
    end
    local mj, sj, sl = healer.job or 0, healer.sjob or 0, healer.sjlvl or 0
    if mj == 0 and healer.pt_data and healer.pt_data.index < 6 then
        local idx = healer.pt_data.index
        local ok, m = pcall(function() return party:GetMemberMainJob(idx) end)
        if ok and m and m > 0 then
            mj = m
            local ok2, s = pcall(function() return party:GetMemberSubJob(idx) end)
            if ok2 and s then sj = s end
            local ok3, l = pcall(function() return party:GetMemberSubJobLevel(idx) end)
            if ok3 and l and l > 0 then sl = l end
        end
    end
    return mj, sj, sl
end

-- One action per tick from one healer. `threshold` gates cures/curaga; `do_status`
-- enables -na; `do_wake` enables waking sleepers; `is_primary` allows Divine Seal.
-- Kit is derived from the healer's live main+sub job.
local function heal_pass(healer, party, player, now, threshold, do_status, do_wake, is_primary)
    if now < (healer.cast_reserved_until or 0) then return false end
    local mj, sj, sjlvl = healer_jobs(healer, party, player)
    local prof = build_profile(mj, sj, sjlvl)
    if not prof then return false end   -- assigned healer isn't on a healing job

    -- Re-allow stance setup when the job changes (incl. first detection).
    if healer._kit_mj ~= mj or healer._kit_sj ~= sj then
        healer._kit_mj, healer._kit_sj = mj, sj
        healer.solace_lock = 0; healer.solace_seen = 0
        healer.larts_lock  = 0; healer.larts_seen  = 0
        healer.addw_lock   = 0; healer.addw_seen   = 0
    end

    -- 0. SELF-SILENCE -- magic is locked out; clear it with an item (items work
    -- while silenced). Wait it out afterwards.
    if bit_band(healer.status or 0, SILENCE_BIT) ~= 0 then
        if now >= (healer.silence_item_lock or 0) then
            healer.silence_item_lock = now + SILENCE_ITEM_GAP
            if heal_dbg then print(('[sync] %s -> %s <me> (silenced)'):format(healer.disp_name, SILENCE_ITEM)) end
            do_action(healer, '/item "' .. SILENCE_ITEM .. '" <me>', 2.0, now)
        end
        return true
    end

    -- 1. STANCES -- /SCH grants white magic via Light Arts -> Addendum: White
    -- (order matters); WHM adds Afflatus Solace. A stance fires ONLY when (a) its
    -- toggle is on, (b) the buff is genuinely ABSENT, and (c) the buff is READABLE
    -- for this healer -- in-party (memory) or a fresh cross-party report. Without
    -- (c) we'd re-fire a stance that is already up but unseen (the old 30s spam).
    -- rdmhelper now reports Light Arts/Addendum/Solace so cross-party is readable.
    -- FIX: presence+readability gate replaces the speculative 30s re-fire timer.
    local hb = healer.buffs or blank_buffs()
    local stance_readable = (healer.pt_data.index < 6)
        or (now - (healer.last_rep_time or 0) < STANCE_READABLE_GAP)
    if stance_readable then
        -- FIX: stamp the last tick each stance was OBSERVED up. A stance is only
        -- (re)cast once it has read absent for >= STANCE_LOSS_DEBOUNCE since that
        -- stamp, so an up buff is never re-used on a one-scan / report-gap miss;
        -- the *_lock then suppresses re-fire across the cast + registration window.
        if hb.larts  then healer.larts_seen  = now end
        if hb.addw   then healer.addw_seen   = now end
        if hb.solace then healer.solace_seen = now end

        if USE_SCH_STANCES and prof.sch and not hb.larts
           and (now - (healer.larts_seen or 0)) >= STANCE_LOSS_DEBOUNCE
           and now > (healer.larts_lock or 0) then
            healer.larts_lock = now + STANCE_GUARD
            if heal_dbg then print(('[sync] %s -> Light Arts'):format(healer.disp_name)) end
            do_action(healer, '/ja "Light Arts" <me>', 1.5, now)
            return true
        end
        if USE_SCH_STANCES and prof.sch and hb.larts and not hb.addw
           and (now - (healer.addw_seen or 0)) >= STANCE_LOSS_DEBOUNCE
           and now > (healer.addw_lock or 0) then
            healer.addw_lock = now + STANCE_GUARD
            if heal_dbg then print(('[sync] %s -> Addendum: White'):format(healer.disp_name)) end
            do_action(healer, '/ja "Addendum: White" <me>', 1.5, now)
            return true
        end
        if prof.solace and USE_AFFLATUS_SOLACE and not hb.solace
           and (now - (healer.solace_seen or 0)) >= STANCE_LOSS_DEBOUNCE
           and now > (healer.solace_lock or 0) then
            healer.solace_lock = now + STANCE_GUARD
            if heal_dbg then print(('[sync] %s -> Afflatus Solace'):format(healer.disp_name)) end
            do_action(healer, '/ja "Afflatus Solace" <me>', 1.5, now)
            return true
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
                   and now - ((healer.buff_locks[t.name] and healer.buff_locks[t.name]['wake']) or 0) >= CURE_RETRY_GAP then
                    sleeper = t; break
                end
            end
        end
        if not sleeper then for _, t in ipairs(guests) do
            if t.heal and t.heal[1] and t.in_zone and t.pt_data then
                local st = t.status or 0
                if bit_band(st, SLEEP_BIT) ~= 0 and bit_band(st, CHARM_BIT) == 0
                   and now - ((healer.buff_locks[t.name] and healer.buff_locks[t.name]['wake']) or 0) >= CURE_RETRY_GAP then
                    sleeper = t; break
                end
            end
        end end
        if sleeper then
            local locks = healer.buff_locks[sleeper.name]
            if not locks then locks = {}; healer.buff_locks[sleeper.name] = locks end
            locks['wake'] = now
            local same_pty = (sleeper.pt_data.group == hgroup)
            local tstr = (sleeper.name_lower == healer.name_lower) and "<me>" or sleeper.name
            if heal_dbg then
                print(('[sync] %s WAKE %s same_pty=%s curaga=%d accession=%s')
                    :format(healer.disp_name, sleeper.name, tostring(same_pty), prof.curaga or 0, tostring(prof.accession)))
            end
            if prof.curaga > 0 and same_pty then
                local spell = curaga_spell_for(100, prof.curaga)
                if heal_dbg then print(('[sync] %s -> %s %s (wake)'):format(healer.disp_name, spell, sleeper.name)) end
                do_action(healer, '/ma "' .. spell .. '" ' .. tstr, get_cast_delay(spell), now)
            elseif prof.accession and same_pty then
                if heal_dbg then print(('[sync] %s -> Accession+Cure %s (wake)'):format(healer.disp_name, sleeper.name)) end
                local cure = cure_spell_for(100, prof.cure)
                local cd   = get_cast_delay(cure)
                do_action(healer, '/ja "Accession" <me>', 0.5, now)
                healer.cast_reserved_until = now + 0.5 + cd + 0.5
                queue_cast(healer, '/ma "' .. cure .. '" ' .. tstr, now + 0.5, cd)
            else
                local cure = cure_spell_for(100, prof.cure)   -- single Cure still wakes the target
                if heal_dbg then print(('[sync] %s -> %s %s (wake)'):format(healer.disp_name, cure, sleeper.name)) end
                do_action(healer, '/ma "' .. cure .. '" ' .. tstr, get_cast_delay(cure), now)
            end
            return true
        end
    end

    -- 3. Scan injured recipients (respecting this healer's per-target cure gap).
    --    worst* = lowest HP anywhere (single cure / DS); g* = healer's own party
    --    cluster (Curaga only helps the caster's party). Charmed members are
    --    skipped entirely -- curing them would wake them back into attacking us.
    local worst, worst_pct = nil, 101
    local gworst, gworst_pct, gcount = nil, 101, 0
    if prof.cure > 0 and ((not mp_known) or mp >= CURE_MIN_MP) then
        local function consider(t)
            if not (t.heal and t.heal[1] and t.in_zone and t.pt_data) then return end
            if bit_band(t.status or 0, CHARM_BIT) ~= 0 then return end
            local pct = party:GetMemberHPPercent(t.pt_data.index) or 0
            if pct <= 0 or pct > threshold then return end
            local locks = healer.buff_locks[t.name]
            if now - ((locks and locks['cure']) or 0) < CURE_RETRY_GAP then return end
            if pct < worst_pct then worst, worst_pct = t, pct end
            if t.pt_data.group == hgroup then
                gcount = gcount + 1
                if pct < gworst_pct then gworst, gworst_pct = t, pct end
            end
        end
        for _, c in ipairs(chars)  do consider(c) end
        for _, g in ipairs(guests) do consider(g) end
    end

    if worst then
        -- 3. DIVINE SEAL -- main WHM only, emergency, off cooldown. Burst the next
        --    (curaga/cure) cast; it fires next tick with DS up.
        if is_primary and prof.ds and worst_pct <= EMERGENCY_PCT and now > (healer.ds_lock or 0) then
            healer.ds_lock = now + DIVINE_SEAL_RECAST
            if heal_dbg then print(('[sync] %s -> Divine Seal (%d%%)'):format(healer.disp_name, worst_pct)) end
            do_action(healer, '/ja "Divine Seal" <me>', 1.5, now)
            return true
        end

        -- 4. CURAGA -- WHM, 2+ injured in the healer's own party.
        if prof.curaga > 0 and gworst and gcount >= CURAGA_MIN_TARGETS then
            local spell = curaga_spell_for(gworst_pct, prof.curaga)
            local locks = healer.buff_locks[gworst.name]
            if not locks then locks = {}; healer.buff_locks[gworst.name] = locks end
            locks['cure'] = now
            local tstr = (gworst.name_lower == healer.name_lower) and "<me>" or gworst.name
            if heal_dbg then print(('[sync] %s -> %s %s x%d (%d%%)'):format(healer.disp_name, spell, gworst.name, gcount, gworst_pct)) end
            do_action(healer, '/ma "' .. spell .. '" ' .. tstr, get_cast_delay(spell), now)
            return true
        end

        -- 5. CURE -- single target, lowest HP anywhere (cross-party capable).
        local spell = cure_spell_for(worst_pct, prof.cure)
        local locks = healer.buff_locks[worst.name]
        if not locks then locks = {}; healer.buff_locks[worst.name] = locks end
        locks['cure'] = now
        local tstr = (worst.name_lower == healer.name_lower) and "<me>" or worst.name
        if heal_dbg then print(('[sync] %s -> %s %s (%d%%)'):format(healer.disp_name, spell, worst.name, worst_pct)) end
        do_action(healer, '/ma "' .. spell .. '" ' .. tstr, get_cast_delay(spell), now)
        return true
    end

    -- 6. STATUS REMOVAL -- only statuses this job can actually cure. na_now is
    -- available immediately; na_arts adds once Addendum: White is up (SCH).
    local na_mask = prof.na_now
    if healer.buffs and healer.buffs.addw then na_mask = bit_bor(na_mask, prof.na_arts) end
    if do_status and na_mask ~= 0 and ((not mp_known) or mp >= NA_MIN_MP) then
        local function consider_na(t)
            if not (t.heal and t.heal[1] and t.in_zone and t.pt_data) then return false end
            if bit_band(t.status or 0, CHARM_BIT) ~= 0 then return false end
            local st = bit_band(t.status or 0, na_mask)
            if st == 0 then return false end
            for _, b in ipairs(STATUS_BIT_PRIORITY) do
                if bit_band(st, b) ~= 0 then
                    local locks = healer.buff_locks[t.name]
                    local key   = 'na' .. b
                    if now - ((locks and locks[key]) or 0) >= NA_RETRY_GAP then
                        if not locks then locks = {}; healer.buff_locks[t.name] = locks end
                        locks[key] = now
                        local spell = STATUS_BIT_TO_SPELL[b]
                        local tstr  = (t.name_lower == healer.name_lower) and "<me>" or t.name
                        if heal_dbg then print(('[sync] %s -> %s %s (bit=%d)'):format(healer.disp_name, spell, t.name, b)) end
                        do_action(healer, '/ma "' .. spell .. '" ' .. tstr, get_cast_delay(spell), now)
                        return true
                    end
                end
            end
            return false
        end
        for _, c in ipairs(chars)  do if consider_na(c) then return true end end
        for _, g in ipairs(guests) do if consider_na(g) then return true end end
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
            local g = { name = party:GetMemberName(data.index), buf = {false} }
            init_char_state(g); g.in_zone, g.pt_data = true, data
            t_insert(guests, g)
        end
    end
end

local function scan_buff_list(t, slot_addr, myNameL, player, now)
    for _, c in ipairs(t) do
        if c.pt_data and c.pt_data.index >= 6 then
            if (now - c.last_rep_time) >= 15.0 then
                c.buffs = blank_buffs()
            end
            goto continue
        end

        if c.in_zone and c.pt_data and c.pt_data.index < 6 then
            c.buffs.h = false; c.buffs.r = false; c.buffs.p = false; c.buffs.fl = false
            c.buffs.comp = false; c.buffs.pro = false; c.buffs.sh = false; c.buffs.samba = false
            c.buffs.larts = false; c.buffs.addw = false; c.buffs.solace = false

            local st = 0
            if c.name_lower == myNameL then
                local b = player:GetBuffs()
                for i = 0, 31 do
                    local id = b[i]
                    local k = BUFF_ID_TO_KEY[id]
                    if k then c.buffs[k] = true end
                    local sb = STATUS_ID_TO_BIT[id]
                    if sb then st = bit_bor(st, sb) end
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
                        local k = BUFF_ID_TO_KEY[id]
                        if k then c.buffs[k] = true end
                        local sb = STATUS_ID_TO_BIT[id]
                        if sb then st = bit_bor(st, sb) end
                    end
                end
            end
            -- Local read is authoritative for our own party (lower latency than the
            -- rdmhelper wire); keep it fresh so the report-expiry path won't zero it.
            c.status = st
            c.last_status_time = now
        end
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
local TICK_ACTION = 0.1
local TICK_SCAN   = 0.5
local lastTick, lastScanTick = 0, 0
local last_heal_dbg = 0
local is_zoning_prev = false
local rdm_buff_idle_until = 0

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

    local rdm_in_zone = rdm and rdm.in_zone and rdm.pt_data

    ------------------------------------------------------------
    -- HEALER PASS -- main + backup healers cast concurrently (independent boxes,
    -- independent action_locks). Runs before the RDM block so that if a healer is
    -- also the RDM, casting a heal sets its lock and the buff/debuff block yields.
    ------------------------------------------------------------
    local mh = resolve_healer(main_healer)
    local bh = (backup_healer ~= main_healer) and resolve_healer(backup_healer) or nil
    local main_ok = mh and bit_band(mh.status or 0, SILENCE_BIT) == 0

    -- Work gate (mirrors the RDM's rdm_has_work): a healer only acts -- including
    -- popping stances like Light Arts/Addendum/Solace -- when at least one in-zone
    -- member actually has Cure (heal) checked. No recipients => no action.
    local heal_work = false
    for _, c in ipairs(chars)  do if c.heal and c.heal[1] and c.in_zone then heal_work = true; break end end
    if not heal_work then
        for _, g in ipairs(guests) do if g.heal and g.heal[1] and g.in_zone then heal_work = true; break end end
    end

    if heal_dbg and now - last_heal_dbg >= 1.0 then
        last_heal_dbg = now
        print(('[sync] work=%s main=%s%s backup=%s%s'):format(tostring(heal_work),
            main_healer,   mh and (' '..(mh.job or 0)..'/'..(mh.sjob or 0)..'('..(mh.sjlvl or 0)..')') or '(off)',
            backup_healer, bh and (' '..(bh.job or 0)..'/'..(bh.sjob or 0)..'('..(bh.sjlvl or 0)..')') or '(off)'))
        local function dump(t)
            if t.heal and t.heal[1] and t.in_zone and t.pt_data then
                local st = t.status or 0
                local tag = ''
                if bit_band(st, CHARM_BIT) ~= 0 then tag = tag .. ' CHARM' end
                if bit_band(st, SLEEP_BIT) ~= 0 then tag = tag .. ' SLEEP' end
                print(('[sync]   %s hp=%d%% status=%d%s%s'):format(
                    t.name, party:GetMemberHPPercent(t.pt_data.index) or 0, st, tag,
                    t == cached_main and ' (local)' or ''))
            end
        end
        for _, c in ipairs(chars)  do dump(c) end
        for _, g in ipairs(guests) do dump(g) end
    end

    if heal_work then
        if mh and now > mh.action_lock then
            heal_pass(mh, party, player, now, CURE_THRESHOLD, true, true, true)
        end
        if bh and now > bh.action_lock then
            heal_pass(bh, party, player, now, BACKUP_CURE_THRESHOLD, not main_ok, not main_ok, false)
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
                rdm.action_lock = now + FOLLOW_SETTLE
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
        local function sleep_bookkeep(t)
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
        for _, c in ipairs(chars)  do if not c.is_rdm then sleep_bookkeep(c) end end
        for _, g in ipairs(guests) do sleep_bookkeep(g) end
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
            local function charmed_awake(t)
                if not (t.heal and t.heal[1] and t.in_zone and t.pt_data) then return false end
                local st = t.status or 0
                return bit_band(st, CHARM_BIT) ~= 0 and bit_band(st, SLEEP_BIT) == 0
            end
            local victim = nil
            for _, c in ipairs(chars)  do if not c.is_rdm and charmed_awake(c) then victim = c; break end end
            if not victim then for _, g in ipairs(guests) do if charmed_awake(g) then victim = g; break end end end
            if victim then
                local locks = rdm.buff_locks[victim.name]
                if not locks then locks = {}; rdm.buff_locks[victim.name] = locks end
                -- FIX: spend from the per-episode budget (locks.sleep2_n). The
                -- bookkeeping pass refunds it when a sleep sticks and clears it when
                -- charm wears off, so we keep retrying through resists / interrupts and
                -- through natural sleep expiry, but stop cycling Sleep on a member that
                -- simply can't be kept asleep (immune, or a DoT waking it every tick).
                if (locks.sleep2_n or 0) < CHARM_SLEEP_MAX
                   and now - (locks['sleep2'] or 0) >= CHARM_SLEEP_GAP then
                    locks['sleep2'] = now
                    locks.sleep2_n  = (locks.sleep2_n or 0) + 1
                    if heal_dbg then print(('[sync] %s -> Sleep II %s (charmed, try %d/%d)'):format(rdm.disp_name, victim.name, locks.sleep2_n, CHARM_SLEEP_MAX)) end
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
                if not rdm.buffs.comp and now > (rdm.comp_lock or 0) then
                    rdm.comp_lock = now + 295.0
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
    -- CHARACTER LOGIC
------------------------------------------------------------
    for _, c in ipairs(chars) do
        if not c.is_main then
            local want_follow = c.f[1] and not c.debuff_pause
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

                    if c.e[1] then
                        if main_is_attacking and engageTarget > 0 then
                            local time_since = now - (c.last_engage_time or 0)
                            if (c.last_engage_target ~= engageTarget or not is_attacking)
                                and time_since >= ENGAGE_RETRY_GAP then
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
    for _, v in ipairs(ui_columns) do
        igTableNextColumn()
        if not (t.is_main and not v.allow_main)
        and not (v.rdm_only and not t.is_rdm)
        and (col ~= COLOR_GUEST or v.key == 'buf' or v.key == 'heal') then
            igCheckbox(t.ui_ids[v.key], t[v.key])
        else igTextDisabled("-") end
    end
end

ashita.events.register('d3d_present', 'render_ui', function()
    if not show_ui then return end
    local now = os_clock()
    igSetNextWindowBgAlpha(0.4)
    if igBegin('Sync', SYNC_WINDOW_OPEN, SYNC_WINDOW_FLAGS) then
        do
            local function hstat(nm)
                if nm == '' then return nil end
                for _, c in ipairs(chars) do if c.name_lower == nm then return c.in_zone end end
                return false
            end
            local mon, bon = hstat(main_healer), hstat(backup_healer)
            igTextColored(mon and COLOR_GUEST or COLOR_OFFLINE,
                'Heal: ' .. main_healer:sub(1,3):upper() .. (mon and '' or '!'))
            imgui.SameLine(0, 6)
            if backup_healer == '' then
                igTextDisabled('+--')
            else
                igTextColored(bon and COLOR_RECOVERING or COLOR_OFFLINE,
                    '+' .. backup_healer:sub(1,3):upper() .. (bon and '' or '!'))
            end
        end
        if igBeginTable('SyncTable', NUM_UI_COLS + 1, 0) then
            igTableSetupColumn('Name', 0, 24)
            for _, col in ipairs(ui_columns) do igTableSetupColumn(col.label, 0, 22) end
            
            imgui.TableHeadersRow()
            
            for _, c in ipairs(chars) do draw(c, nil, now) end
            if #guests > 0 then
                igTableNextRow()
                igTableNextColumn()
                if igSmallButton(show_guests and 'v' or '>') then
                    show_guests = not show_guests
                end
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

ashita.events.register('command', 'sync_rdmhelper_listener', function(e)
    local cmd = e.command:lower()
    
    if not cmd:find('/rdmhelper rep', 1, true) then return end
    
    local _, _, name, flags_str, st_str, mj_str, sj_str, sl_str = cmd:find('/rdmhelper rep (%S+) (%d+)%s*(%d*)%s*(%d*)%s*(%d*)%s*(%d*)')
    if name and flags_str then
        e.blocked = true
        local flags = tonumber(flags_str) or 0
        if name == "shaymin" then return end
        
        local t = nil
        for _, c in ipairs(chars)  do if c.name_lower == name then t = c; break end end
        if not t then for _, g in ipairs(guests) do if g.name_lower == name then t = g; break end end end

        if rep_dbg then
            print(('[sync] rep %s flags=%d st=%s job=%s/%s lv=%s match=%s')
                :format(name, flags, st_str ~= '' and st_str or '-',
                    mj_str ~= '' and mj_str or '-', sj_str ~= '' and sj_str or '-',
                    sl_str ~= '' and sl_str or '-',
                    t and ((t.pt_data and t.pt_data.index) or '?') or 'NONE'))
        end
        
        if t then
            local nowc = os_clock()
            t.last_rep_time = nowc
            t.buffs.h    = (bit_band(flags, 1) > 0)
            t.buffs.fl   = (bit_band(flags, 2) > 0)
            t.buffs.r    = (bit_band(flags, 4) > 0)
            t.buffs.p    = (bit_band(flags, 8) > 0)
            t.buffs.pro  = (bit_band(flags, 16) > 0)
            t.buffs.sh   = (bit_band(flags, 32) > 0)
            t.buffs.comp = (bit_band(flags, 64) > 0)
            t.buffs.larts  = (bit_band(flags, 128) > 0)
            t.buffs.addw   = (bit_band(flags, 256) > 0)
            t.buffs.solace = (bit_band(flags, 512) > 0)
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
    fraz = 'Frazzle III'
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

local presets = {
    on = {
        { 'buf', 'all',    true },
        { 'deb', 'goomy',  true },
        { 'e',   'all',    true },
        { 'bs',  'muunch', true },
        { 'hs',  'muunch', true },
		{ 'h', 'all', true },
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
            apply_command(p[1], p[2], p[3]) 
            log_command_state(p[1], p[2])
        end
        return
    end

    local a2, a3, a4 = args[2]:lower(), args[3] and args[3]:lower(), args[4] and args[4]:lower()
    
    if a2 == 'ui' then
        show_ui = (a3 == 'on') or (a3 ~= 'off' and not show_ui)
        return
    end

    if a2 == 'dbg' then
        rep_dbg = not rep_dbg
        print('[sync] rep debug ' .. (rep_dbg and 'ON' or 'OFF'))
        return
    end

    if a2 == 'hdbg' then
        heal_dbg = not heal_dbg
        print('[sync] heal debug ' .. (heal_dbg and 'ON' or 'OFF'))
        return
    end

    if a2 == 'healer' or a2 == 'backup' then
        if a3 then
            local set = (a3 == 'off' or a3 == 'none') and '' or nil
            if set == nil then
                for _, c in ipairs(chars) do if c.name_lower:sub(1, #a3) == a3 then set = c.name_lower; break end end
            end
            if set ~= nil then
                if a2 == 'healer' then main_healer = set else backup_healer = set end
                print(('[sync] %s healer -> %s'):format(a2 == 'healer' and 'main' or 'backup', set == '' and 'OFF' or set))
            else
                print('[sync] no crew matches "' .. a3 .. '"')
            end
        else
            print(('[sync] main=%s backup=%s'):format(main_healer, backup_healer == '' and 'OFF' or backup_healer))
        end
        return
    end

    if a2 == 'thr' then
        local n = tonumber(a4)
        if (a3 == 'main' or a3 == 'backup') and n then
            if a3 == 'main' then CURE_THRESHOLD = n else BACKUP_CURE_THRESHOLD = n end
            print(('[sync] %s cure threshold -> %d%%'):format(a3, n))
        else
            print(('[sync] main=%d%% backup=%d%% (usage: /sync thr main|backup <pct>)'):format(CURE_THRESHOLD, BACKUP_CURE_THRESHOLD))
        end
        return
    end

    if a2 == 'solace' then
        USE_AFFLATUS_SOLACE = (a3 == 'on') or (a3 ~= 'off' and not USE_AFFLATUS_SOLACE)
        if not USE_AFFLATUS_SOLACE then for _, c in ipairs(chars) do c.solace_lock = 0 end end
        print('[sync] Afflatus Solace maintenance ' .. (USE_AFFLATUS_SOLACE and 'ON' or 'OFF'))
        return
    end

    if a2 == 'arts' then
        USE_SCH_STANCES = (a3 == 'on') or (a3 ~= 'off' and not USE_SCH_STANCES)
        if not USE_SCH_STANCES then for _, c in ipairs(chars) do c.larts_lock = 0; c.addw_lock = 0 end end
        print('[sync] SCH stances (Light Arts/Addendum: White) ' .. (USE_SCH_STANCES and 'ON' or 'OFF')
              .. (USE_SCH_STANCES and '' or ' -- /SCH -na disabled while OFF'))
        return
    end

    -- /sync sp <combo> -- one-shot stratagem combos on the main healer. The
    -- healer is reserved for the whole window so a routine Cure can't consume the
    -- Accession charge before the buffed spell lands.
    -- regen: Accession, ~1.0s, Regen IV <me> (AoE party Regen IV).
    if a2 == 'sp' then
        local h = resolve_healer(main_healer)
        if not h then
            print('[sync] sp: main healer not available (in zone + partied required)')
            return
        end
        if a3 == 'regen' then
            local now = os_clock()
            local rd  = get_cast_delay("Regen IV")
            do_action(h, '/ja "Accession" <me>', 1.0, now)
            h.cast_reserved_until = now + 1.0 + rd + 0.5
            queue_cast(h, '/ma "Regen IV" <me>', now + 1.0, rd)
            print(('[sync] %s -> Accession + Regen IV (party)'):format(h.disp_name))
        else
            print('[sync] usage: /sync sp regen')
        end
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
                    
                    -- Triple command burst to fight past animation lock states
                    chat:QueueCommand(1, c.cmd_attack_off)
                    coroutine.sleep(0.15)
                    chat:QueueCommand(1, c.cmd_attack_off)
                    coroutine.sleep(0.15)
                    chat:QueueCommand(1, c.cmd_attack_off)
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
                coroutine.sleep(0.15)
                chat:QueueCommand(1, t.cmd_attack_off)
                coroutine.sleep(0.15)
                chat:QueueCommand(1, t.cmd_attack_off)
                print(string.format('[sync] Action Verified: [%s] disengage burst complete; tracking reset.', t.disp_name))
            else
                print('[sync] Warning: Specified character target to disengage was missing or invalid.')
            end
        end
        return
    end

    local DEBUFF_TOGGLES = { silence='sil', sil='sil', distract='dist', dist='dist', frazzle='fraz', fraz='fraz' }
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
                   abs='abs', hs='hs', fl='fl', ref='ref', heal='heal', hl='heal' , c='heal', cure='heal' }
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
