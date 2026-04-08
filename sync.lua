addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '0.3' 

require('common')
local imgui = require('imgui')

-- Logic Constants
local HS_TP_THRESHOLD   = 350
local HS_COOLDOWN       = 85
local STEP_TP_THRESHOLD = 100
local STEP_COOLDOWN     = 10
local ABS_COOLDOWN      = 15 
local TICK_INTERVAL     = 0.3 
local lastTick          = 0

local ui_show = { true }
local debuff_list = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Slow II", "Paralyze II" }
local spell_mp    = { ["Dia III"]=45, ["Frazzle III"]=90, ["Distract III"]=84, ["Blind II"]=31, ["Slow II"]=45, ["Paralyze II"]=36, ["Absorb-TP"]=33 }

local chars = {
    { name='',   f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0, hs_last=0, bs_last=0, qs_last=0, last_f_state=nil, deb_last=0, last_target_id=0, casting=false, cast_start=0, disengage_sent=0 },
    { name='', f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0, hs_last=0, bs_last=0, qs_last=0, last_f_state=nil, deb_last=0, last_target_id=0, casting=false, cast_start=0, disengage_sent=0 },
    { name='',    f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0, hs_last=0, bs_last=0, qs_last=0, last_f_state=nil, deb_last=0, last_target_id=0, casting=false, cast_start=0, disengage_sent=0 },
}

local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

------------------------------------------------------------
-- Event: Packet Handling
------------------------------------------------------------
ashita.events.register('packet_in', 'packet_logic', function (e)
    if (e.id == 0x28) then
        local mm = AshitaCore:GetMemoryManager(); local ent = mm and mm:GetEntity()
        if not ent then return end

        local userId   = ashita.bits.unpack_be(e.data_raw, 0, 40, 32)
        local category = ashita.bits.unpack_be(e.data_raw, 0, 82, 4)
        local actorId  = bit.band(userId, 0x7FF); local actorName = ent:GetName(actorId)
        
        if not actorName then return end

        for _, c in ipairs(chars) do
            if actorName:lower() == c.name:lower() then
                if category == 4 or category == 6 or category == 14 then 
                    if c.casting then
                        c.casting = false
                        if c.deb[1] and not c.abs[1] then
                            c.step = c.step + 1
                            if c.step > #debuff_list then c.done = true end
                        end
                        c.timer = os.clock() + 0.8
                    end
                elseif category == 8 or category == 12 then 
                    c.casting = false; c.timer = os.clock() + 1.5 
                end
            end
        end
    end
end)

------------------------------------------------------------
-- Event: Main Logic Loop
------------------------------------------------------------
ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os.clock()
    if now - lastTick < TICK_INTERVAL then return end
    lastTick = now

    local mm = AshitaCore:GetMemoryManager()
    if not mm or mm:GetPlayer():GetIsZoning() ~= 0 then return end

    -- 1. FOLLOW LOGIC (No target needed)
    for _, c in ipairs(chars) do
        if c.f[1] ~= c.last_f_state then
            qcmd(string.format('/mst %s /ms follow %s', c.name, c.f[1] and 'on' or 'off'))
            c.last_f_state = c.f[1]
        end
    end

    -- 2. TARGET & PARTY DATA
    local ent, party, targ = mm:GetEntity(), mm:GetParty(), mm:GetTarget()
    if not ent or not party or not targ then return end

    local subActive = targ:GetIsSubTargetActive()
    local tIndex    = targ:GetTargetIndex(subActive)
    local tID       = (tIndex ~= 0) and ent:GetServerId(tIndex) or 0
    local tHP       = (tIndex ~= 0) and ent:GetHPPercent(tIndex) or 0
    local mainIdx   = party:GetMemberTargetIndex(0)
    local mainEngaged = (mainIdx ~= 0 and ent:GetStatus(mainIdx) == 1)

    local partyMap = {}
    for x = 0, 17 do 
        local mName = party:GetMemberName(x)
        if mName then partyMap[mName:lower()] = x end 
    end

    for _, c in ipairs(chars) do
        local pIdx = partyMap[c.name:lower()]
        if pIdx then
            local muleTP = party:GetMemberTP(pIdx)
            local muleMP = party:GetMemberMP(pIdx)
            local mIdx   = party:GetMemberTargetIndex(pIdx)
            local muleEngaged = (mIdx ~= 0 and ent:GetStatus(mIdx) == 1)
            local distSq = (mIdx ~= 0 and tIndex ~= 0) and ent:GetDistance(mIdx, tIndex) or 1000

            -- RESET LOGIC
            if not mainEngaged or tID == 0 or tHP <= 0 or (tID ~= c.last_target_id) then
                if c.last_target_id ~= tID or not mainEngaged then
                    c.step = 1; c.done = false; c.casting = false; c.last_target_id = tID; c.deb_last = 0
                end
            end

            -- ENGAGE / DISENGAGE
            if (not c.e[1] or not mainEngaged or tID == 0 or tHP <= 0) then
                if muleEngaged and (now - c.disengage_sent > 2.0) then
                    qcmd(string.format('/mst %s /attack off', c.name)); c.disengage_sent = now
                end
            elseif c.e[1] and mainEngaged and tID ~= 0 and tHP > 5 then
                if not muleEngaged and distSq < 100 then -- Only engage if within 10 yalms
                    qcmd(string.format('/mst %s /attack [t]', c.name)); c.disengage_sent = 0 
                end
            end

            -- COMBAT & DEBUFFS
            if mainEngaged and tID ~= 0 and tHP > 5 and distSq < 441 then -- 21 yalms max range
                if not c.deb[1] and not c.abs[1] then c.casting = false end

                if now > c.timer and not c.casting then 
                    -- Haste Samba
                    if c.hs[1] and muleTP >= HS_TP_THRESHOLD and (now - c.hs_last > HS_COOLDOWN) then
                        qcmd(string.format('/mst %s /ja "Haste Samba" <me>', c.name))
                        c.hs_last = now; c.timer = now + 1.8
                    
                    -- Absorb-TP (Check MP)
                    elseif c.abs[1] and muleMP >= 33 and (now - c.last_abs > ABS_COOLDOWN) then
                        qcmd(string.format('/mst %s /ma "Absorb-TP" [t]', c.name))
                        c.last_abs = now; c.cast_start = now; c.casting = true; c.timer = now + 1.0
                    
                    -- Debuffs (Check MP)
                    elseif c.deb[1] and not c.done then
                        local spell = debuff_list[c.step]
                        if (now - c.deb_last > 1.5) and muleMP >= (spell_mp[spell] or 0) then
                            qcmd(string.format('/mst %s /ma "%s" [t]', c.name, spell))
                            c.deb_last = now; c.cast_start = now; c.casting = true; c.timer = now + 1.0
                        end
                    
                    -- Steps
                    elseif c.bs[1] and muleTP >= STEP_TP_THRESHOLD and (now - c.bs_last > STEP_COOLDOWN) then
                        qcmd(string.format('/mst %s /ja "Box Step" [t]', c.name))
                        c.bs_last = now; c.timer = now + 1.5
                    elseif c.qs[1] and muleTP >= STEP_TP_THRESHOLD and (now - c.qs_last > STEP_COOLDOWN) then
                        qcmd(string.format('/mst %s /ja "Quick Step" [t]', c.name))
                        c.qs_last = now; c.timer = now + 1.5
                    end
                end
            end

            -- Casting Failsafe
            if c.casting and (now - c.cast_start > 8.0) then
                c.casting = false
                if c.deb[1] and not c.abs[1] then
                    c.step = c.step + 1; if c.step > #debuff_list then c.done = true end
                end
            end
        end
    end
end)

------------------------------------------------------------
-- UI Rendering
------------------------------------------------------------
ashita.events.register('d3d_present', 'render_ui', function ()
    if not ui_show[1] then return end
    if imgui.Begin('Sync 1.0.3', ui_show, ImGuiWindowFlags_AlwaysAutoResize) then
        if imgui.BeginTable('SyncTable', 8, bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg)) then
            imgui.TableSetupColumn('Mule'); imgui.TableSetupColumn('F'); imgui.TableSetupColumn('E')
            imgui.TableSetupColumn('HS'); imgui.TableSetupColumn('BS'); imgui.TableSetupColumn('QS')
            imgui.TableSetupColumn('Abs'); imgui.TableSetupColumn('Deb')
            imgui.TableHeadersRow()
            for i, c in ipairs(chars) do
                imgui.TableNextRow()
                imgui.TableNextColumn(); imgui.Text(c.name:upper())
                imgui.TableNextColumn(); imgui.Checkbox('##F'..i, c.f)
                imgui.TableNextColumn(); imgui.Checkbox('##E'..i, c.e)
                imgui.TableNextColumn(); imgui.Checkbox('##HS'..i, c.hs)
                imgui.TableNextColumn(); imgui.Checkbox('##BS'..i, c.bs)
                imgui.TableNextColumn(); imgui.Checkbox('##QS'..i, c.qs)
                imgui.TableNextColumn(); imgui.Checkbox('##Abs'..i, c.abs)
                imgui.TableNextColumn(); imgui.Checkbox('##Deb'..i, c.deb)
            end
            imgui.EndTable()
        end
        imgui.End()
    end
end)

ashita.events.register('load', 'sync_load', function() qcmd('/ms followme on') end)
ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args()
    if #args > 0 and args[1]:lower() == '/sync' then
        e.blocked = true; ui_show[1] = not ui_show[1]
    end
end)
