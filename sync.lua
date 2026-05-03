addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '.050326_opt_fixed'
addon.desc    = 'sync'

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- LUA OPTIMIZATIONS
------------------------------------------------------------
local os_clock      = os.clock
local math_sqrt     = math.sqrt
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

------------------------------------------------------------
-- CONFIGURATION & DICTIONARIES
------------------------------------------------------------
local show_ui = true

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
    { name='x',  is_main=true, f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='x',    is_rdm=true,  f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
	{ name='x',                 f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='x',               f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
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
    { label = 'De', key = 'deb', allow_main = false, rdm_only = true },
    { label = 'Bu', key = 'buf', allow_main = true,  rdm_only = false }
}

------------------------------------------------------------
-- BUFF DURATIONS
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
local RDM_FAST_CAST = 0.50 
local ANIMATION_LOCK = 2.3

local SPELL_CAST_TIMES = {
    ["Refresh III"] = 3.0,  ["Haste II"] = 3.0,
    ["Phalanx II"]  = 3.0,  ["Phalanx"]  = 3.0,
    ["Protect V"]   = 3.0,  ["Shell V"]  = 3.0,
    ["Silence"]     = 3.0,  ["Dia III"]  = 2.5,  
    ["Frazzle III"] = 3.0,  ["Distract III"] = 3.0,
    ["Blind II"]    = 3.0,  ["Slow II"]  = 3.0,
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
local TICK_ACTION = 0.1 
local TICK_SCAN   = 0.5 
local ENGAGE_RETRY_GAP = 0.5
local COMP_RETRY_DELAY = 300
local lastTick    = 0
local lastScanTick = 0
local is_zoning_prev = false

local debuff_list = { "Dia III", "Distract III" }

local qcmd = function(cmd, isFollow)
    local mm = AshitaCore:GetMemoryManager()
    local player = mm:GetPlayer()
    if not isFollow and player and player:GetIsZoning() ~= 0 then return end
    AshitaCore:GetChatManager():QueueCommand(1, cmd) 
end

local function init_char_state(c)
    c.name_lower = c.name:lower() 
    c.disp_name = c.name:sub(1,5):upper() 
    c.actual_follow = (c.f and c.f[1] or false)
    c.step, c.done, c.action_lock, c.magic_lock = 1, false, 0, 0
    c.e_prev = (c.e and c.e[1] or false)
    c.lastTarget, c.lastEngageTime = 0, 0
    c.lastDebuffTarget = 0
    c.lastDebuffTargetName = ""
    c.hs_last, c.step_last, c.abs_last, c.deb_last = 0, 0, 0, 0
    c.buffs = {h=false, r=false, p=false, comp=false, pro=false, sh=false, hsamba=false}
    c.last_cast = {comp=0}
    c.buff_locks = {} 
    c.engaged, c.in_zone, c.silenced = false, false, false
    c.pt_data = nil 
    c.next_step = "Box Step"
    c.ui_ids = {}
    for _, col in ipairs(ui_columns) do
        c.ui_ids[col.key] = '##' .. col.label .. '_' .. c.name_lower
    end
end

for _, c in ipairs(chars) do 
    init_char_state(c) 
    known_cores[c.name_lower] = true 
end

------------------------------------------------------------
-- SCANNING LOGIC 
------------------------------------------------------------
local function update_membership_and_zones(party)
    if not party then return nil end
    local my_zone = party:GetMemberZone(0)
    
    for _, v in pairs(current_active) do v.active_this_scan = false end

    for i = 0, 17 do
        local name = party:GetMemberName(i)
        if name and name ~= "" then
            local zId = party:GetMemberZone(i)
            local sId = party:GetMemberServerId(i)
            local isActive = party:GetMemberIsActive(i)
            if sId ~= 0 and isActive ~= 0 and zId == my_zone then
                local name_l = name:lower()
                if not current_active[name_l] then current_active[name_l] = {} end
                local ca = current_active[name_l]
                ca.index = i
                ca.job = party:GetMemberMainJob(i)
                ca.sId = sId
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
            for _, gst in ipairs(guests) do if gst.name_lower == name_l then is_known = true break end end
        end
        if not is_known then
            local properName = party:GetMemberName(data.index)
            local g = { name = properName, buf = {false} }
            init_char_state(g)
            g.in_zone = true
            g.pt_data = data
            for _, col in ipairs(ui_columns) do g.ui_ids[col.key] = '##G' .. col.label .. '_' .. g.name_lower end
            table.insert(guests, g)
        end
    end
end

local function parse_buff(b, buffs)
    if b == BUFF_IDS.HASTE then buffs.h = true
    elseif b == BUFF_IDS.REFRESH then buffs.r = true
    elseif b == BUFF_IDS.PHALANX then buffs.p = true
    elseif b == BUFF_IDS.COMPOSURE then buffs.comp = true
    elseif b == BUFF_IDS.PROTECT then buffs.pro = true
    elseif b == BUFF_IDS.SHELL then buffs.sh = true
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
        c.buffs.h, c.buffs.r, c.buffs.p, c.buffs.comp, c.buffs.pro, c.buffs.sh, c.buffs.hsamba = false, false, false, false, false, false, false
        
        if c.name_lower == myNameL and player then
            local icons = player:GetStatusIcons()
            for i = 1, 32 do
                local b = icons[i]; if b <= 0 or b == 255 then break end
                parse_buff(b, c.buffs)
            end
        elseif c.pt_data then
            local sId = c.pt_data.sId
            for slot = 0, 5 do
                if partyMgr:GetStatusIconsServerId(slot) == sId then
                    local mPtr = partyBuffsPtr + (0x30 * slot)
                    if mPtr ~= 0 and ashita.memory.read_uint32(mPtr) ~= 0 then
                        for j = 0, 31 do
                            local low = ashita.memory.read_uint8(mPtr + 16 + j)
                            if low == 255 then break end
                            local high = ashita.memory.read_uint8(mPtr + 8 + math_floor(j / 4))
                            high = bit_lshift(bit_band(bit_rshift(high, (j % 4) * 2), 0x03), 8)
                            parse_buff(high + low, c.buffs)
                        end
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
-- LOGIC LOOP
------------------------------------------------------------
ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os_clock()
    if now - lastTick < TICK_ACTION then return end
    lastTick = now

    local mm = AshitaCore:GetMemoryManager()
    if not mm then return end
    
    local player = mm:GetPlayer()
    if not player then return end
    
    local is_zoning = (player:GetIsZoning() ~= 0)
    
    if is_zoning and not is_zoning_prev then 
        guests = {} 
        for _, c in ipairs(chars) do
            c.e[1], c.hs[1], c.bs[1], c.qs[1] = false, false, false, false
            c.abs[1], c.deb[1], c.buf[1] = false, false, false
            c.step, c.done, c.in_zone, c.pt_data = 1, false, false, nil
            c.actual_follow = c.f[1]
            c.buff_locks = {} 
        end
    end
    is_zoning_prev = is_zoning
    if is_zoning then return end
    
    local party = mm:GetParty()
    if not party then return end

    if now - lastScanTick >= TICK_SCAN then
        update_membership_and_zones(party)
        scan_buffs(chars, party, player)
        scan_buffs(guests, party, player)
        lastScanTick = now
    end

    local ent = mm:GetEntity()
    local targ = mm:GetTarget()
    if not ent or not targ then return end 

    local selfIdx = party:GetMemberTargetIndex(0)
    local mainEngaged = (selfIdx > 0 and ent:GetStatus(selfIdx) == 1)
    
    local engageTarget = 0
    local targetHPP = 0

    if selfIdx > 0 then
        local pt = targ:GetTargetIndex(targ:GetIsSubTargetActive())
        if pt == 0 then pt = ent:GetTargetedIndex(selfIdx) end
        if pt > 0 then 
            engageTarget = pt
            targetHPP = ent:GetHPPercent(pt) 
        end
    end

    local rdm = nil
    for _, c in ipairs(chars) do if c.is_rdm then rdm = c break end end

    if rdm and rdm.in_zone and now > rdm.action_lock then
        local rdmIdx = rdm.pt_data.index
        local rdmMP = party:GetMemberMP(rdmIdx) or 0
        local rdmEntIdx = party:GetMemberTargetIndex(rdmIdx)
        local can_cast_debuffs = rdm.deb[1] and mainEngaged and targetHPP >= 10

        ------------------------------------------------------------
        -- 1. DEBUFFING
        ------------------------------------------------------------
        if can_cast_debuffs then
            if rdm.lastDebuffTarget ~= engageTarget then
                rdm.step, rdm.done, rdm.silenced, rdm.lastDebuffTarget = 1, false, false, engageTarget
                rdm.debuff_wait = now + 0.6 
                
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
        -- 2. BUFFING (Haste > Pro > Shell > Phalanx > Refresh)
        ------------------------------------------------------------
        if now > rdm.action_lock then
            local spell_to_cast = nil
            local target_to_buff = nil
            local target_name = nil

            -- Priority order of Buff Keys
            local priority_keys = { 'h', 'pro', 'sh', 'p', 'r' }
            local spell_map = { h="Haste II", pro="Protect V", sh="Shell V", p="Phalanx II", r="Refresh III" }

            for _, key in ipairs(priority_keys) do
                local function find_target_for_spell(list)
                    for _, t in ipairs(list) do
                        if t.buf[1] and t.in_zone and t.pt_data then
                            local rdm_group    = math_floor(rdm.pt_data.index / 6)
                            local target_group = math_floor(t.pt_data.index / 6)
                            local same_party   = (rdm_group == target_group)
                            
                            -- Range Check
                            local targEntIdx = party:GetMemberTargetIndex(t.pt_data.index)
                            local in_range = t.is_rdm or guaranteed_in_range(rdmEntIdx, targEntIdx, 21.0, ent)

                            if in_range then
                                local job = t.pt_data.job
                                rdm.buff_locks[t.name] = rdm.buff_locks[t.name] or {h=0, pro=0, sh=0, p=0, r=0}
                                local t_locks = rdm.buff_locks[t.name]
                                local can_read = (t.pt_data.index <= 5)

                                -- Logic checks for specific spells
                                local valid_spell = true
                                if key == 'r' and (not same_party or not refresh_jobs[job]) then valid_spell = false end
                                if key == 'p' and not same_party then valid_spell = false end

                                if valid_spell then
                                    local needs_buff = false
                                    if can_read then
                                        needs_buff = (not t.buffs[key]) and (now - t_locks[key] > BUFF_RETRY_GAP)
                                    else
                                        needs_buff = (now - t_locks[key] > BUFF_RETIMER[key])
                                    end

                                    if needs_buff then
                                        target_to_buff = t
                                        target_name = t.name
                                        spell_to_cast = spell_map[key]
                                        
                                        -- Handle self-phalanx
                                        if key == 'p' and t.is_rdm then 
                                            spell_to_cast = "Phalanx" 
                                            target_name = "<me>"
                                        end

                                        t_locks[key] = now
                                        return true
                                    end
                                end
                            end
                        end
                    end
                    return false
                end

                if find_target_for_spell(chars) or find_target_for_spell(guests) then break end
            end

            if target_to_buff and rdmMP >= 50 then
                if not rdm.buffs.comp and (now - rdm.last_cast.comp > COMP_RETRY_DELAY) then
                    do_action(rdm, '/ja "Composure" <me>', 2.0, now, false)
                    rdm.last_cast.comp = now
                else
                    do_action(rdm, string_format('/ma "%s" %s', spell_to_cast, target_name), get_cast_delay(spell_to_cast), now, false)
                end
            end
        end
    end

    for _, c in ipairs(chars) do
        if not c.is_main then
            local is_magic_busy = (now <= (c.magic_lock or 0))
            local desired_follow = c.f[1] and not is_magic_busy
            if c.actual_follow ~= desired_follow then
                qcmd(string_format('/mst %s /ms follow %s', c.name, desired_follow and 'on' or 'off'), true)
                c.actual_follow = desired_follow
            end

            if c.in_zone and c.pt_data and now > c.action_lock then
                local pIdx = c.pt_data.index
                local mIdx = party:GetMemberTargetIndex(pIdx)
                c.engaged = (mIdx > 0 and ent:GetStatus(mIdx) == 1)
                
                if mainEngaged and c.e[1] then
                    if (c.lastTarget ~= engageTarget or not c.engaged) and (now - c.lastEngageTime > ENGAGE_RETRY_GAP) then
                        do_action(c, '/attack [t]', 1.2, now, false)
                        c.lastTarget, c.lastEngageTime = engageTarget, now
                    end
                elseif (not mainEngaged or not c.e[1]) and c.engaged then 
                    qcmd(string_format('/mst %s /attack off', c.name)) 
                end
                
                if c.engaged then
                    local tp = party:GetMemberTP(pIdx)
                    local cEntIdx = party:GetMemberTargetIndex(pIdx)
                    local in_magic_range = guaranteed_in_range(cEntIdx, mIdx, 21.0, ent)
                    local in_melee_range = guaranteed_in_range(cEntIdx, mIdx, 6.0, ent)

                    if c.abs[1] and in_magic_range and now > c.abs_last + 45 then
                        do_action(c, '/ma "Absorb-TP" [t]', 3.0, now, true) 
                        c.abs_last = now
                    elseif c.hs[1] and tp >= 350 and not c.buffs.hsamba and now > c.hs_last + 5 then
                        do_action(c, '/ja "Haste Samba" <me>', 2.0, now, false) 
                        c.hs_last = now
                    elseif (c.bs[1] or c.qs[1]) and tp >= 100 and in_melee_range and now > c.step_last + 12 then
                        local step_to_use = (c.bs[1] and c.qs[1]) and c.next_step or (c.bs[1] and "Box Step" or "Quick Step")
                        if c.bs[1] and c.qs[1] then c.next_step = (c.next_step == "Box Step") and "Quick Step" or "Box Step" end
                        do_action(c, string_format('/ja "%s" [t]', step_to_use), 2.0, now, false) 
                        c.step_last = now
                    end
                end
            end
        end
    end
end)

------------------------------------------------------------
-- UI & EVENTS
------------------------------------------------------------
local window_state = {true} 

ashita.events.register('d3d_present', 'render_ui', function ()
    if not show_ui then return end
    local now = os_clock()
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, UI_PADDING) 
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, UI_SPACING)
    
    local is_open = imgui.Begin('Sync', window_state, bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar))
    if is_open then
        if imgui.BeginTable('Sync_Main_Table', #ui_columns + 1, bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg)) then
            imgui.TableSetupColumn('Name', 0, 50); 
            for _, col in ipairs(ui_columns) do imgui.TableSetupColumn(col.label, 0, 18) end
            imgui.TableHeadersRow()
            
            -- Render Core Characters
            for _, c in ipairs(chars) do
                imgui.TableNextRow(); imgui.TableNextColumn()
                
                -- Status Coloring Logic
                if not c.in_zone then 
                    imgui.TextColored(COLOR_OFFLINE, c.disp_name)
                elseif now <= (c.action_lock or 0) then 
                    imgui.TextColored(COLOR_BUSY, c.disp_name) 
                else 
                    imgui.Text(c.disp_name) 
                end
                
                for _, col in ipairs(ui_columns) do
                    imgui.TableNextColumn()
                    local can_show = not (c.is_main and not col.allow_main) and not (col.rdm_only and not c.is_rdm)
                    if can_show then 
                        imgui.Checkbox(c.ui_ids[col.key], c[col.key]) 
                    else 
                        imgui.TextDisabled("-") 
                    end
                end
            end
            
            -- Render Guests (Dynamic Party Members)
            for _, g in ipairs(guests) do
                imgui.TableNextRow(); imgui.TableNextColumn()
                imgui.TextColored(COLOR_GUEST, g.disp_name)
                for _, col in ipairs(ui_columns) do
                    imgui.TableNextColumn(); 
                    if col.key == 'buf' then 
                        imgui.Checkbox(g.ui_ids[col.key], g[col.key]) 
                    else 
                        imgui.TextDisabled("-") 
                    end
                end
            end
            imgui.EndTable()
        end
    end
    imgui.End()
    imgui.PopStyleVar(2)
end)

ashita.events.register('command', 'cmd_logic', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/sync' then return end
    e.blocked = true

    -- Toggle UI with just /sync
    if #args == 1 then
        show_ui = not show_ui
        return
    end

    local commands = { 
        f = 'f', follow = 'f', e = 'e',
        d = 'deb', de = 'deb', deb = 'deb',
        buf = 'buf', buff = 'buf', b = 'buf',
        qs = 'qs', bs = 'bs', abs = 'abs', hs = 'hs'
    }

    local arg2 = args[2] and args[2]:lower()
    local arg3 = args[3] and args[3]:lower()
    local arg4 = args[4] and args[4]:lower()

    local cmd, target_raw, state_raw

    -- Smart Parsing (Handles shorthand like /sync f on)
    if commands[arg2] then
        cmd, target_raw, state_raw = commands[arg2], 'all', arg3
    elseif arg2 == 'all' or arg2 == 'ui' then
        target_raw, cmd, state_raw = arg2, commands[arg3] or arg3, arg4
    else
        target_raw, cmd, state_raw = arg2, commands[arg3] or arg3, arg4
    end

    if target_raw == 'ui' then
        show_ui = (state_raw == 'on') or (not state_raw and not show_ui)
        return
    end

    -- Prefix Matching for Character Names
    local function resolve(name)
        if not name or name == 'all' then return 'all' end
        for _, c in ipairs(chars) do
            if c.name_lower:sub(1, #name) == name then return c end
        end
        return nil
    end

    local target = resolve(target_raw)
    
    -- Determine state: true (on), false (off), or nil (toggle)
    local state = nil
    if state_raw == 'on' then state = true
    elseif state_raw == 'off' then state = false end

    local function apply(key, val)
        if not key then return end
        if target == 'all' then
            for _, c in ipairs(chars) do
                if c[key] then 
                    -- Toggle if val is nil, otherwise set absolute
                    c[key][1] = (val == nil) and (not c[key][1]) or val 
                end
            end
        elseif target and target[key] then
            target[key][1] = (val == nil) and (not target[key][1]) or val
            if key == 'f' then target.actual_follow = nil end
        end
    end

    apply(cmd, state)
end)

ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on', true)
    qcmd('/mso /ms follow on', true)
end)
