-- sync v4.1.3
addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '0.8'

require('common')
local imgui = require('imgui')

-- Logic Constants
local HS_TP_THRESHOLD   = 350
local HS_COOLDOWN       = 85
local STEP_TP_THRESHOLD = 100
local STEP_COOLDOWN     = 10
local TICK_INTERVAL     = 0.4 
local lastTick          = 0

local ui_show = { true }
local debuff_list = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Paralyze II" }

-- Optimized Character Table
local chars = {
    { name='muunch',   f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0, hs_last=0, bs_last=0, qs_last=0, last_f_state=nil, deb_last=0, last_target_id=0, casting=false, cast_start=0 },
    { name='slowpoke', f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0, hs_last=0, bs_last=0, qs_last=0, last_f_state=nil, deb_last=0, last_target_id=0, casting=false, cast_start=0 },
    { name='goomy',    f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0, hs_last=0, bs_last=0, qs_last=0, last_f_state=nil, deb_last=0, last_target_id=0, casting=false, cast_start=0 },
}

local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

------------------------------------------------------------
-- Event: Packet Handling
------------------------------------------------------------
ashita.events.register('packet_in', 'packet_logic', function (e)
    if (e.id == 0x28) then
        local mm = AshitaCore:GetMemoryManager()
        if not mm then return end
        local ent = mm:GetEntity()
        if not ent then return end

        local userId   = ashita.bits.unpack_be(e.data_raw, 0, 40, 32)
        local category = ashita.bits.unpack_be(e.data_raw, 0, 82, 4)
        local actionId = ashita.bits.unpack_be(e.data_raw, 0, 86, 32)
        local actorId  = bit.band(userId, 0x7FF)
        
        -- Fix: Use GetName(id) from the entity manager
        local actorName = ent:GetName(actorId)
        
        if not actorName then return end

        for _, c in ipairs(chars) do
            if actorName:lower() == c.name:lower() then
                if actionId == 275 then c.last_abs = os.clock() end
                
                if category == 4 then -- Success
                    if c.casting then
                        c.casting = false
                        c.step = c.step + 1
                        if c.step > #debuff_list then c.done = true end
                    end
                elseif category == 8 or category == 12 then -- Fail/Interrupt
                    c.casting = false
                    c.deb_last = 0 
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

    Fetch managers inside the loop to avoid nil reference errors
    local mm = AshitaCore:GetMemoryManager()
    if not mm or mm:GetPlayer():GetIsZoning() ~= 0 then return end

    local ent   = mm:GetEntity()
    local party = mm:GetParty()
    local targ  = mm:GetTarget()
    if not ent or not party or not targ then return end

    -- Get Target Info
    local subActive = targ:GetIsSubTargetActive()
    local tIndex    = targ:GetTargetIndex(subActive)
    
    local tID = (tIndex ~= 0) and ent:GetServerId(tIndex) or 0
    local tHP = (tIndex ~= 0) and ent:GetHPPercent(tIndex) or 0

    -- Engagement Status
    local mainIdx    = party:GetMemberTargetIndex(0)
    local mainEngaged = (mainIdx ~= 0 and ent:GetStatus(mainIdx) == 1)

    for _, c in ipairs(chars) do
        local pIdx = nil
        for x=0,17 do 
            local mName = party:GetMemberName(x)
            if mName and mName:lower() == c.name:lower() then pIdx = x break end 
        end
        
        if pIdx then
            local muleTP = party:GetMemberTP(pIdx)
            
            if tHP > 0 and tHP < 5 then c.done = true end

            if tID ~= 0 and c.last_target_id ~= tID then
                c.step = 1; c.done = false; c.deb_last = 0; c.casting = false; c.last_target_id = tID
            end

            if c.last_f_state ~= c.f[1] then
                qcmd(string.format('/mst %s /ms follow %s', c.name, c.f[1] and 'on' or 'off'))
                c.last_f_state = c.f[1]
            end

            if c.abs[1] and (now - c.last_abs > 15.0) and (now - c.timer > 1.2) then
                qcmd(string.format('/mst %s /ma "Absorb-TP" [t]', c.name))
                c.timer = now
            end

            if mainEngaged and tID ~= 0 then
                if c.e[1] then qcmd(string.format('/mst %s /attack [t]', c.name)) end

                if now - c.timer > 1.2 then
                    if c.casting and (now - c.cast_start > 6.5) then
                        c.casting = false
                        c.step = c.step + 1
                        if c.step > #debuff_list then c.done = true end
                    end

                    if c.hs[1] and muleTP >= HS_TP_THRESHOLD and (now - c.hs_last > HS_COOLDOWN) then
                        qcmd(string.format('/mst %s /ja "Haste Samba" <me>', c.name))
                        c.hs_last = now; c.timer = now
                    elseif c.bs[1] and muleTP >= STEP_TP_THRESHOLD and (now - c.bs_last > STEP_COOLDOWN) then
                        qcmd(string.format('/mst %s /ja "Box Step" [t]', c.name))
                        c.bs_last = now; c.timer = now
                    elseif c.qs[1] and muleTP >= STEP_TP_THRESHOLD and (now - c.qs_last > STEP_COOLDOWN) then
                        qcmd(string.format('/mst %s /ja "Quick Step" [t]', c.name))
                        c.qs_last = now; c.timer = now
                    elseif c.deb[1] and not c.done and not c.casting then
                        if (now - c.deb_last > 2.8) then
                            qcmd(string.format('/mst %s /ma "%s" [t]', c.name, debuff_list[c.step]))
                            c.deb_last = now; c.timer = now; c.casting = true; c.cast_start = now
                        end
                    end
                end
            else
                if not mainEngaged then
                    c.step = 1; c.done = false; c.casting = false
                    if c.e[1] then qcmd(string.format('/mst %s /attack', c.name)) end
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
    if imgui.Begin('Sync 4.1.3', ui_show, ImGuiWindowFlags_AlwaysAutoResize) then
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
