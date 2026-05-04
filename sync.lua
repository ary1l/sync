addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '.050326'
addon.desc    = 'sync'

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- LUA OPTIMIZATIONS
------------------------------------------------------------
local os_clock      = os.clock
local math_sqrt      = math.sqrt
local math_floor    = math.floor
local string_format = string.format
local bit_lshift    = bit.lshift
local bit_rshift    = bit.rshift
local bit_band      = bit.band

local UI_PADDING    = {2, 2}
local UI_SPACING    = {2, 2}
local COLOR_OFFLINE = {1.0, 0.2, 0.2, 1.0}
local COLOR_BUSY    = {1.0, 0.8, 0.0, 1.0}
local COLOR_GUEST    = {0.6, 0.9, 1.0, 1.0}
local COLOR_RECOVERING = {0.4, 0.6, 1.0, 1.0}

------------------------------------------------------------
-- CONFIGURATION & DICTIONARIES
------------------------------------------------------------
local show_ui = true

local BUFF_IDS = {
    HASTE = 33, PROTECT = 40, SHELL = 41, REFRESH = 43,
    PHALANX = 116, HASTE_SAMBA = 370, COMPOSURE = 419
}

local JOB_IDS = {
    WHM = 3, BLM = 4, RDM = 5, BRD = 6, PLD = 7, DRK = 8,
    SMN = 15, BLU = 16, GEO = 21, RUN = 22
}

local silence_whitelist = {
    ["imp"] = true,
    ["eschan corse"] = true
}

local refresh_jobs = {
    [JOB_IDS.WHM] = true, [JOB_IDS.BLM] = true, [JOB_IDS.RDM] = true,
    [JOB_IDS.BRD] = true, [JOB_IDS.PLD] = true, [JOB_IDS.DRK] = true, 
    [JOB_IDS.SMN] = true, [JOB_IDS.BLU] = true, [JOB_IDS.GEO] = true, 
    [JOB_IDS.RUN] = true
}

local chars = {
    { name='shaymin',  is_main=true, f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='goomy',    is_rdm=true,  f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='muunch',                  f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='slowpoke',                f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
}

local guests = {}
local current_active = {}
local known_cores = {}

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
-- BUFF DURATIONS & RETRY LOGIC
------------------------------------------------------------
local BUFF_RETIMER = {
    r   = 300,   -- Refresh III
    h   = 270,   -- Haste II
    p   = 270,   -- Phalanx II
    pro = 3300,  -- Protect V
    sh  = 3300,  -- Shell V
}
local BUFF_RETRY_GAP = 8.0

------------------------------------------------------------
-- CASTING & DELAY CALCULATIONS
------------------------------------------------------------
local RDM_FAST_CAST  = 0.50
local ANIMATION_LOCK = 2.3

local SPELL_CAST_TIMES = {
    ["Refresh III"] = 3.0,  ["Haste II"]      = 3.0,
    ["Phalanx II"]  = 3.0,  ["Phalanx"]       = 3.0,
    ["Protect V"]   = 3.0,  ["Shell V"]        = 3.0,
    ["Silence"]     = 3.0,  ["Dia III"]        = 2.5,
    ["Frazzle III"] = 3.0,  ["Distract III"]   = 3.0,
    ["Blind II"]    = 3.0,  ["Slow II"]        = 3.0,
    ["Paralyze II"] = 3.0,
}

local function get_cast_delay(spell)
    local base_time = SPELL_CAST_TIMES[spell] or 3.0
    return (base_time * (1.0 - RDM_FAST_CAST)) + ANIMATION_LOCK
end

local function get_yalms(entIdx, ent)
    if not entIdx or entIdx == 0 then return 999 end
    local dSq = ent:GetDistance(entIdx)
    if not dSq or dSq < 0 then return 999 end
    return math_sqrt(dSq)
end

local function guaranteed_in_range(casterIdx, targetIdx, max_yalms, ent)
    if not casterIdx or not targetIdx then return false end
    local d1 = get_yalms(casterIdx, ent)
    local d2 = get_yalms(targetIdx, ent)
    return (d1 + d2) <= max_yalms
end

------------------------------------------------------------
-- INTERNAL STATE & SAFETY
------------------------------------------------------------
local TICK_ACTION      = 0.1
local TICK_SCAN        = 0.5
local ENGAGE_RETRY_GAP = 0.5
local COMP_RETRY_DELAY = 10
local lastTick         = 0
local lastScanTick     = 0
local is_zoning_prev   = false

local debuff_list = { "Dia III", "Distract III" }

local qcmd = function(cmd, isFollow)
    local mm = AshitaCore:GetMemoryManager()
    local player = mm:GetPlayer()
    if not isFollow and player and player:GetIsZoning() ~= 0 then return end
    AshitaCore:GetChatManager():QueueCommand(1, cmd)
end

local function init_char_state(c)
    c.name_lower    = c.name:lower()
    c.disp_name     = c.name:sub(1,5):upper()
    c.actual_follow = (c.f and c.f[1] or false)
    c.step, c.done, c.action_lock, c.magic_lock = 1, false, 0, 0
    c.e_prev        = (c.e and c.e[1] or false)
    c.lastTarget, c.lastEngageTime = 0, 0
    c.lastDebuffTarget     = 0
    c.lastDebuffTargetName = ""
    c.debuff_wait   = 0
    c.hs_last, c.step_last, c.abs_last, c.deb_last = 0, 0, 0, 0
    c.buffs     = { h=false, r=false, p=false, comp=false, pro=false, sh=false, hsamba=false }
    c.last_cast = { comp=0 }
    c.buff_locks    = {}
    c.engaged, c.in_zone, c.silenced = false, false, false
    c.pt_data   = nil
    c.entIdx    = 0
    c.next_step     = "Box Step"
    c.low_mp_mode   = false
    c.ui_ids    = {}
    for _, col in ipairs(ui_columns) do
        c.ui_ids[col.key] = '##' .. col.label .. '_' .. c.name_lower
    end
end

for _, c in ipairs(chars) do
    init_char_state(c)
    known_cores[c.name_lower] = true
end

------------------------------------------------------------
-- SCANNING & UTILITY
------------------------------------------------------------
local function update_membership_and_zones(party)
    if not party then return nil end
    local my_zone = party:GetMemberZone(0)
    for _, v in pairs(current_active) do v.active_this_scan = false end

    for i = 0, 17 do
        local name = party:GetMemberName(i)
        if name and name ~= "" then
            local zId      = party:GetMemberZone(i)
            local sId      = party:GetMemberServerId(i)
            local isActive = party:GetMemberIsActive(i)
            if sId ~= 0 and isActive ~= 0 and zId == my_zone then
                local name_l = name:lower()
                if not current_active[name_l] then current_active[name_l] = {} end
                local ca = current_active[name_l]
                ca.index            = i
                ca.job              = party:GetMemberMainJob(i)
                ca.sId              = sId
                ca.active_this_scan = true
            end
        end
    end

    for k, v in pairs(current_active) do
        if not v.active_this_scan then current_active[k] = nil end
    end

    for _, c in ipairs(chars) do
        c.pt_data = current_active[c.name_lower]
        c.in_zone = (c.pt_data ~= nil)
    end

    for i = #guests, 1, -1 do
        local g = guests[i]
        g.pt_data = current_active[g.name_lower]
        if not g.pt_data then table.remove(guests, i)
        else g.in_zone = true end
    end

    for name_l, data in pairs(current_active) do
        local is_known = known_cores[name_l]
        if not is_known then
            for _, gst in ipairs(guests) do if gst.name_lower == name_l then is_known = true; break end end
        end
        if not is_known then
            local properName = party:GetMemberName(data.index)
            local g = { name = properName, buf = {false} }
            init_char_state(g)
            g.in_zone, g.pt_data = true, data
            for _, col in ipairs(ui_columns) do g.ui_ids[col.key] = '##G' .. col.label .. '_' .. g.name_lower end
            table.insert(guests, g)
        end
    end
end

local function parse_buff(b, buffs)
    if      b == BUFF_IDS.HASTE       then buffs.h      = true
    elseif b == BUFF_IDS.REFRESH     then buffs.r      = true
    elseif b == BUFF_IDS.PHALANX     then buffs.p      = true
    elseif b == BUFF_IDS.COMPOSURE   then buffs.comp   = true
    elseif b == BUFF_IDS.PROTECT     then buffs.pro    = true
    elseif b == BUFF_IDS.SHELL       then buffs.sh     = true
    elseif b == BUFF_IDS.HASTE_SAMBA then buffs.hsamba = true
    end
end

local function scan_buffs(t, partyMgr, player)
    local ptr_mgr = AshitaCore:GetPointerManager()
    local pPtr = ptr_mgr:Get('party.statusicons')
    if pPtr == 0 then return end

    local partyBuffsPtr = ashita.memory.read_uint32(pPtr)
    if not partyMgr or partyBuffsPtr == 0 then return end

    local myNameL = (partyMgr:GetMemberName(0) or ''):lower()

    for _, c in ipairs(t) do
        if not c.in_zone then goto continue end
        c.buffs.h, c.buffs.r, c.buffs.p, c.buffs.comp,
        c.buffs.pro, c.buffs.sh, c.buffs.hsamba = false, false, false, false, false, false, false

        if c.name_lower == myNameL and player then
            local buffs = player:GetBuffs()
            if buffs then
                for i = 0, 31 do
                    local b = buffs[i]
                    if not b or b <= 0 or b == 255 then break end
                    parse_buff(b, c.buffs)
                end
            end
        elseif c.pt_data then
            local sId = c.pt_data.sId
            for slot = 0, 5 do
                local mPtr = partyBuffsPtr + (0x30 * slot)
                if mPtr ~= 0 and ashita.memory.read_uint32(mPtr) == sId then
                    for j = 0, 31 do
                        local low = ashita.memory.read_uint8(mPtr + 16 + j)
                        if low == 255 then break end
                        local high = ashita.memory.read_uint8(mPtr + 8 + math_floor(j / 4))
                        high = bit_lshift(bit_band(bit_rshift(high, (j % 4) * 2), 0x03), 8)
                        parse_buff(high + low, c.buffs)
                    end
                    break
                end
            end
        end
        ::continue::
    end
end

local function do_action(c, cmd, lock_time, current_time, stop_movement)
    if stop_movement and c.f[1] and c.actual_follow ~= false then
        qcmd(string_format('/mst %s /ms follow off', c.name), true)
        c.actual_follow = false
    end
    qcmd(string_format('/mst %s %s', c.name, cmd))
    c.action_lock = current_time + lock_time
    if stop_movement then c.magic_lock = current_time + lock_time end
end

------------------------------------------------------------
-- ALLIANCE CYCLE COMPLETION CHECK
-- Ensures Haste, Protect, Shell, and applicable Phalanx/Refresh are cast
------------------------------------------------------------
local function check_alliance_cycle_done(t, rdm)
    local tl = rdm.buff_locks[t.name]
    if not tl then return end
    
    local rdm_grp = math_floor(rdm.pt_data.index / 6)
    local t_grp   = math_floor(t.pt_data.index / 6)
    local same_party = (rdm_grp == t_grp)

    local core_done = (tl.h or 0) > 0 and (tl.pro or 0) > 0 and (tl.sh or 0) > 0
    local refresh_done = (not same_party or not refresh_jobs[t.pt_data.job] or (tl.r or 0) > 0)
    local phalanx_done = (not same_party or (tl.p or 0) > 0)

    if core_done and refresh_done and phalanx_done then
        t.buf[1] = false
        rdm.buff_locks[t.name] = { h=0, pro=0, sh=0, p=0, r=0 }
    end
end

------------------------------------------------------------
-- MAIN LOGIC LOOP
------------------------------------------------------------
ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os_clock()
    if now - lastTick < TICK_ACTION then return end
    lastTick = now

    local mm = AshitaCore:GetMemoryManager()
    if not mm then return end
    local player, party, ent, targ = mm:GetPlayer(), mm:GetParty(), mm:GetEntity(), mm:GetTarget()
    if not player or not party or not ent or not targ then return end

    local is_zoning = (player:GetIsZoning() ~= 0)
    if is_zoning and not is_zoning_prev then
        guests = {}
        for _, c in ipairs(chars) do
            c.step, c.done, c.in_zone, c.pt_data, c.actual_follow = 1, false, false, nil, c.f[1]
            c.buff_locks, c.low_mp_mode = {}, false
        end
    end
    is_zoning_prev = is_zoning
    if is_zoning then return end

    if now - lastScanTick >= TICK_SCAN then
        update_membership_and_zones(party)
        scan_buffs(chars, party, player); scan_buffs(guests, party, player)
        lastScanTick = now
    end

    local selfIdx = party:GetMemberTargetIndex(0)
    
    -- Track leader/main engagement instead of local window engagement
    local main_char = nil
    for _, c in ipairs(chars) do if c.is_main then main_char = c; break end end
    local main_idx = (main_char and main_char.pt_data) and party:GetMemberTargetIndex(main_char.pt_data.index) or selfIdx
    local mainEngaged = (main_idx > 0 and ent:GetStatus(main_idx) == 1)

    local engageTarget, targetHPP = 0, 0
    if main_idx > 0 then
        local pt = (main_idx == selfIdx) and targ:GetTargetIndex(targ:GetIsSubTargetActive()) or 0
        if pt == 0 then pt = ent:GetTargetedIndex(main_idx) end
        if pt > 0 then engageTarget, targetHPP = pt, ent:GetHPPercent(pt) end
    end

    local rdm = nil
    for _, c in ipairs(chars) do if c.is_rdm then rdm = c; break end end

    if rdm and rdm.in_zone and now > rdm.action_lock then
        local rdmIdx    = rdm.pt_data.index
        local rdmMP      = party:GetMemberMP(rdmIdx) or 0
        local rdmEntIdx = party:GetMemberTargetIndex(rdmIdx)

        -- MP Hysteresis
        if rdmMP < 200 then rdm.low_mp_mode = true
        elseif rdmMP >= 450 then rdm.low_mp_mode = false end

        if not rdm.low_mp_mode then
            ------------------------------------------------------------
            -- 1. DEBUFFING
            ------------------------------------------------------------
            if rdm.deb[1] and mainEngaged and targetHPP >= 10 then
                if rdm.lastDebuffTarget ~= engageTarget then
                    rdm.step, rdm.done, rdm.silenced, rdm.lastDebuffTarget = 1, false, false, engageTarget
                    rdm.debuff_wait = now + 0.45
                    local tNameRaw = ent:GetName(engageTarget)
                    rdm.lastDebuffTargetName = tNameRaw and tNameRaw:lower() or ""
                end

                if not rdm.done and now > (rdm.debuff_wait or 0) then
                    if guaranteed_in_range(rdmEntIdx, engageTarget, 21.0, ent) and rdmMP >= 40 then
                        if not rdm.silenced and silence_whitelist[rdm.lastDebuffTargetName] then
                            do_action(rdm, '/ma "Silence" [t]', get_cast_delay("Silence"), now, true)
                            rdm.silenced = true
                        else
                            local s = debuff_list[rdm.step]
                            if s then
                                do_action(rdm, string_format('/ma "%s" [t]', s), get_cast_delay(s), now, true)
                                rdm.step = rdm.step + 1
                            else rdm.done = true end
                        end
                    end
                end
            end

            ------------------------------------------------------------
            -- 2. BUFFING (PRIORITY: SELF > PARTY > ALLIANCE > GUESTS)
            ------------------------------------------------------------
            if now > rdm.action_lock then
                local spell_to_cast, target_name = nil, nil
                local spell_map = { h="Haste II", pro="Protect V", sh="Shell V", p="Phalanx II", r="Refresh III" }

                rdm.buff_locks[rdm.name] = rdm.buff_locks[rdm.name] or { h=0, pro=0, sh=0, p=0, r=0 }

                local function check_needs(t, key)
                    if not t or not t.in_zone or not t.pt_data or not t.buf[1] then return false end

                    local rdm_grp    = math_floor(rdm.pt_data.index / 6)
                    local t_grp      = math_floor(t.pt_data.index / 6)
                    local same_party = (rdm_grp == t_grp)
                    local targEntIdx = party:GetMemberTargetIndex(t.pt_data.index)
                    if not (t.is_rdm or guaranteed_in_range(rdmEntIdx, targEntIdx, 21.0, ent)) then return false end

                    if key == 'r' and (not same_party or not refresh_jobs[t.pt_data.job]) then return false end
                    if key == 'p' and not same_party then return false end

                    rdm.buff_locks[t.name] = rdm.buff_locks[t.name] or { h=0, pro=0, sh=0, p=0, r=0 }
                    local t_locks = rdm.buff_locks[t.name]

                    if t.pt_data.index <= 5 then
                        return (not t.buffs[key]) and (now - t_locks[key] > BUFF_RETRY_GAP)
                    else
                        return ((not t.buffs[key]) and (now - t_locks[key] > BUFF_RETRY_GAP))
                            or (now - t_locks[key] > BUFF_RETIMER[key])
                    end
                end

                -- SELF PRIORITY
                for _, k in ipairs({'h', 'r'}) do
                    if check_needs(rdm, k) then
                        spell_to_cast, target_name = spell_map[k], "<me>"
                        rdm.buff_locks[rdm.name][k] = now; break
                    end
                end

                -- PARTY / ALLIANCE / GUEST PRIORITY
                if not spell_to_cast then
                    for _, key in ipairs({'h', 'pro', 'sh', 'p', 'r'}) do
                        local found = false
                        for _, t in ipairs(chars) do
                            if t.pt_data and t.pt_data.index <= 5 and check_needs(t, key) then
                                spell_to_cast = spell_map[key]; target_name = t.name
                                if key == 'p' and t.is_rdm then spell_to_cast, target_name = "Phalanx", "<me>" end
                                rdm.buff_locks[t.name][key] = now
                                found = true; break
                            end
                        end
                        if not found then
                            for _, t in ipairs(chars) do
                                if t.pt_data and t.pt_data.index > 5 and check_needs(t, key) then
                                    spell_to_cast = spell_map[key]; target_name = t.name
                                    rdm.buff_locks[t.name][key] = now
                                    check_alliance_cycle_done(t, rdm)
                                    found = true; break
                                end
                            end
                        end
                        if not found then
                            for _, t in ipairs(guests) do
                                if check_needs(t, key) then
                                    spell_to_cast = spell_map[key]; target_name = t.name
                                    rdm.buff_locks[t.name][key] = now
                                    if t.pt_data.index > 5 then check_alliance_cycle_done(t, rdm) end
                                    found = true; break
                                end
                            end
                        end
                        if found then break end
                    end
                end

                if spell_to_cast and rdmMP >= 50 then
                    if not rdm.buffs.comp and (now - (rdm.last_cast.comp or 0) > COMP_RETRY_DELAY) then
                        do_action(rdm, '/ja "Composure" <me>', 1.5, now, false)
                        rdm.last_cast.comp = now
                    else
                        do_action(rdm, string_format('/ma "%s" %s', spell_to_cast, target_name), get_cast_delay(spell_to_cast), now, false)
                    end
                end
            end
        end
    end

    -- Character Actions
    for _, c in ipairs(chars) do
        if not c.is_main then
            local is_magic_busy = (now <= (c.magic_lock or 0))
            if c.actual_follow ~= (c.f[1] and not is_magic_busy) then
                c.actual_follow = c.f[1] and not is_magic_busy
                qcmd(string_format('/mst %s /ms follow %s', c.name, c.actual_follow and 'on' or 'off'), true)
            end

            if c.in_zone and c.pt_data and now > c.action_lock then
                local pIdx = c.pt_data.index
                c.entIdx   = party:GetMemberTargetIndex(pIdx)
                local mIdx = c.entIdx
                c.engaged  = (mIdx > 0 and ent:GetStatus(mIdx) == 1)

                if mainEngaged and c.e[1] then
                    if (c.lastTarget ~= engageTarget or not c.engaged) and (now - c.lastEngageTime > ENGAGE_RETRY_GAP) then
                        do_action(c, '/attack [t]', 1.2, now, false)
                        c.lastTarget, c.lastEngageTime = engageTarget, now
                    end
                elseif (not mainEngaged or not c.e[1]) and c.engaged then
                    qcmd(string_format('/mst %s /attack off', c.name))
                end

                if c.engaged then
                    local tp, cEntIdx = party:GetMemberTP(pIdx), c.entIdx
                    if c.abs[1] and guaranteed_in_range(cEntIdx, mIdx, 21.0, ent) and now > c.abs_last + 45 then
                        do_action(c, '/ma "Absorb-TP" [t]', 3.0, now, true); c.abs_last = now
                    elseif c.hs[1] and tp >= 350 and not c.buffs.hsamba and now > c.hs_last + 5 then
                        do_action(c, '/ja "Haste Samba" <me>', 2.0, now, false); c.hs_last = now
                    elseif (c.bs[1] or c.qs[1]) and tp >= 100 and guaranteed_in_range(cEntIdx, mIdx, 6.0, ent) and now > c.step_last + 12 then
                        local step = (c.bs[1] and c.qs[1]) and c.next_step or (c.bs[1] and "Box Step" or "Quick Step")
                        if c.bs[1] and c.qs[1] then c.next_step = (c.next_step == "Box Step") and "Quick Step" or "Box Step" end
                        do_action(c, string_format('/ja "%s" [t]', step), 2.0, now, false); c.step_last = now
                    end
                end
            end
        end
    end
end)

------------------------------------------------------------
-- UI RENDERING
------------------------------------------------------------
ashita.events.register('d3d_present', 'render_ui', function ()
    if not show_ui then return end
    local now = os_clock()
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, UI_PADDING)
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, UI_SPACING)

    if imgui.Begin('Sync', {true}, bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)) then
        if imgui.BeginTable('SyncTable', #ui_columns + 1, bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg)) then
            imgui.TableSetupColumn('Name', 0, 50)
            for _, col in ipairs(ui_columns) do imgui.TableSetupColumn(col.label, 0, 18) end
            imgui.TableHeadersRow()

            local function draw_row(t, color)
                imgui.TableNextRow(); imgui.TableNextColumn()
                local label_color = not t.in_zone and COLOR_OFFLINE
                    or (t.low_mp_mode and COLOR_RECOVERING
                    or (now <= t.action_lock and COLOR_BUSY or color))
                if label_color then imgui.TextColored(label_color, t.disp_name) else imgui.Text(t.disp_name) end
                for _, col in ipairs(ui_columns) do
                    imgui.TableNextColumn()
                    local valid = not (t.is_main and not col.allow_main)
                        and not (col.rdm_only and not t.is_rdm)
                        and (color ~= COLOR_GUEST or col.key == 'buf')
                    if valid then imgui.Checkbox(t.ui_ids[col.key], t[col.key]) else imgui.TextDisabled("-") end
                end
            end

            for _, c in ipairs(chars) do draw_row(c, nil) end
            for _, g in ipairs(guests) do draw_row(g, COLOR_GUEST) end
            imgui.EndTable()
        end
    end
    imgui.End(); imgui.PopStyleVar(2)
end)

------------------------------------------------------------
-- COMMANDS & LOAD
------------------------------------------------------------
ashita.events.register('command', 'cmd_logic', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/sync' then return end
    e.blocked = true

    if #args == 1 then show_ui = not show_ui; return end
    local cmds = { f='f', e='e', deb='deb', buf='buf', b='buf', qs='qs', bs='bs', abs='abs', hs='hs' }
    local arg2, arg3, arg4 = args[2]:lower(), args[3] and args[3]:lower(), args[4] and args[4]:lower()
    local cmd, target_raw, state_raw
    if cmds[arg2] then
        cmd, target_raw, state_raw = cmds[arg2], arg3 or 'all', arg4
    else
        cmd, target_raw, state_raw = arg3 and cmds[arg3], arg2, arg4
    end

    if target_raw == 'ui' then show_ui = (state_raw == 'on') or (not state_raw and not show_ui); return end

    local state   = (state_raw == 'on') and true or ((state_raw == 'off') and false or nil)
    local target = target_raw == 'all' and 'all' or nil
    if not target then for _, c in ipairs(chars) do if c.name_lower:sub(1, #target_raw) == target_raw then target = c; break end end end

    if target == 'all' then
        for _, c in ipairs(chars) do if c[cmd] then c[cmd][1] = (state == nil) and (not c[cmd][1]) or state end end
        for _, g in ipairs(guests) do if g[cmd] then g[cmd][1] = (state == nil) and (not g[cmd][1]) or state end end
    elseif target and target[cmd] then
        target[cmd][1] = (state == nil) and (not target[cmd][1]) or state
    end
end)

ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on', true)
    qcmd('/mso /ms follow on', true)
end)
