addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '.0415'
addon.desc    = 'Target-of-Target Sync with Guest Detection & Input Safety'

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- CONFIGURATION
------------------------------------------------------------
local show_ui = true
local silence_whitelist = { "Ahriman", "Crawler", "Fly", "Ghost", "Hecteyes", "Imp", "Shadow", "Skeleton" }

local refresh_jobs = { 
    [3]=true, [4]=true, [5]=true, [7]=true, [8]=true, 
    [15]=true, [16]=true, [21]=true, [22]=true 
} 

-- Core 4 Table
local chars = {
    { name='shaymin',  f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='muunch',   f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='slowpoke', f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='goomy',    f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
}

-- Dynamic Guest Table
local guests = {}

------------------------------------------------------------
-- INTERNAL STATE
------------------------------------------------------------
local TICK_INTERVAL    = 0.4 
local ENGAGE_RETRY_GAP = 0.5
local CAST_LOCK_TIME   = 3.8 
local COMP_RETRY_DELAY = 300 
local lastTick         = 0

local debuff_list      = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Slow II", "Paralyze II" }

local partyBuffsPtr = AshitaCore:GetPointerManager():Get('party.statusicons')
partyBuffsPtr = ashita.memory.read_uint32(partyBuffsPtr)

local function init_char_state(c)
    c.f_prev, c.step, c.done, c.action_lock = (c.f and c.f[1] or false), 1, false, 0
    c.e_prev = (c.e and c.e[1] or false)
    c.lastTarget = 0
    c.lastEngageTime = 0
    c.hs_last, c.step_last, c.abs_last, c.deb_last = 0, 0, 0, 0
    c.buffs = {h=false, r=false, p=false, comp=false, pro=false, sh=false, hsamba=false}
    c.last_cast = {h=0, r=0, p=0, comp=0, pro=0, sh=0}
    c.silenced = false
    c.engaged = false
end

for _, c in ipairs(chars) do init_char_state(c) end

local mm = AshitaCore:GetMemoryManager()
local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

------------------------------------------------------------
-- UTILS
------------------------------------------------------------
local function is_in_list(val, list)
    if not val then return false end
    for _, v in ipairs(list) do if v:lower() == val:lower() then return true end end
    return false
end

local function scan_buffs_for_table(t, partyMgr)
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
            local sId = -1
            for i = 1, 5 do
                if (partyMgr:GetMemberName(i) or ''):lower() == c.name:lower() then
                    sId = partyMgr:GetMemberServerId(i)
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
-- GUEST WATCHER
------------------------------------------------------------
local function update_guests(partyMgr)
    if not partyMgr then return end
    local current_party = {}
    for i = 0, 5 do
        local name = partyMgr:GetMemberName(i)
        if name and name ~= "" then current_party[name:lower()] = true end
    end

    -- Remove guests who left
    for i = #guests, 1, -1 do
        if not current_party[guests[i].name:lower()] then table.remove(guests, i) end
    end

    -- Add new guests
    for name, _ in pairs(current_party) do
        local is_core = false
        for _, core in ipairs(chars) do if core.name:lower() == name then is_core = true break end end
        
        local is_known_guest = false
        for _, gst in ipairs(guests) do if gst.name:lower() == name then is_known_guest = true break end end

        if not is_core and not is_known_guest then
            local new_guest = { name = name, buf = {false} }
            init_char_state(new_guest)
            table.insert(guests, new_guest)
        end
    end
end

------------------------------------------------------------
-- MAIN LOGIC
------------------------------------------------------------
ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os.clock()
    if now - lastTick < TICK_INTERVAL then return end
    lastTick = now

    if not mm or mm:GetPlayer():GetIsZoning() ~= 0 then return end
    
    local party = mm:GetParty()
    update_guests(party)
    scan_buffs_for_table(chars, party)
    scan_buffs_for_table(guests, party)

    local ent   = mm:GetEntity()
    local targ  = mm:GetTarget()
    
    local selfIdx = party:GetMemberTargetIndex(0)
    local playerEngaged = (selfIdx > 0 and ent:GetStatus(selfIdx) == 1)
    
    local playerTarget = 0
    local playerTargetOfTarget = 0
    local targetHPP = 100

    if selfIdx > 0 then
        local isSub = targ:GetIsSubTargetActive()
        playerTarget = targ:GetTargetIndex(isSub)
        if playerTarget > 0 then
            targetHPP = ent:GetHPPercent(playerTarget)
            local tot = ent:GetTargetedIndex(playerTarget)
            if tot > 0 then playerTargetOfTarget = tot end
        end
    end

    local engageTarget = playerTarget
    if engageTarget == 0 and playerTargetOfTarget > 0 then
        engageTarget = playerTargetOfTarget
    end
    
    -- State Watcher for Core 4
    for _, c in ipairs(chars) do
        if c.name:lower() ~= 'shaymin' then
            if c.e_prev == true and c.e[1] == false then qcmd(string.format('/mst %s /attack off', c.name)) end
            c.e_prev = c.e[1]
            if c.f_prev == false and c.f[1] == true then qcmd(string.format('/mst %s /ms follow on', c.name))
            elseif c.f_prev == true and c.f[1] == false then qcmd(string.format('/mst %s /ms follow off', c.name)) end
            c.f_prev = c.f[1]

            local pIdx = -1
            for x=0,5 do if (party:GetMemberName(x) or ''):lower() == c.name:lower() then pIdx = x break end end
            if pIdx ~= -1 then
                local mIdx = party:GetMemberTargetIndex(pIdx)
                c.engaged = (mIdx > 0 and ent:GetStatus(mIdx) == 1)
            end
        end
    end

    ------------------------------------------------------------
    -- GOOMY (RDM) BUFFING
    ------------------------------------------------------------
    local goomy = chars[4]
    if goomy and now > goomy.action_lock then
        local buffTarget = nil
        local targetJob = 0

        -- Priority 1: Mules
        for _, c in ipairs(chars) do
            if c.buf[1] then
                local pIdx = -1
                for x=0,5 do if (party:GetMemberName(x) or ''):lower() == c.name:lower() then pIdx = x break end end
                local mJob = (pIdx ~= -1) and party:GetMemberMainJob(pIdx) or 0
                if (refresh_jobs[mJob] and not c.buffs.r) or not c.buffs.h or not c.buffs.p or not c.buffs.pro or not c.buffs.sh then
                    buffTarget = c; targetJob = mJob; break
                end
            end
        end

        -- Priority 2: Guests
        if not buffTarget then
            for _, g in ipairs(guests) do
                if g.buf[1] then
                    local pIdx = -1
                    for x=0,5 do if (party:GetMemberName(x) or ''):lower() == g.name:lower() then pIdx = x break end end
                    local gJob = (pIdx ~= -1) and party:GetMemberMainJob(pIdx) or 0
                    if (refresh_jobs[gJob] and not g.buffs.r) or not g.buffs.h or not g.buffs.p or not g.buffs.pro or not g.buffs.sh then
                        buffTarget = g; targetJob = gJob; break
                    end
                end
            end
        end

        if buffTarget then
            if not goomy.buffs.comp and (now - goomy.last_cast.comp > COMP_RETRY_DELAY) then
                qcmd('/mst goomy /ja "Composure" <me>')
                goomy.last_cast.comp = now; goomy.action_lock = now + 1.5
            else
                if refresh_jobs[targetJob] and not buffTarget.buffs.r then
                    qcmd(string.format('/mst goomy /ma "Refresh III" %s', buffTarget.name))
                elseif not buffTarget.buffs.h then
                    qcmd(string.format('/mst goomy /ma "Haste II" %s', buffTarget.name))
                elseif not buffTarget.buffs.p then
                    local s = (buffTarget.name:lower() == 'goomy') and 'Phalanx' or 'Phalanx II'
                    local t = (buffTarget.name:lower() == 'goomy') and '<me>' or buffTarget.name
                    qcmd(string.format('/mst goomy /ma "%s" %s', s, t))
                elseif not buffTarget.buffs.pro then
                    qcmd(string.format('/mst goomy /ma "Protect V" %s', buffTarget.name))
                elseif not buffTarget.buffs.sh then
                    qcmd(string.format('/mst goomy /ma "Shell V" %s', buffTarget.name))
                end
                goomy.action_lock = now + CAST_LOCK_TIME
            end
        end
    end

    ------------------------------------------------------------
    -- COMBAT LOGIC
    ------------------------------------------------------------
    if playerEngaged then
        local targetName = ent:GetName(engageTarget) or ""
        for i, c in ipairs(chars) do
            if c.name:lower() ~= 'shaymin' and now > c.action_lock then
                if c.e[1] then 
                    local timeSince = now - c.lastEngageTime
                    if (c.lastTarget ~= engageTarget or not c.engaged) and timeSince >= ENGAGE_RETRY_GAP then
                        qcmd(string.format('/mst %s /attack [t]', c.name))
                        c.lastTarget = engageTarget; c.lastEngageTime = now; c.action_lock = now + 1.0 
                    end
                end

                if c.lastTarget ~= engageTarget then c.step = 1; c.done = false; c.silenced = false; c.lastTarget = engageTarget end
                
                local pIdx = -1
                for x=0,5 do if (party:GetMemberName(x) or ''):lower() == c.name:lower() then pIdx = x break end end
                
                if pIdx ~= -1 then
                    if c.name:lower() == 'goomy' and c.deb[1] and not c.done then
                        if targetHPP < 50 then c.done = true
                        else
                            if not c.silenced and is_in_list(targetName, silence_whitelist) and c.step > 2 then
                                qcmd('/mst goomy /ma "Silence" [t]')
                                c.silenced = true; c.action_lock = now + CAST_LOCK_TIME
                            else
                                local s = debuff_list[c.step]
                                if s then qcmd(string.format('/mst goomy /ma "%s" [t]', s)); c.step = c.step + 1; c.action_lock = now + CAST_LOCK_TIME
                                else c.done = true end
                            end
                        end
                    end

                    if c.engaged then
                        local tp = party:GetMemberTP(pIdx)
                        if c.abs[1] and now > c.abs_last + 45 then
                            qcmd(string.format('/mst %s /ma "Absorb-TP" [t]', c.name)); c.abs_last = now; c.action_lock = now + 2.0
                        elseif c.hs[1] and tp >= 350 and not c.buffs.hsamba and now > c.hs_last + 5 then
                            qcmd(string.format('/mst %s /ja "Haste Samba" <me>', c.name)); c.hs_last = now; c.action_lock = now + 2.0
                        elseif (c.bs[1] or c.qs[1]) and tp >= 100 and now > c.step_last + 12 then
                            local ja = c.bs[1] and "Box Step" or "Quick Step"
                            qcmd(string.format('/mst %s /ja "%s" [t]', c.name, ja)); c.step_last = now; c.action_lock = now + 2.0
                        end
                    end
                end
            end
        end
    else
        for _, c in ipairs(chars) do 
            if c.engaged and c.e[1] and c.name:lower() ~= 'shaymin' then qcmd(string.format('/mst %s /attack off', c.name)) end
            c.step = 1; c.done = false; c.silenced = false; c.lastTarget = 0
        end
    end
end)

------------------------------------------------------------
-- UI & COMMANDS
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
                imgui.TableNextRow(); imgui.TableNextColumn(); imgui.Text(c.name:sub(1,5):upper())
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##F'..i, c.f) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##E'..i, c.e) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##H'..i, c.hs) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##BS'..i, c.bs) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##Q'..i, c.qs) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if i ~= 1 then imgui.Checkbox('##A'..i, c.abs) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); if c.name == 'goomy' then imgui.Checkbox('##D'..i, c.deb) else imgui.TextDisabled("-") end
                imgui.TableNextColumn(); imgui.Checkbox('##U'..i, c.buf)
            end

            for i, g in ipairs(guests) do
                imgui.TableNextRow(); imgui.TableNextColumn(); imgui.TextColored({0.4, 0.8, 1.0, 1.0}, g.name:sub(1,5):upper())
                imgui.TableNextColumn(); imgui.TextDisabled("-"); imgui.TableNextColumn(); imgui.TextDisabled("-")
                imgui.TableNextColumn(); imgui.TextDisabled("-"); imgui.TableNextColumn(); imgui.TextDisabled("-")
                imgui.TableNextColumn(); imgui.TextDisabled("-"); imgui.TableNextColumn(); imgui.TextDisabled("-")
                imgui.TableNextColumn(); imgui.TextDisabled("-"); imgui.TableNextColumn(); imgui.Checkbox('##GU'..i, g.buf)
            end
            imgui.EndTable()
        end
        imgui.End()
    end
    imgui.PopStyleVar(2)
end)

ashita.events.register('command', 'cmd_logic', function(e)
    local args = e.command:args()
    if #args > 0 and args[1] and args[1]:lower() == '/sync' then 
        show_ui = not show_ui
        e.blocked = true 
    end
end)

ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on')
    qcmd('/mso /ms follow on')
end)
