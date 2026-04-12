addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '0.5.0' 

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- CONFIGURATION & CACHE
------------------------------------------------------------
local show_ui = true
local CAST_LOCK = 3.8 
local TICK_INTERVAL = 0.5

local chars = {
    { name='shaymin',  is_guest=false, active=true, f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='muunch',   is_guest=false, active=true, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='slowpoke', is_guest=false, active=true, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='goomy',    is_guest=false, active=true, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
}

local REFRESH_JOBS = { [3]=true, [4]=true, [5]=true, [7]=true, [15]=true, [16]=true, [21]=true }
local RDM_INDEX = 4 
local lastTick = os.clock() 
local zone_lock = os.clock() + 3.0 

for _, c in ipairs(chars) do
    c.name_lower = c.name:lower()
    c.f_prev, c.e_prev = c.f[1], c.e[1]
    c.step, c.done, c.action_lock = 1, false, 0
    c.hs_last, c.step_last, c.abs_last, c.deb_last = 0, 0, 0, 0
    c.buffs = {} 
    c.last_cast = {} 
    c.job = 0 
    c.pIdx = -1 
    c.engaged_target = 0 
end

local chatManager = AshitaCore:GetChatManager()
local memManager = AshitaCore:GetMemoryManager()
local qcmd = function(cmd) chatManager:QueueCommand(1, cmd) end

------------------------------------------------------------
-- COMMAND HANDLER
------------------------------------------------------------
ashita.events.register('command', 'command_logic', function (e)
    local args = e.command:args()
    if #args > 0 and args[1]:lower() == '/sync' then
        show_ui = not show_ui
        e.blocked = true
    end
end)

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function get_effective_target()
    local targ = memManager:GetTarget()
    local ent = memManager:GetEntity()
    if not targ or not ent then return 0 end
    local tIdx = targ:GetTargetIndex(targ:GetIsSubTargetActive())
    if tIdx == 0 then return 0 end
    local target_ent = ent:GetRawEntity(tIdx)
    if target_ent and target_ent.SpawnType == 0 then 
        local totIdx = ent:GetTargetedIndex(tIdx)
        if totIdx ~= 0 then return totIdx end
    end
    return tIdx
end

------------------------------------------------------------
-- PACKET TRACKING (0x076)
------------------------------------------------------------
ashita.events.register('packet_in', 'packet_logic', function (e)
    if (e.id == 0x076) then
        local party = memManager:GetParty()
        if not party then return end
        for x = 0, 4 do
            local offset = x * 0x30
            local server_id = struct.unpack('I', e.data, offset + 0x04 + 1)
            if server_id and server_id > 0 then
                for p = 0, 5 do
                    if party:GetMemberIsActive(p) == 1 and party:GetMemberServerId(p) == server_id then
                        local rawName = party:GetMemberName(p)
                        if rawName then
                            local target_name = rawName:lower()
                            for _, c in ipairs(chars) do
                                if target_name == c.name_lower then
                                    local current_buffs = {}
                                    for i = 0, 31 do
                                        local mask = bit.band(bit.rshift(struct.unpack('b', e.data, bit.rshift(i, 2) + (offset + 0x0C) + 1), 2 * (i % 4)), 3)
                                        local buffId = bit.bor(struct.unpack('B', e.data, (offset + 0x14) + i + 1), bit.lshift(mask, 8))
                                        if buffId ~= 255 and buffId > 0 then current_buffs[buffId] = true end
                                    end
                                    c.buffs = current_buffs
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end)

------------------------------------------------------------
-- CASTING LOGIC
------------------------------------------------------------
local function check_buff_needed(target_char, buff_id, now, retry_delay)
    if not target_char.buffs[buff_id] then
        if not target_char.last_cast[buff_id] or (now - target_char.last_cast[buff_id] > retry_delay) then
            return true
        end
    end
    return false
end

local function try_cast(command, caster, target_char, buff_id, now, lock_time, retry_delay)
    if check_buff_needed(target_char, buff_id, now, retry_delay) then
        qcmd(command)
        target_char.last_cast[buff_id] = now
        caster.action_lock = now + lock_time
        return true
    end
    return false
end

local function handle_buffs(caster, now)
    local buff_needed = false
    for _, c in ipairs(chars) do
        if c.buf[1] then
            if check_buff_needed(c, 33, now, 15) then buff_needed = true; break end
            if REFRESH_JOBS[c.job] and check_buff_needed(c, 43, now, 15) then buff_needed = true; break end
            if c.name ~= caster.name and check_buff_needed(c, 116, now, 15) then buff_needed = true; break end
            if check_buff_needed(c, 40, now, 120) then buff_needed = true; break end
            if check_buff_needed(c, 41, now, 120) then buff_needed = true; break end
        end
    end

    if not buff_needed and caster.buf[1] then
        if check_buff_needed(caster, 116, now, 15) then buff_needed = true end
        if check_buff_needed(caster, 432, now, 300) then buff_needed = true end
    end

    if buff_needed then
        if try_cast(string.format('/mst %s /ja "Composure" <me>', caster.name), caster, caster, 419, now, 2.0, 300) then return true end
    end

    for _, c in ipairs(chars) do
        if c.buf[1] then
            if try_cast(string.format('/mst %s /ma "Haste II" %s', caster.name, c.name), caster, c, 33, now, CAST_LOCK, 15) then return true end
        end
    end

    if caster.buf[1] then
        if try_cast(string.format('/mst %s /ma "Phalanx" <me>', caster.name), caster, caster, 116, now, CAST_LOCK, 15) then return true end
        if try_cast(string.format('/mst %s /ma "Temper II" <me>', caster.name), caster, caster, 432, now, CAST_LOCK, 300) then return true end
    end

    for _, c in ipairs(chars) do
        if c.buf[1] then
            if REFRESH_JOBS[c.job] and try_cast(string.format('/mst %s /ma "Refresh III" %s', caster.name, c.name), caster, c, 43, now, CAST_LOCK, 15) then return true end
            if c.name ~= caster.name and try_cast(string.format('/mst %s /ma "Phalanx II" %s', caster.name, c.name), caster, c, 116, now, CAST_LOCK, 15) then return true end
            if try_cast(string.format('/mst %s /ma "Protect V" %s', caster.name, c.name), caster, c, 40, now, CAST_LOCK, 120) then return true end
            if try_cast(string.format('/mst %s /ma "Shell V" %s', caster.name, c.name), caster, c, 41, now, CAST_LOCK, 120) then return true end
        end
    end
    return false
end

------------------------------------------------------------
-- CORE LOOP
------------------------------------------------------------
ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os.clock()
    if now - lastTick < TICK_INTERVAL then return end
    lastTick = now

    if not memManager or memManager:GetPlayer():GetIsZoning() ~= 0 then 
        zone_lock = now + 3.0
        return 
    end
    
    if now < zone_lock then return end
    
    local party, player, ent = memManager:GetParty(), memManager:GetPlayer(), memManager:GetEntity()
    local caster = chars[RDM_INDEX]
    
    local leaderTIdx = party:GetMemberTargetIndex(0)
    local leaderStatus = (leaderTIdx ~= 0) and ent:GetStatus(leaderTIdx) or 0
    
    local mainEngaged = (leaderStatus == 1)
    local effectiveTarget = get_effective_target()

    -- Reset guest activity flags
    for _, c in ipairs(chars) do 
        if c.is_guest then c.active = false end 
    end

    for p = 0, 5 do
        if party:GetMemberIsActive(p) == 1 then
            -- TRUST FILTER: Get the entity and check SpawnType (0 = PC, 2 = NPC/Trust)
            local tIdx = party:GetMemberTargetIndex(p)
            local mEnt = (tIdx ~= 0) and ent:GetRawEntity(tIdx) or nil
            
            -- If we can't find the entity (out of range), we assume it's okay for now.
            -- If we DO find it and it's SpawnType 2, skip it.
            if not (mEnt and mEnt.SpawnType == 2) then
                local rawName = party:GetMemberName(p)
                if rawName then
                    local pName = rawName:lower()
                    local pJob = party:GetMemberMainJob(p)
                    local found = false
                    
                    for _, c in ipairs(chars) do
                        if pName == c.name_lower then
                            c.job = pJob; c.pIdx = p; c.active = true
                            if p == 0 then 
                                local current_buffs = {}
                                local pBuffs = player:GetBuffs()
                                for j = 0, 31 do
                                    local b = pBuffs[j]
                                    if b and b > 0 and b ~= 255 then current_buffs[b] = true end
                                end
                                c.buffs = current_buffs
                            end
                            found = true; break
                        end
                    end
                    
                    if not found then
                        local new_guest = {
                            name = rawName, name_lower = pName, is_guest = true, active = true,
                            f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false},
                            f_prev=false, e_prev=false, step=1, done=false, action_lock=0, hs_last=0, step_last=0, abs_last=0, deb_last=0,
                            buffs={}, last_cast={}, job=pJob, pIdx=p, engaged_target=0
                        }
                        table.insert(chars, new_guest)
                    end
                end
            end
        end
    end

    for i = #chars, 1, -1 do
        if chars[i].is_guest and not chars[i].active then table.remove(chars, i) end
    end

    -- Follow and Attack Logic
    for i, c in ipairs(chars) do
        if not c.is_guest and i ~= 1 and c.pIdx ~= -1 then
            if c.f[1] ~= c.f_prev then
                qcmd(string.format('/mst %s /ms follow %s', c.name, c.f[1] and 'on' or 'off'))
                c.f_prev = c.f[1]
            end
            
            local should_be_attacking = c.e[1] and mainEngaged
            
            if should_be_attacking then
                if c.engaged_target ~= effectiveTarget then
                    qcmd(string.format('/mst %s /attack [t]', c.name))
                    c.engaged_target = effectiveTarget
                    -- Buffer magic for 2s to allow weapon draw animation
                    if i == RDM_INDEX then
                        c.action_lock = now + 2.0
                        c.step = 1
                        c.done = false
                    end
                end
            else
                if c.engaged_target ~= 0 then
                    qcmd(string.format('/mst %s /attack off', c.name))
                    c.engaged_target = 0
                end
            end
        end
    end

    -- RDM Main Loop
    if now > caster.action_lock then
        if mainEngaged and caster.deb[1] and not caster.done and now > caster.deb_last + 2.5 then
            local debuffs = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Slow II", "Paralyze II" }
            local s = debuffs[caster.step]
            if s then 
                qcmd(string.format('/mst %s /ma "%s" [t]', caster.name, s))
                caster.deb_last = now; caster.action_lock = now + CAST_LOCK; caster.step = caster.step + 1 
            else caster.done = true end
        else
            handle_buffs(caster, now)
        end
    end

    -- Mule JA Logic
    for i, c in ipairs(chars) do
        if not c.is_guest and i ~= 1 and i ~= RDM_INDEX and now > c.action_lock and c.pIdx ~= -1 then
            local tp, mp = party:GetMemberTP(c.pIdx), party:GetMemberMP(c.pIdx)
            if c.abs[1] and mp >= 33 and now > c.abs_last + 15 then
                qcmd(string.format('/mst %s /ma "Absorb-TP" [t]', c.name))
                c.abs_last = now; c.action_lock = now + 4.0
            elseif mainEngaged then
                if c.hs[1] and tp >= 350 and now > c.hs_last + 85 then
                    qcmd(string.format('/mst %s /ja "Haste Samba" <me>', c.name)); c.hs_last = now; c.action_lock = now + 2.0
                elseif c.bs[1] and tp >= 100 and now > c.step_last + 10 then
                    qcmd(string.format('/mst %s /ja "Box Step" [t]', c.name)); c.step_last = now; c.action_lock = now + 2.0
                elseif c.qs[1] and tp >= 100 and now > c.step_last + 10 then
                    qcmd(string.format('/mst %s /ja "Quick Step" [t]', c.name)); c.step_last = now; c.action_lock = now + 2.0
                end
            end
        end
    end

    if not mainEngaged then caster.step, caster.done = 1, false end
end)

------------------------------------------------------------
-- UI
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
                if c.active then
                    imgui.TableNextRow(); imgui.TableNextColumn(); imgui.Text(c.name:upper())
                    imgui.TableNextColumn(); if not c.is_guest and i ~= 1 then imgui.Checkbox('##F'..i, c.f) else imgui.TextDisabled("-") end
                    imgui.TableNextColumn(); if not c.is_guest and i ~= 1 then imgui.Checkbox('##E'..i, c.e) else imgui.TextDisabled("-") end
                    imgui.TableNextColumn(); if not c.is_guest and i ~= 1 then imgui.Checkbox('##H'..i, c.hs) else imgui.TextDisabled("-") end
                    imgui.TableNextColumn(); if not c.is_guest and i ~= 1 then imgui.Checkbox('##BS'..i, c.bs) else imgui.TextDisabled("-") end
                    imgui.TableNextColumn(); if not c.is_guest and i ~= 1 then imgui.Checkbox('##Q'..i, c.qs) else imgui.TextDisabled("-") end
                    imgui.TableNextColumn(); if not c.is_guest and i ~= 1 then imgui.Checkbox('##A'..i, c.abs) else imgui.TextDisabled("-") end
                    imgui.TableNextColumn(); if not c.is_guest and i == RDM_INDEX then imgui.Checkbox('##D'..i, c.deb) else imgui.TextDisabled("-") end
                    imgui.TableNextColumn(); imgui.Checkbox('##U'..i, c.buf)
                end
            end
            imgui.EndTable()
        end
        imgui.End()
    end
    imgui.PopStyleVar(2)
end)

ashita.events.register('load','sync_load',function()
    qcmd('/ms followme on')
    qcmd('/mso /ms follow on')
end)
