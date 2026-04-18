addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '.04292_optimized_v2'
addon.desc    = 'sync'

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- CONFIGURATION & DICTIONARIES
------------------------------------------------------------
local show_ui = true

-- Pre-lowercased for instant comparisons
local ROLES = {
    main = 'shaymin',
    rdm  = 'goomy'
}

local BUFF_IDS = {
    HASTE = 33, PROTECT = 40, SHELL = 41, REFRESH = 43,
    PHALANX = 116, HASTE_SAMBA = 370, COMPOSURE = 419
}

local JOB_IDS = {
    WHM = 3, BLM = 4, RDM = 5, PLD = 7, DRK = 8, 
    SMN = 15, BLU = 16, GEO = 21, RUN = 22
}

local silence_whitelist = { 
    ["ahriman"] = true, ["crawler"] = true, ["fly"] = true, ["ghost"] = true, 
    ["hecteyes"] = true, ["imp"] = true, ["shadow"] = true, ["skeleton"] = true,
    ["eschan corse"] = true 
}

local refresh_jobs = { 
    [JOB_IDS.WHM] = true, [JOB_IDS.BLM] = true, [JOB_IDS.RDM] = true, 
    [JOB_IDS.PLD] = true, [JOB_IDS.DRK] = true, [JOB_IDS.SMN] = true, 
    [JOB_IDS.BLU] = true, [JOB_IDS.GEO] = true, [JOB_IDS.RUN] = true 
} 

local chars = {
    { name='shaymin',  f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='muunch',   f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='slowpoke', f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='goomy',    f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
}

local guests = {}

------------------------------------------------------------
-- CASTING & DELAY CALCULATIONS
------------------------------------------------------------
local RDM_FAST_CAST = 0.70 -- Adjust this to match Goomy's actual FC gear/traits
local ANIMATION_LOCK = 1.5 -- Standard FFXI physical animation lock

local SPELL_CAST_TIMES = {
    ["Refresh III"] = 3.0,  ["Haste II"] = 3.0,
    ["Phalanx II"]  = 3.0,  ["Phalanx"]  = 3.0,
    ["Protect V"]   = 3.0,  ["Shell V"]  = 3.0,
    ["Silence"]     = 2.0,  ["Dia III"]  = 1.0,
    ["Frazzle III"] = 2.0,  ["Distract III"] = 2.0,
    ["Blind II"]    = 2.0,  ["Slow II"]  = 2.0,
    ["Paralyze II"] = 2.0,
}

local function get_cast_delay(spell)
    local base_time = SPELL_CAST_TIMES[spell] or 2.0
    local actual_cast_time = base_time * (1.0 - RDM_FAST_CAST)
    return actual_cast_time + ANIMATION_LOCK
end

------------------------------------------------------------
-- INTERNAL STATE & SAFETY
------------------------------------------------------------
local TICK_INTERVAL    = 0.1 -- Lowered to 0.1 for maximum responsiveness
local ENGAGE_RETRY_GAP = 0.5
local COMP_RETRY_DELAY = 300
local lastTick         = 0
local is_zoning_prev   = false

local debuff_list = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Slow II", "Paralyze II" }

local mm = AshitaCore:GetMemoryManager()

local qcmd = function(cmd, isFollow) 
    if not isFollow and mm:GetPlayer():GetIsZoning() ~= 0 then return end
    AshitaCore:GetChatManager():QueueCommand(1, cmd) 
end

local partyBuffsPtr = AshitaCore:GetPointerManager():Get('party.statusicons')
partyBuffsPtr = ashita.memory.read_uint32(partyBuffsPtr)

local function init_char_state(c)
    c.name_lower = c.name:lower() -- Cached to prevent string generation spam
    c.disp_name = c.name:sub(1,5):upper() -- Cached for UI loop
    c.actual_follow = (c.f and c.f[1] or false)
    c.step, c.done, c.action_lock = 1, false, 0
    c.e_prev = (c.e and c.e[1] or false)
    c.lastTarget, c.lastEngageTime = 0, 0
    c.lastDebuffTarget = 0
    c.hs_last, c.step_last, c.abs_last, c.deb_last = 0, 0, 0, 0
    c.buffs = {h=false, r=false, p=false, comp=false, pro=false, sh=false, hsamba=false}
    c.last_cast = {h=0, r=0, p=0, comp=0, pro=0, sh=0}
    c.target_buff_timers = {} -- Tracks specific buff attempts to bypass server packet lag
    c.engaged, c.in_zone, c.silenced = false, false, false
    c.pt_data = nil -- Will hold job/index info dynamically
end

for _, c in ipairs(chars) do init_char_state(c) end

------------------------------------------------------------
-- SCANNING LOGIC 
------------------------------------------------------------
local function update_membership_and_zones(party)
    if not party or not mm then return nil end
    local my_zone = party:GetMemberZone(0)
    local current_active = {}

    -- 1. Create a dictionary map of active party members (O(N) sweep)
    for i = 0, 5 do
        local name = party:GetMemberName(i)
        if name and name ~= "" then
            local zId = party:GetMemberZone(i)
            local sId = party:GetMemberServerId(i)
            local isActive = party:GetMemberIsActive(i)

            if sId ~= 0 and isActive ~= 0 and zId == my_zone then
                current_active[name:lower()] = { index = i, job = party:GetMemberMainJob(i), sId = sId }
            end
        end
    end

    -- 2. Update core chars and grab their dictionary data
    for _, c in ipairs(chars) do
        local was_in_zone = c.in_zone
        c.pt_data = current_active[c.name_lower]
        c.in_zone = (c.pt_data ~= nil)
        
        -- Box reset safety
        if was_in_zone and not c.in_zone then
            c.e[1], c.hs[1], c.bs[1], c.qs[1] = false, false, false, false
            c.abs[1], c.deb[1], c.buf[1] = false, false, false
            c.step, c.done = 1, false
        end
    end

    -- 3. Update/Clear guests
    for i = #guests, 1, -1 do
        local g = guests[i]
        g.pt_data = current_active[g.name_lower]
        if not g.pt_data then table.remove(guests, i)
        else g.in_zone = true end
    end

    -- 4. Add new guests 
    for name_l, data in pairs(current_active) do
        local is_known = false
        for _, core in ipairs(chars) do if core.name_lower == name_l then is_known = true break end end
        if not is_known then
            for _, gst in ipairs(guests) do if gst.name_lower == name_l then is_known = true break end end
        end

        if not is_known then
            local properName = party:GetMemberName(data.index)
            local g = { name = properName, buf = {false} }
            init_char_state(g)
            g.in_zone = true
            g.pt_data = data
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

local function scan_buffs(t, partyMgr)
    if not partyMgr or partyBuffsPtr == 0 then return end
    local myNameL = (partyMgr:GetMemberName(0) or ''):lower()

    for _, c in ipairs(t) do
        if not c.in_zone then goto continue end
        
        c.buffs.h, c.buffs.r, c.buffs.p, c.buffs.comp, c.buffs.pro, c.buffs.sh, c.buffs.hsamba = false, false, false, false, false, false, false
        
        if c.name_lower == myNameL then
            local icons = mm:GetPlayer():GetStatusIcons()
            for i = 1, 32 do
                local b = icons[i]
                if b <= 0 or b == 255 then break end
                parse_buff(b, c.buffs)
            end
        elseif c.pt_data then
            local sId = c.pt_data.sId
            for slot = 0, 4 do
                if partyMgr:GetStatusIconsServerId(slot) == sId then
                    local mPtr = partyBuffsPtr + (0x30 * slot)
                    for j = 0, 31 do
                        local low = ashita.memory.read_uint8(mPtr + 16 + j)
                        if low == 255 then break end
                        local high = ashita.memory.read_uint8(mPtr + 8 + math.floor(j / 4))
                        high = bit.lshift(bit.band(bit.rshift(high, (j % 4) * 2), 0x03), 8)
                        parse_buff(high + low, c.buffs)
                    end
                    break
                end
            end
        end
        ::continue::
    end
end

------------------------------------------------------------
-- ACTION HELPER
------------------------------------------------------------
local function do_action(c, cmd, lock_time, current_time)
    if c.f[1] and c.actual_follow ~= false then
        qcmd(string.format('/mst %s /ms follow off', c.name), true)
        c.actual_follow = false
    end
    qcmd(string.format('/mst %s %s', c.name, cmd))
    c.action_lock = current_time + lock_time
end

------------------------------------------------------------
-- LOGIC LOOP
------------------------------------------------------------
ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os.clock()
    if now - lastTick < TICK_INTERVAL then return end
    lastTick = now

    if not mm then return end
    local is_zoning = (mm:GetPlayer():GetIsZoning() ~= 0)
    
    if is_zoning and not is_zoning_prev then 
        guests = {} 
        for _, c in ipairs(chars) do
            c.e[1], c.hs[1], c.bs[1], c.qs[1] = false, false, false, false
            c.abs[1], c.deb[1], c.buf[1] = false, false, false
            c.step, c.done, c.in_zone, c.pt_data = 1, false, false, nil
            c.actual_follow = c.f[1]
            c.target_buff_timers = {} 
        end
    end
    is_zoning_prev = is_zoning
    
    local party = mm:GetParty()
    update_membership_and_zones(party)
    if is_zoning then return end
    
    scan_buffs(chars, party)
    scan_buffs(guests, party)

    local ent = mm:GetEntity()
    local targ = mm:GetTarget()
    local selfIdx = party:GetMemberTargetIndex(0)
    local mainEngaged = (selfIdx > 0 and ent:GetStatus(selfIdx) == 1)
    
    local engageTarget = 0
    local targetHPP = 100
    if selfIdx > 0 then
        local pt = targ:GetTargetIndex(targ:GetIsSubTargetActive())
        if pt > 0 then engageTarget = pt; targetHPP = ent:GetHPPercent(pt) end
    end

    local rdm = nil
    for _, c in ipairs(chars) do if c.name_lower == ROLES.rdm then rdm = c break end end

    if rdm and rdm.in_zone and now > rdm.action_lock then
        -- 1. BUFFING
        local buffTarget, targetJob = nil, 0
        
        local function evaluate_target(t)
            if t.buf[1] and t.in_zone and t.pt_data then
                local job = t.pt_data.job
                if (refresh_jobs[job] and not t.buffs.r) or not t.buffs.h or not t.buffs.p or not t.buffs.pro or not t.buffs.sh then
                    buffTarget, targetJob = t, job
                    return true
                end
            end
            return false
        end

        for _, t in ipairs(chars) do if evaluate_target(t) then break end end
        if not buffTarget then for _, t in ipairs(guests) do if evaluate_target(t) then break end end end

        if buffTarget then
            if not rdm.buffs.comp and (now - rdm.last_cast.comp > COMP_RETRY_DELAY) then
                do_action(rdm, '/ja "Composure" <me>', 1.5, now)
                rdm.last_cast.comp = now
            else
                local spell_to_cast = nil
                local target_name = buffTarget.name
                
                -- Check missing buffs & apply 8-second anti-spam timer to bypass packet delay
                if refresh_jobs[targetJob] and not buffTarget.buffs.r and (now - (rdm.target_buff_timers[target_name.. "Ref"] or 0) > 8.0) then 
                    spell_to_cast = "Refresh III"
                    rdm.target_buff_timers[target_name.. "Ref"] = now
                elseif not buffTarget.buffs.h and (now - (rdm.target_buff_timers[target_name.. "Has"] or 0) > 8.0) then 
                    spell_to_cast = "Haste II"
                    rdm.target_buff_timers[target_name.. "Has"] = now
                elseif not buffTarget.buffs.p and (now - (rdm.target_buff_timers[target_name.. "Pha"] or 0) > 8.0) then
                    spell_to_cast = (buffTarget.name_lower == ROLES.rdm) and 'Phalanx' or 'Phalanx II'
                    target_name = (buffTarget.name_lower == ROLES.rdm) and '<me>' or target_name
                    rdm.target_buff_timers[buffTarget.name.. "Pha"] = now
                elseif not buffTarget.buffs.pro and (now - (rdm.target_buff_timers[target_name.. "Pro"] or 0) > 8.0) then 
                    spell_to_cast = "Protect V"
                    rdm.target_buff_timers[target_name.. "Pro"] = now
                elseif not buffTarget.buffs.sh and (now - (rdm.target_buff_timers[target_name.. "She"] or 0) > 8.0) then 
                    spell_to_cast = "Shell V"
                    rdm.target_buff_timers[target_name.. "She"] = now
                end

                if spell_to_cast then
                    local dynamic_lock = get_cast_delay(spell_to_cast)
                    do_action(rdm, string.format('/ma "%s" %s', spell_to_cast, target_name), dynamic_lock, now)
                end
            end
            
        -- 2. DEBUFFING
        elseif rdm.deb[1] and mainEngaged and targetHPP >= 35 then
            if rdm.lastDebuffTarget ~= engageTarget then
                rdm.step = 1
                rdm.done = false
                rdm.silenced = false
                rdm.lastDebuffTarget = engageTarget
            end

            if not rdm.done then
                local tNameRaw = ent:GetName(engageTarget)
                if tNameRaw then
                    if rdm.cached_tNameRaw ~= tNameRaw then
                        rdm.cached_tNameRaw = tNameRaw
                        rdm.cached_tNameLower = tNameRaw:lower()
                    end
                    local tName = rdm.cached_tNameLower

                    if not rdm.silenced and silence_whitelist[tName] and rdm.step > 2 then
                        do_action(rdm, '/ma "Silence" [t]', get_cast_delay("Silence"), now)
                        rdm.silenced = true
                    else
                        local s = debuff_list[rdm.step]
                        if s then 
                            do_action(rdm, string.format('/ma "%s" [t]', s), get_cast_delay(s), now)
                            rdm.step = rdm.step + 1
                        else 
                            rdm.done = true 
                        end
                    end
                end
            end
        end
    end   

    -- BOX ACTIONS
    for _, c in ipairs(chars) do
        if c.name_lower ~= ROLES.main then
            local is_busy = (now <= c.action_lock)
            local desired_follow = c.f[1] and not is_busy
            
            if c.actual_follow ~= desired_follow then
                qcmd(string.format('/mst %s /ms follow %s', c.name, desired_follow and 'on' or 'off'), true)
                c.actual_follow = desired_follow
            end

            if c.in_zone and c.pt_data and now > c.action_lock then
                local pIdx = c.pt_data.index
                local mIdx = party:GetMemberTargetIndex(pIdx)
                c.engaged = (mIdx > 0 and ent:GetStatus(mIdx) == 1)
                
                if mainEngaged and c.e[1] then
                    if (c.lastTarget ~= engageTarget or not c.engaged) and (now - c.lastEngageTime > ENGAGE_RETRY_GAP) then
                        do_action(c, '/attack [t]', 1.2, now)
                        c.lastTarget, c.lastEngageTime = engageTarget, now
                    end
                elseif not mainEngaged and c.engaged then 
                    qcmd(string.format('/mst %s /attack off', c.name)) 
                end
                
                if c.engaged then
                    local tp = party:GetMemberTP(pIdx)
                    if c.abs[1] and now > c.abs_last + 45 then
                        do_action(c, '/ma "Absorb-TP" [t]', 2.0, now)
                        c.abs_last = now
                    elseif c.hs[1] and tp >= 350 and not c.buffs.hsamba and now > c.hs_last + 5 then
                        do_action(c, '/ja "Haste Samba" <me>', 1.8, now)
                        c.hs_last = now
                    elseif (c.bs[1] or c.qs[1]) and tp >= 100 and now > c.step_last + 12 then
                        do_action(c, string.format('/ja "%s" [t]', c.bs[1] and "Box Step" or "Quick Step"), 1.8, now)
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

ashita.events.register('d3d_present', 'render_ui', function ()
    if not show_ui then return end
    local now = os.clock()
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {2, 2}); imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {2, 2})
    if imgui.Begin('Sync', {true}, bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)) then
        if imgui.BeginTable('T', #ui_columns + 1, bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg)) then
            imgui.TableSetupColumn('Name', 0, 50)
            for _, col in ipairs(ui_columns) do imgui.TableSetupColumn(col.label, 0, 18) end
            imgui.TableHeadersRow()
            
            for i, c in ipairs(chars) do
                imgui.TableNextRow(); imgui.TableNextColumn()
                local is_main, is_rdm = (c.name_lower == ROLES.main), (c.name_lower == ROLES.rdm)
                
                if not c.in_zone then 
                    imgui.TextColored({1.0, 0.2, 0.2, 1.0}, c.disp_name)
                elseif now <= c.action_lock then
                    imgui.TextColored({1.0, 0.8, 0.0, 1.0}, c.disp_name) 
                else 
                    imgui.Text(c.disp_name) 
                end

                for _, col in ipairs(ui_columns) do
                    imgui.TableNextColumn()
                    local can_show = not (is_main and not col.allow_main) and not (col.rdm_only and not is_rdm)
                    if can_show then imgui.Checkbox('##'..col.label..i, c[col.key])
                    else imgui.TextDisabled("-") end
                end
            end

            for i, g in ipairs(guests) do
                imgui.TableNextRow(); imgui.TableNextColumn()
                imgui.TextColored({0.6, 0.9, 1.0, 1.0}, g.disp_name)
                for _, col in ipairs(ui_columns) do
                    imgui.TableNextColumn()
                    if col.key == 'buf' then imgui.Checkbox('##G'..col.label..i, g[col.key])
                    else imgui.TextDisabled("-") end
                end
            end
            imgui.EndTable()
        end
        imgui.End()
    end
    imgui.PopStyleVar(2)
end)

ashita.events.register('command', 'cmd_logic', function(e)
    local args = e.command:args()
    if #args > 0 and args[1]:lower() == '/sync' then show_ui = not show_ui; e.blocked = true end
end)

ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on', true)
    qcmd('/mso /ms follow on', true)
end)
