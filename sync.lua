addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '.04292'
addon.desc    = 'sync'

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- CONFIGURATION
------------------------------------------------------------
local show_ui = true
local silence_whitelist = { "Ahriman", "Crawler", "Fly", "Ghost", "Hecteyes", "Imp", "Shadow", "Skeleton" }
local refresh_jobs = { [3]=true, [4]=true, [5]=true, [7]=true, [8]=true, [15]=true, [16]=true, [21]=true, [22]=true } 

local chars = {
    { name='shaymin',  f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='muunch',   f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='slowpoke', f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='goomy',    f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
}

local guests = {}

------------------------------------------------------------
-- INTERNAL STATE & SAFETY
------------------------------------------------------------
local TICK_INTERVAL    = 0.4 
local ENGAGE_RETRY_GAP = 0.5
local CAST_LOCK_TIME   = 3.8 
local COMP_RETRY_DELAY = 300
local lastTick         = 0
local is_zoning_prev   = false

local debuff_list      = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Slow II", "Paralyze II" }

local mm = AshitaCore:GetMemoryManager()

-- Safety: Selective bypass for Follow commands while zoning
local qcmd = function(cmd, isFollow) 
    if not isFollow and mm:GetPlayer():GetIsZoning() ~= 0 then return end
    AshitaCore:GetChatManager():QueueCommand(1, cmd) 
end

local partyBuffsPtr = AshitaCore:GetPointerManager():Get('party.statusicons')
partyBuffsPtr = ashita.memory.read_uint32(partyBuffsPtr)

local function init_char_state(c)
    c.f_prev, c.step, c.done, c.action_lock = (c.f and c.f[1] or false), 1, false, 0
    c.e_prev = (c.e and c.e[1] or false)
    c.lastTarget, c.lastEngageTime = 0, 0
    c.hs_last, c.step_last, c.abs_last, c.deb_last = 0, 0, 0, 0
    c.buffs = {h=false, r=false, p=false, comp=false, pro=false, sh=false, hsamba=false}
    c.last_cast = {h=0, r=0, p=0, comp=0, pro=0, sh=0}
    c.engaged, c.in_zone = false, false
end

for _, c in ipairs(chars) do init_char_state(c) end

local function is_in_list(val, list)
    for _, v in ipairs(list) do if v == val then return true end end
    return false
end

------------------------------------------------------------
-- SCANNING LOGIC 
------------------------------------------------------------
local function update_membership_and_zones(party)
    if not party or not mm then return end
    local my_zone = party:GetMemberZone(0)
    local entMgr = mm:GetEntity()
    local current_names = {}

    for i = 0, 5 do
        local name = party:GetMemberName(i)
        local tIdx = party:GetMemberTargetIndex(i)
        local sId = party:GetMemberServerId(i)
        local zId = party:GetMemberZone(i)

        if name and name ~= "" and sId ~= 0 and tIdx > 0 and tIdx < 2048 then
            local entName = entMgr:GetName(tIdx)
            if entName and entName ~= "" and zId == my_zone then
                current_names[name:lower()] = true
            end
        end
    end

    for _, c in ipairs(chars) do
        c.in_zone = current_names[c.name:lower()] == true
    end

    for i = #guests, 1, -1 do
        if not current_names[guests[i].name:lower()] then
            table.remove(guests, i)
        end
    end

    for name, _ in pairs(current_names) do
        local name_l = name:lower()
        local is_core = false
        for _, core in ipairs(chars) do 
            if core.name:lower() == name_l then is_core = true break end 
        end
        
        local is_known = false
        for _, gst in ipairs(guests) do 
            if gst.name:lower() == name_l then is_known = true break end 
        end

        if not is_core and not is_known then
            local g = { name = name, buf = {false}, in_zone = true }
            init_char_state(g)
            table.insert(guests, g)
        end
    end
end

local function scan_buffs(t, partyMgr)
    if not partyMgr or partyBuffsPtr == 0 then return end
    
    for _, c in ipairs(t) do
        local h, r, p, comp, pro, sh, hsamba = false, false, false, false, false, false, false
        
        if c.name:lower() == (partyMgr:GetMemberName(0) or ''):lower() then
            local icons = mm:GetPlayer():GetStatusIcons()
            for i = 1, 32 do
                local b = icons[i]
                if b <= 0 or b == 255 then break end
                if b == 33 then h = true elseif b == 43 then r = true elseif b == 116 then p = true 
                elseif b == 419 then comp = true elseif b == 40 then pro = true elseif b == 41 then sh = true
                elseif b == 370 then hsamba = true end
            end
        else
            for i = 1, 5 do
                if (partyMgr:GetMemberName(i) or ''):lower() == c.name:lower() then
                    local sId = partyMgr:GetMemberServerId(i)
                    for slot = 0, 4 do
                        if partyMgr:GetStatusIconsServerId(slot) == sId then
                            local mPtr = partyBuffsPtr + (0x30 * slot)
                            for j = 0, 31 do
                                local low = ashita.memory.read_uint8(mPtr + 16 + j)
                                if low == 255 then break end
                                local high = ashita.memory.read_uint8(mPtr + 8 + math.floor(j / 4))
                                high = bit.lshift(bit.band(bit.rshift(high, (j % 4) * 2), 0x03), 8)
                                local b = high + low
                                if b == 33 then h = true elseif b == 43 then r = true elseif b == 116 then p = true 
                                elseif b == 419 then comp = true elseif b == 40 then pro = true elseif b == 41 then sh = true
                                elseif b == 370 then hsamba = true end
                            end
                            break
                        end
                    end
                    break
                end
            end
        end
        c.buffs.h, c.buffs.r, c.buffs.p, c.buffs.comp, c.buffs.pro, c.buffs.sh, c.buffs.hsamba = h, r, p, comp, pro, sh, hsamba
    end
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
        for _, c in ipairs(chars) do
            c.e[1] = false; c.hs[1] = false; c.bs[1] = false; c.qs[1] = false
            c.abs[1] = false; c.deb[1] = false; c.buf[1] = false
            c.step, c.done = 1, false
            c.in_zone = false
        end
    end
    is_zoning_prev = is_zoning
    
    local party = mm:GetParty()
    update_membership_and_zones(party)
    
    -- We allow scanning and follow commands even if is_zoning is true,
    -- but combat/rdm logic is skipped.
    if is_zoning then 
        for _, c in ipairs(chars) do
            if c.name:lower() ~= 'shaymin' then
                if c.f_prev == false and c.f[1] == true then qcmd(string.format('/mst %s /ms follow on', c.name), true)
                elseif c.f_prev == true and c.f[1] == false then qcmd(string.format('/mst %s /ms follow off', c.name), true) end
                c.f_prev = c.f[1]
            end
        end
        return 
    end
    
    scan_buffs(chars, party)
    scan_buffs(guests, party)

    local ent     = mm:GetEntity()
    local targ    = mm:GetTarget()
    local selfIdx = party:GetMemberTargetIndex(0)
    local mainEngaged = (selfIdx > 0 and ent:GetStatus(selfIdx) == 1)
    
    local engageTarget = 0
    local targetHPP = 100
    if selfIdx > 0 then
        local pt = targ:GetTargetIndex(targ:GetIsSubTargetActive())
        if pt > 0 then engageTarget = pt; targetHPP = ent:GetHPPercent(pt)
        else
            local tot = ent:GetTargetedIndex(pt)
            if tot > 0 then engageTarget = tot end
        end
    end

    ------------------------------------------------------------
    -- CONSOLIDATED RDM PROCESSING (IN-ZONE ONLY)
    ------------------------------------------------------------
    local rdm = nil
    for _, c in ipairs(chars) do
        if c.name:lower() == 'goomy' then rdm = c break end
    end

    if rdm and rdm.in_zone and now > rdm.action_lock then
        local buffTarget = nil
        local targetJob = 0
        local all_targets = {}
        for _, c in ipairs(chars) do table.insert(all_targets, c) end
        for _, g in ipairs(guests) do table.insert(all_targets, g) end

        for _, t in ipairs(all_targets) do
            if t.buf[1] and t.in_zone then
                local pIdx = -1
                for x=0,5 do if (party:GetMemberName(x) or ''):lower() == t.name:lower() then pIdx = x break end end
                local job = (pIdx ~= -1) and party:GetMemberMainJob(pIdx) or 0
                if (refresh_jobs[job] and not t.buffs.r) or not t.buffs.h or not t.buffs.p or not t.buffs.pro or not t.buffs.sh then
                    buffTarget = t; targetJob = job; break
                end
            end
        end

        if buffTarget then
            if not rdm.buffs.comp and (now - rdm.last_cast.comp > COMP_RETRY_DELAY) then
                qcmd('/mst goomy /ja "Composure" <me>'); rdm.last_cast.comp = now; rdm.action_lock = now + 1.5
            else
                if refresh_jobs[targetJob] and not buffTarget.buffs.r then qcmd(string.format('/mst goomy /ma "Refresh III" %s', buffTarget.name))
                elseif not buffTarget.buffs.h then qcmd(string.format('/mst goomy /ma "Haste II" %s', buffTarget.name))
                elseif not buffTarget.buffs.p then
                    local s = (buffTarget.name:lower() == 'goomy') and 'Phalanx' or 'Phalanx II'
                    local tg = (buffTarget.name:lower() == 'goomy') and '<me>' or buffTarget.name
                    qcmd(string.format('/mst goomy /ma "%s" %s', s, tg))
                elseif not buffTarget.buffs.pro then qcmd(string.format('/mst goomy /ma "Protect V" %s', buffTarget.name))
                elseif not buffTarget.buffs.sh then qcmd(string.format('/mst goomy /ma "Shell V" %s', buffTarget.name))
                end
                rdm.action_lock = now + CAST_LOCK_TIME
            end
        elseif rdm.deb[1] and not rdm.done and mainEngaged then
            if targetHPP < 35 then rdm.done = true 
            else
                local targetName = ent:GetName(engageTarget) or ""
                if not rdm.silenced and is_in_list(targetName, silence_whitelist) and rdm.step > 2 then
                    qcmd('/mst goomy /ma "Silence" [t]'); rdm.silenced = true; rdm.action_lock = now + CAST_LOCK_TIME
                else
                    local s = debuff_list[rdm.step]
                    if s then qcmd(string.format('/mst goomy /ma "%s" [t]', s)); rdm.step = rdm.step + 1; rdm.action_lock = now + CAST_LOCK_TIME
                    else rdm.done = true end
                end
            end
        end
    end

    ------------------------------------------------------------
    -- CHARACTER ACTIONS (FOLLOW / ATTACK / JA)
    ------------------------------------------------------------
    for _, c in ipairs(chars) do
        if c.name:lower() ~= 'shaymin' then
            -- Follow commands bypass zoning checks
            if c.f_prev == false and c.f[1] == true then qcmd(string.format('/mst %s /ms follow on', c.name), true)
            elseif c.f_prev == true and c.f[1] == false then qcmd(string.format('/mst %s /ms follow off', c.name), true) end
            c.f_prev = c.f[1]

            -- Combat logic requires character to be in-zone
            if c.in_zone then
                local pIdx = -1
                for x=0,5 do if (party:GetMemberName(x) or ''):lower() == c.name:lower() then pIdx = x break end end
                
                if pIdx ~= -1 and now > c.action_lock then
                    local mIdx = party:GetMemberTargetIndex(pIdx)
                    c.engaged = (mIdx > 0 and ent:GetStatus(mIdx) == 1)

                    if mainEngaged and c.e[1] then
                        if (c.lastTarget ~= engageTarget or not c.engaged) and (now - c.lastEngageTime > ENGAGE_RETRY_GAP) then
                            qcmd(string.format('/mst %s /attack [t]', c.name))
                            c.lastTarget = engageTarget; c.lastEngageTime = now; c.action_lock = now + 1.2; return 
                        end
                    elseif not mainEngaged and c.engaged then
                        qcmd(string.format('/mst %s /attack off', c.name))
                    end

                    if c.lastTarget ~= engageTarget then c.step, c.done, c.lastTarget = 1, false, engageTarget end

                    if c.engaged then
                        local tp = party:GetMemberTP(pIdx)
                        if c.abs[1] and now > c.abs_last + 45 then
                            qcmd(string.format('/mst %s /ma "Absorb-TP" [t]', c.name)); c.abs_last = now; c.action_lock = now + 2.0
                        elseif c.hs[1] and tp >= 350 and not c.buffs.hsamba and now > c.hs_last + 5 then
                            qcmd(string.format('/mst %s /ja "Haste Samba" <me>', c.name)); c.hs_last = now; c.action_lock = now + 1.8
                        elseif (c.bs[1] or c.qs[1]) and tp >= 100 and now > c.step_last + 12 then
                            local ja = c.bs[1] and "Box Step" or "Quick Step"
                            qcmd(string.format('/mst %s /ja "%s" [t]', c.name, ja)); c.step_last = now; c.action_lock = now + 1.8
                        end
                    end
                end
            end
        end
    end
end)

------------------------------------------------------------
-- UI & EVENTS
------------------------------------------------------------
ashita.events.register('d3d_present', 'render_ui', function ()
    if not show_ui then return end
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {2, 2}); imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {2, 2})
    if imgui.Begin('Sync', {true}, bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)) then
        if imgui.BeginTable('T', 9, bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg)) then
            imgui.TableSetupColumn('Name', 0, 50); imgui.TableSetupColumn('F', 0, 18); imgui.TableSetupColumn('E', 0, 18)
            imgui.TableSetupColumn('HS', 0, 18); imgui.TableSetupColumn('BS', 0, 18); imgui.TableSetupColumn('QS', 0, 18)
            imgui.TableSetupColumn('Ab', 0, 18); imgui.TableSetupColumn('De', 0, 18); imgui.TableSetupColumn('Bu', 0, 18)
            imgui.TableHeadersRow()
            
            for i, c in ipairs(chars) do
                imgui.TableNextRow(); imgui.TableNextColumn()
                if not c.in_zone then imgui.TextColored({1.0, 0.2, 0.2, 1.0}, c.name:sub(1,5):upper())
                else imgui.Text(c.name:sub(1,5):upper()) end
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##F'..i, c.f) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##E'..i, c.e) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##H'..i, c.hs) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##BS'..i, c.bs) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##Q'..i, c.qs) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##A'..i, c.abs) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if c.name == 'goomy' then imgui.Checkbox('##D'..i, c.deb) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); imgui.Checkbox('##U'..i, c.buf)
            end
            imgui.EndTable()
        end
        imgui.End()
    end
    imgui.PopStyleVar(2)
end)

ashita.events.register('command', 'cmd_logic', function(e)
    local args = e.command:args()
    if #args > 0 and args[1] and args[1]:lower() == '/sync' then show_ui = not show_ui; e.blocked = true end
end)

ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on', true); qcmd('/mso /ms follow on', true)
end)
