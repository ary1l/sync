-- sync v3.0
addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '3.0'

require('common')
local imgui = require('imgui')

-- UI State
local ui_show = { true }
local lastTick = 0

local chars = {
    { name='muunch',   f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0 },
    { name='slowpoke', f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0 },
    { name='goomy',    f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0 },
}

local debuff_list = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Paralyze II" }
local mm = AshitaCore:GetMemoryManager()
local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

------------------------------------------------------------
-- Packet Logic 
------------------------------------------------------------
ashita.events.register('packet_in', 'packet_logic', function (e)
    if (e.id == 0x28) then
        local userId = ashita.bits.unpack_be(e.data_raw, 0, 40, 32)
        local actionId = ashita.bits.unpack_be(e.data_raw, 0, 86, 32)
        local actorName = mm:GetEntity():GetName(bit.band(userId, 0x7FF))
        if not actorName then return end

        for _, c in ipairs(chars) do
            if actorName:lower() == c.name:lower() then
                -- Track Absorb-TP (275) Success
                if actionId == 275 then c.last_abs = os.clock() end
            end
        end
    end
end)

------------------------------------------------------------
-- Main Logic Loop
------------------------------------------------------------
ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os.clock()
    if now - lastTick < 0.5 then return end
    lastTick = now

    local ent = mm:GetEntity()
    local party = mm:GetParty()
    if not party or not ent or mm:GetPlayer():GetIsZoning() ~= 0 then return end

    local mainIdx = party:GetMemberTargetIndex(0)
    local mainEngaged = (mainIdx ~= 0 and ent:GetStatus(mainIdx) == 1)

    for i, c in ipairs(chars) do
        if mainEngaged then
            -- 1. BASE ENGAGEMENT
            if c.e[1] then qcmd(string.format('/mst %s /attack [t]', c.name)) end
            
            -- 2. JOB ABILITIES 
            if now - c.timer > 2.0 then
                if c.hs[1] then
                    qcmd(string.format('/mst %s /ja "Haste Samba" <me>', c.name))
                    c.timer = now
                elseif c.bs[1] then
                    qcmd(string.format('/mst %s /ja "Box Step" [t]', c.name))
                    c.timer = now
                elseif c.qs[1] then
                    qcmd(string.format('/mst %s /ja "Quick Step" [t]', c.name))
                    c.timer = now
                end
            end
            
            -- 3. MAGIC ACTIONS (Priority: Absorb-TP > Debuffs)
            if now - c.timer > 2.5 then
                if c.abs[1] and (now - c.last_abs > 15.0) then
                    qcmd(string.format('/mst %s /ma "Absorb-TP" [t]', c.name))
                    c.timer = now
                elseif c.deb[1] and not c.done then
                    qcmd(string.format('/mst %s /ma "%s" [t]', c.name, debuff_list[c.step]))
                    c.step = c.step + 1
                    c.timer = now
                    if c.step > #debuff_list then c.done = true end
                end
            end
        else
            -- Reset on Disengage
            c.step = 1
            c.done = false
            if c.e[1] then qcmd(string.format('/mst %s /attack off', c.name)) end
        end
    end
end)

------------------------------------------------------------
-- UI Rendering
------------------------------------------------------------
ashita.events.register('d3d_present', 'render_ui', function ()
    if not ui_show[1] then return end
    
    imgui.SetNextWindowSize({ -1, -1 }, ImGuiCond_Always)
    if imgui.Begin('Sync 3.0', ui_show, ImGuiWindowFlags_AlwaysAutoResize) then
        -- Table setup with 8 columns for all features
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

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args()
    if #args > 0 and args[1]:any('/sync') then
        e.blocked = true
        ui_show[1] = not ui_show[1]
    end
end)
