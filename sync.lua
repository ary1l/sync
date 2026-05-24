addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '.050526b'
addon.desc    = 'sync'

require('common')
local mm = AshitaCore:GetMemoryManager()
local imgui = require('imgui')

------------------------------------------------------------
-- LUA OPTIMIZATIONS
------------------------------------------------------------
local os_clock      = os.clock
local math_floor    = math.floor
local string_format = string.format
local bit_lshift    = bit.lshift
local bit_rshift    = bit.rshift
local bit_band      = bit.band

local UI_PADDING    = {2, 2}
local UI_SPACING    = {2, 2}
local COLOR_OFFLINE = {1.0, 0.2, 0.2, 1.0}
local COLOR_BUSY    = {1.0, 0.8, 0.0, 1.0}
local COLOR_GUEST   = {0.6, 0.9, 1.0, 1.0}
local COLOR_RECOVERING = {0.4, 0.6, 1.0, 1.0}

------------------------------------------------------------
-- CONFIGURATION & DICTIONARIES
------------------------------------------------------------
local show_ui = true

local ENGAGE_RETRY_GAP = 0.5
local RETRY_DELAY      = 0.7

local BUFF_IDS = {
    HASTE = 33, PROTECT = 40, SHELL = 41, REFRESH = 43,
    PHALANX = 116, HASTE_SAMBA = 370, COMPOSURE = 419
}

local JOB_IDS = {
    WHM = 3, BLM = 4, RDM = 5, PLD = 7, DRK = 8,
    SMN = 15, BLU = 16, GEO = 21, RUN = 22
}

local silence_whitelist = {
    ["imp"] = true,
    ["eschan corse"] = true
}

local refresh_jobs = {
    [JOB_IDS.WHM] = true, [JOB_IDS.BLM] = true, [JOB_IDS.RDM] = true,
    [JOB_IDS.PLD] = true, [JOB_IDS.DRK] = true, [JOB_IDS.SMN] = true,
    [JOB_IDS.BLU] = true, [JOB_IDS.GEO] = true, [JOB_IDS.RUN] = true
}

local chars = {
    { name='',  is_main=true, f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='',    is_rdm=true,  f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='',                  f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='',                f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='',                  f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
}

local BUFF_PRIORITY = {"h","r","pro","sh","p"}
local guests = {}
local current_active = {}
local known_cores = {}
local buff_cache = {}
local debuff_queue = {}

local cached_rdm  = nil
local cached_main = nil

local last_engage_target = 0

local ui_columns = {
    { label = 'F',  key = 'f',   allow_main = false, rdm_only = false },
    { label = 'E',  key = 'e',   allow_main = false, rdm_only = false },
    { label = 'HS', key = 'hs',  allow_main = false, rdm_only = false },
    { label = 'BS', key = 'bs',  allow_main = false, rdm_only = false },
    { label = 'QS', key = 'qs',  allow_main = false, rdm_only = false },
    { label = 'Ab', key = 'abs', allow_main = false, rdm_only = false },
    { label = 'De', key = 'deb', allow_main = false, rdm_only = true  },
    { label = 'Bu', key = 'buf', allow_main = true,  rdm_only = false }
}

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function get_cache(t)
    if not t or not t.name_lower then return {} end
    local id = t.name_lower
    buff_cache[id] = buff_cache[id] or {r=0, h=0, p=0, pro=0, sh=0, comp=0}
    return buff_cache[id]
end

local function get_debuff_queue(targetIdx)
    if not targetIdx or targetIdx == 0 then return {} end
    if not debuff_queue[targetIdx] then
        debuff_queue[targetIdx] = {
            { name="Silence",      done=false },
            { name="Dia III",      done=false },
            { name="Frazzle III",  done=false },
            { name="Distract III", done=false },
        }
    end
    return debuff_queue[targetIdx]
end

local BUFF_RETIMER   = { r=300, h=270, p=270, pro=3300, sh=3300, comp=3600 }
local BUFF_RETRY_GAP = 9.0
local RDM_FAST_CAST  = 0.50
local ANIMATION_LOCK = 2.75

local SPELL_CAST_TIMES = {
    ["Refresh III"] = 3.0,   ["Distract III"] = 3.0,
    ["Haste II"] = 3.0,      ["Phalanx II"] = 3.0,
    ["Phalanx"] = 3.0,       ["Protect V"] = 3.0,
    ["Shell V"] = 3.0,       ["Silence"] = 3.0,
    ["Dia III"] = 2.5,       ["Frazzle III"] = 3.0,
}

local function get_cast_delay(spell)
    local base_time = SPELL_CAST_TIMES[spell] or 3.0
    return (base_time * (1.0 - RDM_FAST_CAST)) + ANIMATION_LOCK
end

local function get_dist_sq(entIdx, ent)
    if not entIdx or entIdx == 0 then return 9999 end
    return ent:GetDistance(entIdx) or 9999
end

local function get_player_target(targ)
    if not targ then return 0 end
    local ok, idx = pcall(function()
        local isSub = targ:GetIsSubTargetActive()
        return targ:GetTargetIndex(isSub)
    end)
    return (ok and idx and idx > 0) and idx or 0
end

local function GetTargetOfTarget(targ, ent)
    if not targ or not ent then return 0 end
    local ok, targetIndex = pcall(function()
        local isSub = targ:GetIsSubTargetActive()
        return targ:GetTargetIndex(isSub)
    end)
    if not ok or not targetIndex or targetIndex == 0 then return 0 end
    local tot = ent:GetTargetedIndex(targetIndex)
    return (tot and tot > 0) and tot or 0
end

------------------------------------------------------------
-- ENGAGE RETRY
------------------------------------------------------------
local function queue_retry(c, cmd, now)
    c.retry = { cmd = cmd, time = now + RETRY_DELAY }
end

local function process_retry(c, now, party, ent)
    if not c.retry or now < c.retry.time then return end
    if c.retry.cmd:find('/attack') then
        local pIdx = c.pt_data and c.pt_data.index
        local entIdx = pIdx and party:GetMemberTargetIndex(pIdx) or 0
        local status = (entIdx > 0) and ent:GetStatus(entIdx) or 0
        if status ~= 1 then
            AshitaCore:GetChatManager():QueueCommand(1, c.retry.cmd)
        end
    else
        AshitaCore:GetChatManager():QueueCommand(1, c.retry.cmd)
    end
    c.retry = nil
end

------------------------------------------------------------
-- STATE UTILS
------------------------------------------------------------
local qcmd = function(cmd, isFollow)
    local player = mm:GetPlayer()
    if not isFollow and player and player:GetIsZoning() ~= 0 then return end
    AshitaCore:GetChatManager():QueueCommand(1, cmd)
end

local function do_action(c, cmd, lock_time, current_time)
    qcmd('/mst ' .. c.name .. ' ' .. cmd)
    c.action_lock = current_time + lock_time
end

local function init_char_state(c)
    c.name_lower = c.name:lower()
    c.disp_name  = c.name:sub(1,5):upper()
    c.action_lock  = 0
    c.comp_lock    = 0
    c.buff_locks   = {}
    c.low_mp_mode  = false
    c.actual_follow = nil  -- nil forces follow sync on first tick
    c.buffs = { h=false, r=false, p=false, comp=false, pro=false, sh=false, samba=false }
    c.ui_ids = {}
    c.last_engage_target = 0
    c.last_engage_time   = 0
    c.auto_engaged       = false
    c.retry              = nil
    c.debuff_wait        = 0
    for _, col in ipairs(ui_columns) do
        c.ui_ids[col.key] = '##' .. col.label .. '_' .. c.name_lower
    end
    if c.is_rdm  then cached_rdm  = c end
    if c.is_main then cached_main = c end
end

for _, c in ipairs(chars) do init_char_state(c); known_cores[c.name_lower] = true end

------------------------------------------------------------
-- RDM HELPER FUNCTIONS
------------------------------------------------------------
local function check_needs(t, key, rdmGroup, rdm, now, party, ent)
    if not t or not t.in_zone or not t.pt_data or not t.buf then return false end
    if not t.buf[1] then return false end
    local cache = get_cache(t)
    if not cache or not chars[1] or not chars[1].pt_data then return false end

    local tIdx    = t.pt_data.index
    local leadIdx = chars[1].pt_data.index
    local is_in_lead_party = (math_floor(tIdx / 6) == math_floor(leadIdx / 6))

    if is_in_lead_party then
        if t.buffs and t.buffs[key] then cache[key] = now + BUFF_RETIMER[key]; return false end
    else
        if cache[key] and now < cache[key] then return false end
    end

    local tEntIdx = party:GetMemberTargetIndex(tIdx)
    if tEntIdx > 0 and not (t.is_rdm or get_dist_sq(tEntIdx, ent) < 441.0) then return false end

    local in_same_party_as_rdm = (rdmGroup == math_floor(tIdx / 6))
    if key == 'r' and (not in_same_party_as_rdm or not refresh_jobs[t.pt_data.job]) then return false end
    if key == 'p' and not in_same_party_as_rdm then return false end

    rdm.buff_locks[t.name] = rdm.buff_locks[t.name] or {}
    if now - (rdm.buff_locks[t.name][key] or 0) < BUFF_RETRY_GAP then return false end

    return true
end

------------------------------------------------------------
-- SCANNING
------------------------------------------------------------
local function reset_combat_flags()
    local to_reset = {'e', 'hs', 'bs', 'qs', 'abs', 'deb', 'buf'}
    for _, c in ipairs(chars) do
        for _, key in ipairs(to_reset) do if c[key] then c[key][1] = false end end
        c.actual_follow      = nil  -- force re-sync on next tick after zone
        c.last_engage_target = 0
        c.last_engage_time   = 0
        c.auto_engaged       = false
        c.retry              = nil
    end
    for _, g in ipairs(guests) do
        for _, key in ipairs(to_reset) do if g[key] then g[key][1] = false end end
        g.actual_follow      = nil
        g.last_engage_target = 0
        g.last_engage_time   = 0
        g.auto_engaged       = false
        g.retry              = nil
    end
end

local function update_membership_and_zones(party)
    local my_zone = party:GetMemberZone(0)
    for _, v in pairs(current_active) do v.active_this_scan = false end
    for i = 0, 17 do
        local name = party:GetMemberName(i)
        if name and name ~= "" then
            local zId = party:GetMemberZone(i)
            local sId = party:GetMemberServerId(i)
            if sId ~= 0 and party:GetMemberIsActive(i) ~= 0 and zId == my_zone then
                local nl = name:lower()
                current_active[nl] = { index=i, job=party:GetMemberMainJob(i), sId=sId, active_this_scan=true }
            end
        end
    end
    for k, v in pairs(current_active) do if not v.active_this_scan then current_active[k] = nil end end
    for _, c in ipairs(chars) do c.pt_data = current_active[c.name_lower]; c.in_zone = (c.pt_data ~= nil) end
    for i = #guests, 1, -1 do
        guests[i].pt_data = current_active[guests[i].name_lower]
        if not guests[i].pt_data then table.remove(guests, i) else guests[i].in_zone = true end
    end
    for nl, data in pairs(current_active) do
        local known = known_cores[nl]
        if not known then for _, g in ipairs(guests) do if g.name_lower == nl then known = true; break end end end
        if not known then
            local g = { name = party:GetMemberName(data.index), buf = {false} }
            init_char_state(g); g.in_zone, g.pt_data = true, data
            table.insert(guests, g)
        end
    end
end

local function scan_buffs(t, party, player)
    local ptr = AshitaCore:GetPointerManager():Get('party.statusicons')
    if ptr == 0 then return end
    local buff_ptr = ashita.memory.read_uint32(ptr)
    if buff_ptr == 0 then return end
    local myNameL = (party:GetMemberName(0) or ''):lower()

    for _, c in ipairs(t) do
        if not c.in_zone then goto skip end
        c.buffs.h = false; c.buffs.r = false; c.buffs.p = false
        c.buffs.comp = false; c.buffs.pro = false; c.buffs.sh = false; c.buffs.samba = false
        if c.name_lower == myNameL then
            local b = player:GetBuffs()
            for i = 0, 31 do
                local id = b[i]
                if     id == BUFF_IDS.HASTE      then c.buffs.h    = true
                elseif id == BUFF_IDS.REFRESH     then c.buffs.r    = true
                elseif id == BUFF_IDS.PHALANX     then c.buffs.p    = true
                elseif id == BUFF_IDS.COMPOSURE   then c.buffs.comp = true
                elseif id == BUFF_IDS.PROTECT     then c.buffs.pro  = true
                elseif id == BUFF_IDS.SHELL       then c.buffs.sh   = true
                elseif id == BUFF_IDS.HASTE_SAMBA then c.buffs.samba= true end
            end
        elseif c.pt_data and c.pt_data.index <= 5 then
            for slot = 0, 5 do
                local m = buff_ptr + (0x30 * slot)
                if ashita.memory.read_uint32(m) == c.pt_data.sId then
                    for j = 0, 31 do
                        local low = ashita.memory.read_uint8(m + 16 + j)
                        if low == 255 then break end
                        local id = (bit_lshift(bit_band(bit_rshift(ashita.memory.read_uint8(m + 8 + math_floor(j/4)), (j%4)*2), 0x03), 8)) + low
                        if     id == BUFF_IDS.HASTE      then c.buffs.h    = true
                        elseif id == BUFF_IDS.REFRESH     then c.buffs.r    = true
                        elseif id == BUFF_IDS.PHALANX     then c.buffs.p    = true
                        elseif id == BUFF_IDS.COMPOSURE   then c.buffs.comp = true
                        elseif id == BUFF_IDS.PROTECT     then c.buffs.pro  = true
                        elseif id == BUFF_IDS.SHELL       then c.buffs.sh   = true
                        elseif id == BUFF_IDS.HASTE_SAMBA then c.buffs.samba= true end
                    end
                    break
                end
            end
        end
        ::skip::
    end
end

------------------------------------------------------------
-- CORE LOGIC
------------------------------------------------------------
local TICK_ACTION = 0.1
local TICK_SCAN   = 0.5
local lastTick, lastScanTick = 0, 0
local is_zoning_prev = false

ashita.events.register('d3d_present', 'logic_loop', function()
    local now = os_clock()
    if now - lastTick < TICK_ACTION then return end
    lastTick = now

    local player, party, ent = mm:GetPlayer(), mm:GetParty(), mm:GetEntity()
    if not player or not party or not ent then return end

    if player:GetIsZoning() ~= 0 then
        is_zoning_prev = true
        return
    elseif is_zoning_prev then
        reset_combat_flags()
        guests = {}; buff_cache = {}; debuff_queue = {}
        last_engage_target = 0
        is_zoning_prev = false
    end

    if now - lastScanTick >= TICK_SCAN then
        update_membership_and_zones(party)
        scan_buffs(chars, party, player); scan_buffs(guests, party, player)
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

    ------------------------------------------------------------
    -- RDM LOGIC
    ------------------------------------------------------------
    if rdm and rdm.in_zone and now > rdm.action_lock then
        local rdmIdx   = rdm.pt_data.index
        local rdmMP    = party:GetMemberMP(rdmIdx) or 0
        local rdmGroup = math_floor(rdmIdx / 6)

        if rdmMP < 200 then rdm.low_mp_mode = true elseif rdmMP >= 450 then rdm.low_mp_mode = false end
        if rdm.low_mp_mode then goto SKIP_RDM_BUFF end

        if rdm.deb[1] and engageTarget > 0 and ent:GetHPPercent(engageTarget) > 5 then
            local tName  = ent:GetName(engageTarget) or ""
            local tNameL = tName:lower()
            local q      = get_debuff_queue(engageTarget)

            if get_dist_sq(engageTarget, ent) < 441.0 then
                for _, d in ipairs(q) do
                    if not d.done then
                        if d.name == "Silence" and not silence_whitelist[tNameL] then
                            d.done = true
                        else
                            do_action(rdm, string_format('/ma "%s" [t]', d.name), get_cast_delay(d.name), now)
                            d.done = true; goto SKIP_RDM_BUFF
                        end
                    end
                end
            end
        end

        local bKey, bTarget = nil, nil
        for _, key in ipairs(BUFF_PRIORITY) do
            for _, t in ipairs(chars)  do if check_needs(t, key, rdmGroup, rdm, now, party, ent) then bKey, bTarget = key, t; goto found end end
            for _, g in ipairs(guests) do if check_needs(g, key, rdmGroup, rdm, now, party, ent) then bKey, bTarget = key, g; goto found end end
        end
        ::found::

        if bKey and bTarget and rdmMP > 50 then
            local rdmCache = get_cache(rdm)
            local composure_active = rdm.buffs.comp or (rdmCache.comp and now < rdmCache.comp)
            if not composure_active then
                if now > (rdm.comp_lock or 0) then
                    rdm.comp_lock = now + 5.0; rdmCache.comp = now + 3600
                    do_action(rdm, '/ja "Composure" <me>', 1.5, now)
                end
            else
                local is_self = (bTarget.name_lower == rdm.name_lower)
                local spell = "Haste II"
                if     bKey == 'r'   then spell = "Refresh III"
                elseif bKey == 'p'   then spell = is_self and "Phalanx" or "Phalanx II"
                elseif bKey == 'pro' then spell = "Protect V"
                elseif bKey == 'sh'  then spell = "Shell V" end

                rdm.buff_locks[bTarget.name]       = rdm.buff_locks[bTarget.name] or {}
                rdm.buff_locks[bTarget.name][bKey] = now

                local bTargetGroup = math_floor(bTarget.pt_data.index / 6)
                local leadGroup    = chars[1].pt_data and math_floor(chars[1].pt_data.index / 6) or -1
                if bTargetGroup ~= leadGroup then
                    get_cache(bTarget)[bKey] = now + BUFF_RETIMER[bKey]
                end

                do_action(rdm, string_format('/ma "%s" %s', spell, is_self and "<me>" or bTarget.name), get_cast_delay(spell), now)
            end
        end
    end
    ::SKIP_RDM_BUFF::

    ------------------------------------------------------------
    -- CHARACTER LOGIC
    ------------------------------------------------------------
    for _, c in ipairs(chars) do
        if not c.is_main then
		-- Follow runs unconditionally — no zone/party gate.
		-- actual_follow starts nil so the command always fires on first tick.
		if c.f[1] and c.actual_follow ~= true then
			qcmd('/mst ' .. c.name .. ' /ms follow on', true)
			c.actual_follow = true
		elseif not c.f[1] and c.actual_follow ~= false then
			qcmd('/mst ' .. c.name .. ' /ms follow off', true)
			c.actual_follow = false
		end

            -- Everything else needs zone presence and action lock
            if c.in_zone and now > c.action_lock then
                local pIdx   = c.pt_data.index
                local entIdx = party:GetMemberTargetIndex(pIdx)
                if entIdx > 0 then
                    local is_attacking = (ent:GetStatus(entIdx) == 1)

                    -- Absorb TP
                    if c.abs[1] and now > (c.abs_last or 0) + 30 then
                        c.abs_last = now
                        do_action(c, '/ma "Absorb-TP" Aminon', 1.5, now)
                    end

                    -- Engage
                    if c.e[1] then
                        if main_is_attacking and engageTarget > 0 then
                            local time_since = now - (c.last_engage_time or 0)
                            if (c.last_engage_target ~= engageTarget or not is_attacking)
                                and time_since >= ENGAGE_RETRY_GAP then
                                local cmd = '/mst ' .. c.name .. ' /attack [t]'
                                AshitaCore:GetChatManager():QueueCommand(1, cmd)
                                queue_retry(c, cmd, now)
                                c.last_engage_target = engageTarget
                                c.auto_engaged       = true
                                c.last_engage_time   = now
                            end
                        elseif not main_is_attacking and c.auto_engaged then
                            if is_attacking then
                                AshitaCore:GetChatManager():QueueCommand(1, '/mst ' .. c.name .. ' /attack off')
                            end
                            c.last_engage_target = 0
                            c.auto_engaged       = false
                            c.last_engage_time   = 0
                            c.retry              = nil
                        end
                    elseif is_attacking then
                        AshitaCore:GetChatManager():QueueCommand(1, '/mst ' .. c.name .. ' /attack off')
                        c.auto_engaged = false
                        c.retry        = nil
                    end

                    -- Combat job abilities
                    if is_attacking then
                        local tp      = party:GetMemberTP(pIdx)
                        local dist_sq = get_dist_sq(engageTarget, ent)

                        if c.hs[1] and tp >= 350 and not c.buffs.samba then
                            do_action(c, '/ja "Haste Samba" <me>', 1.5, now)
                        end

                        if (c.bs[1] or c.qs[1]) and tp >= 100 and dist_sq < 36.0 and now > (c.step_last or 0) + 10 then
                            local s = (c.bs[1] and c.qs[1])
                                and (c.next_step == "Box Step" and "Quick Step" or "Box Step")
                                or  (c.bs[1] and "Box Step" or "Quick Step")
                            c.next_step, c.step_last = s, now
                            do_action(c, string_format('/ja "%s" <t>', s), 1.5, now)
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
local function draw(t, col)
    imgui.TableNextRow(); imgui.TableNextColumn()
    local c = not t.in_zone and COLOR_OFFLINE
        or (t.low_mp_mode and COLOR_RECOVERING)
        or (os_clock() <= t.action_lock and COLOR_BUSY or col)
    if c then imgui.TextColored(c, t.disp_name) else imgui.Text(t.disp_name) end
    for _, v in ipairs(ui_columns) do
        imgui.TableNextColumn()
        if not (t.is_main and not v.allow_main)
        and not (v.rdm_only and not t.is_rdm)
        and (col ~= COLOR_GUEST or v.key == 'buf') then
            imgui.Checkbox(t.ui_ids[v.key], t[v.key])
        else imgui.TextDisabled("-") end
    end
end

ashita.events.register('d3d_present', 'render_ui', function()
    if not show_ui then return end
    if imgui.Begin('Sync', {true}, bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)) then
        if imgui.BeginTable('SyncTable', #ui_columns + 1, bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg)) then
            imgui.TableSetupColumn('Name', 0, 50)
            for _, col in ipairs(ui_columns) do imgui.TableSetupColumn(col.label, 0, 18) end
            imgui.TableHeadersRow()
            for _, c in ipairs(chars)  do draw(c, nil) end
            for _, g in ipairs(guests) do draw(g, COLOR_GUEST) end
            imgui.EndTable()
        end
    end
    imgui.End()
end)

ashita.events.register('command', 'cmd_logic', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/sync' then return end
    e.blocked = true
    if #args == 1 then show_ui = not show_ui; return end
    local cmds = { f='f', e='e', d='deb', buf='buf', b='buf', qs='qs', bs='bs', abs='abs', hs='hs' }
    local a2, a3, a4 = args[2]:lower(), args[3] and args[3]:lower(), args[4] and args[4]:lower()
    local cmd, tr, st
    if cmds[a2] then cmd, tr, st = cmds[a2], a3 or 'all', a4 else cmd, tr, st = a3 and cmds[a3], a2, a4 end
    if tr == 'ui' then show_ui = (st == 'on') or (not st and not show_ui); return end
    local state  = (st == 'on') and true or ((st == 'off') and false or nil)
    local target = tr == 'all' and 'all' or nil
    if not target then
        for _, c in ipairs(chars)  do if c.name_lower:sub(1,#tr) == tr then target = c; break end end
        if not target then
            for _, g in ipairs(guests) do if g.name_lower:sub(1,#tr) == tr then target = g; break end end
        end
    end
    if target == 'all' then
        for _, c in ipairs(chars)  do if c[cmd] then c[cmd][1] = (state == nil) and (not c[cmd][1]) or state end end
        for _, g in ipairs(guests) do if g[cmd] then g[cmd][1] = (state == nil) and (not g[cmd][1]) or state end end
    elseif target and target[cmd] then
        target[cmd][1] = (state == nil) and (not target[cmd][1]) or state
    end
end)

ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on', true)
    qcmd('/mso /ms follow on', true)
end)
