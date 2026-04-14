addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '.032' 

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

local chars = {
    { name='shaymin',  f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='muunch',   f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='slowpoke', f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='goomy',    f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
}

------------------------------------------------------------
-- Internal State
------------------------------------------------------------
local TICK_INTERVAL    = 0.4 
local lastTick         = 0
local CAST_LOCK_TIME   = 4.2 
local COMP_RETRY_DELAY = 300 
local debuff_list      = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Slow II", "Paralyze II" }

local partyBuffsPtr = AshitaCore:GetPointerManager():Get('party.statusicons')
partyBuffsPtr = ashita.memory.read_uint32(partyBuffsPtr)

for _, c in ipairs(chars) do
    c.f_prev, c.step, c.done, c.action_lock = c.f[1], 1, false, 0
    c.e_prev = c.e[1] -- Watcher for Attack Off logic
    c.hs_last, c.step_last, c.abs_last, c.deb_last = 0, 0, 0, 0
    c.buffs = {h=false, r=false, p=false, comp=false, pro=false, sh=false}
    c.last_cast = {h=0, r=0, p=0, comp=0, pro=0, sh=0}
end

local mm = AshitaCore:GetMemoryManager()
local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

------------------------------------------------------------
-- UTILS
------------------------------------------------------------
local function is_in_list(val, list)
    for _, v in ipairs(list) do if v:lower() == val:lower() then return true end end
    return false
end

local function scan_party_buffs()
    local partyMgr = mm:GetParty()
    if partyBuffsPtr == 0 then return end

    for _, c in ipairs(chars) do
        local h, r, p, comp, pro, sh = false, false, false, false, false, false
        if c.name:lower() == (partyMgr:GetMemberName(0) or ''):lower() then
            local icons = mm:GetPlayer():GetStatusIcons()
            for i = 1, 32 do
                local b = icons[i]
                if b <= 0 or b == 255 then break end
                if b == 33 then h = true elseif b == 43 then r = true elseif b == 116 then p = true 
                elseif b == 419 then comp = true elseif b == 40 then pro = true elseif b == 41 then sh = true end
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
                                elseif b == 419 then comp = true elseif b == 40 then pro = true elseif b == 41 then sh = true end
                            end
                            break
                        end
                    end
                    break
                end
            end
        end
        c.buffs.h, c.buffs.r, c.buffs.p, c.buffs.comp, c.buffs.pro, c.buffs.sh = h, r, p, comp, pro, sh
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
    scan_party_buffs()

    local party = mm:GetParty()
    local ent = mm:GetEntity()
    local leaderTIdx = party:GetMemberTargetIndex(0)
    local mainEngaged = (leaderTIdx ~= 0 and ent:GetStatus(leaderTIdx) == 1)
    
    -- STATE WATCHER (Attack Off / Follow Toggle)
    for _, c in ipairs(chars) do
        if c.name:lower() ~= 'shaymin' then
            -- Engage Watcher
            if c.e_prev == true and c.e[1] == false then
                qcmd(string.format('/mst %s /attack off', c.name))
            end
            c.e_prev = c.e[1]
            
            -- Follow Watcher
            if c.f_prev == false and c.f[1] == true then
                qcmd(string.format('/mst %s /ms follow on', c.name))
            elseif c.f_prev == true and c.f[1] == false then
                qcmd(string.format('/mst %s /ms follow off', c.name))
            end
            c.f_prev = c.f[1]
        end
    end

    -- GOOMY (RDM) BUFFING
    local goomy = chars[4]
    if goomy and now > goomy.action_lock then
        local buffTarget = nil
        local targetJob = 0

        for _, c in ipairs(chars) do
            if c.buf[1] then
                local pIdx = -1
                for x=0,5 do if (party:GetMemberName(x) or ''):lower() == c.name:lower() then pIdx = x break end end
                local mJob = (pIdx ~= -1) and party:GetMemberMainJob(pIdx) or 0
                
                local needs_r = (refresh_jobs[mJob] and not c.buffs.r)
                if needs_r or not c.buffs.h or not c.buffs.p or not c.buffs.pro or not c.buffs.sh then
                    buffTarget = c; targetJob = mJob; break
                end
            end
        end

        if buffTarget then
            if not goomy.buffs.comp and (now - goomy.last_cast.comp > COMP_RETRY_DELAY) then
                qcmd('/mst goomy /ja "Composure" <me>')
                goomy.last_cast.comp = now; goomy.action_lock = now + 1.5; return
            end

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
            goomy.action_lock = now + CAST_LOCK_TIME; return
        end
    end

    -- COMBAT JAs & DEBUFFS
    if mainEngaged then
        local targetName = ent:GetName(leaderTIdx) or ""
        for i, c in ipairs(chars) do
            if c.name:lower() ~= 'shaymin' and now > c.action_lock then
                if c.e[1] then qcmd(string.format('/mst %s /attack on', c.name)) end
                
                local pIdx = -1
                for x=0,5 do if (party:GetMemberName(x) or ''):lower() == c.name:lower() then pIdx = x break end end
                
                if pIdx ~= -1 then
                    local tp = party:GetMemberTP(pIdx)
                    if c.name:lower() == 'goomy' and c.deb[1] and not c.done then
                        local s = debuff_list[c.step]
                        if s then
                            qcmd(string.format('/mst goomy /ma "%s" <t>', s))
                            c.step = c.step + 1; c.action_lock = now + CAST_LOCK_TIME; return
                        elseif is_in_list(targetName, silence_whitelist) and c.step == (#debuff_list + 1) then
                            qcmd('/mst goomy /ma "Silence" <t>')
                            c.step = c.step + 1; c.action_lock = now + CAST_LOCK_TIME; return
                        else c.done = true end
                    end

                    if c.abs[1] and now > c.abs_last + 45 then
                        qcmd(string.format('/mst %s /ma "Absorb-TP" <t>', c.name)); c.abs_last = now; c.action_lock = now + 2.0
                    elseif c.hs[1] and tp >= 350 and now > c.hs_last + 90 then
                        qcmd(string.format('/mst %s /ja "Haste Samba" <me>', c.name)); c.hs_last = now; c.action_lock = now + 2.0
                    elseif (c.bs[1] or c.qs[1]) and tp >= 100 and now > c.step_last + 12 then
                        local ja = c.bs[1] and "Box Step" or "Quick Step"
                        qcmd(string.format('/mst %s /ja "%s" <t>', c.name, ja)); c.step_last = now; c.action_lock = now + 2.0
                    end
                end
            end
        end
    else
        for _, c in ipairs(chars) do c.step = 1; c.done = false end
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
            imgui.EndTable()
        end
        imgui.End()
    end
    imgui.PopStyleVar(2)
end)

ashita.events.register('command', 'cmd_logic', function(e)
    if e.command:args()[1]:lower() == '/sync' then show_ui = not show_ui; e.blocked = true end
end)

ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on')
    qcmd('/mso /ms follow on')
end)
