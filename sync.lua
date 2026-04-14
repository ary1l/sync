addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '.013' 

require('common')
local imgui = require('imgui')
local ffi = require('ffi')

ffi.cdef[[
    int32_t memcmp(const void* buff1, const void* buff2, size_t count);
]]

------------------------------------------------------------
-- CONFIGURATION & SETTINGS
------------------------------------------------------------
local show_ui = true
local CAST_LOCK = 4.2 
local TICK_INTERVAL = 0.5
local lastTick = os.clock() 
local lastSync = 0
local zone_lock = os.clock() + 3.0 

local REFRESH_JOBS = { [3]=true, [4]=true, [5]=true, [7]=true, [8]=true, [15]=true, [16]=true, [21]=true, [22]=true }
local SILENCE_LIST = { 
    ['Crimson-toothed Pawberry']=true, ['Korrigan']=true, ['Sozu Rognot']=true, 
    ['Ghost']=true, ['Shadow']=true, ['Vampyr']=true, ['Warlock']=true 
}

local chars = {
    { name='shaymin',  active=false, f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='muunch',   active=false, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='slowpoke', active=false, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='goomy',    active=false, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
}

local global_buff_cache = {} 
local mm = AshitaCore:GetMemoryManager()
local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

local function init_char(c)
    c.name_lower = c.name:lower()
    c.f_prev, c.e_prev = c.f[1], c.e[1]
    c.step, c.done, c.action_lock = 1, false, 0
    c.buffs = {} 
    c.last_cast = {} 
    c.last_target_id = 0 
    c.sId = 0
    c.last_attack_targ = 0
    c.silence_done = false
end

for _, c in ipairs(chars) do init_char(c) end

------------------------------------------------------------
-- PACKET HANDLING (BUFF TRACKING)
------------------------------------------------------------
ashita.events.register('packet_in', 'HandlePackets', function (e)
    if (e.id == 0x00A) then
        for _, c in ipairs(chars) do
            c.e[1] = false; c.done = false; c.step = 1; c.last_target_id = 0; c.last_attack_targ = 0
        end
        zone_lock = os.clock() + 4.0
        return
    end

    if (e.id == 0x076) then
        local data = e.data:totable()
        for k = 0, 4 do
            local offset = (4 + (k * 48))
            local sId = ashita.bits.unpack_be(data, offset * 8, 32)
            if sId > 0 then
                local rawBuffs = {}
                for i = 0, 31 do
                    local bitPos = (offset + 16) * 8 + (i * 10)
                    local bid = ashita.bits.unpack_be(data, bitPos, 10)
                    if bid > 0 and bid < 1023 then rawBuffs[bid] = true end
                end
                global_buff_cache[sId] = rawBuffs
            end
        end
    end
end)

local function has_buff(target_char, buff_id)
    if target_char.name_lower == 'shaymin' then
        local pBuffs = mm:GetPlayer():GetBuffs()
        for j = 0, 31 do if pBuffs[j] == buff_id then return true end end
    end
    if os.clock() - (target_char.last_cast[buff_id] or 0) < 180 then return true end
    local buffs = global_buff_cache[target_char.sId] or {}
    return buffs[buff_id] == true
end

------------------------------------------------------------
-- RDM ACTION LOGIC (UPDATED)
------------------------------------------------------------
local function handle_buffs(caster, now)
    if not caster then return false end

    -- 1. COMPOSURE: Always check for RDM
    if not has_buff(caster, 419) then
        if now - (caster.last_cast[419] or 0) > 10 then 
            qcmd(string.format('/mst %s /ja "Composure" <me>', caster.name))
            caster.last_cast[419] = now; caster.action_lock = now + 2.0; return true
        end
    end

    -- 2. PARTY BUFFS: Based on Target's Toggle
    for _, c in ipairs(chars) do
        if c.active and c.buf[1] then
            local target = (c.name_lower == caster.name_lower) and "<me>" or c.name
            local buffs = { 
                {id=580, name="Haste II"}, 
                {id=591, name="Refresh III", job=true}, 
                {id=116, name="Phalanx II"} 
            }
            for _, b in ipairs(buffs) do
                if (not b.job or REFRESH_JOBS[c.job]) and not has_buff(c, b.id) then
                    local spell = (b.id == 116 and c.name_lower == caster.name_lower) and "Phalanx" or b.name
                    qcmd(string.format('/mst %s /ma "%s" %s', caster.name, spell, target))
                    c.last_cast[b.id] = now; caster.action_lock = now + CAST_LOCK; return true
                end
            end
        end
    end
    return false
end

ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os.clock()
    if not mm or mm:GetPlayer():GetIsZoning() ~= 0 or now < zone_lock then return end
    
    local party, ent = mm:GetParty(), mm:GetEntity()
    local goomy = nil
    for _, c in ipairs(chars) do if c.name_lower == 'goomy' then goomy = c; break end end
    
    local leaderTIdx = party:GetMemberTargetIndex(0)
    local currentMobID = 0
    local mainEngaged = false

    if leaderTIdx ~= 0 and leaderTIdx < 2304 then 
        local leaderEntId = ent:GetServerId(leaderTIdx)
        if leaderEntId ~= 0 then
            currentMobID = leaderEntId
            mainEngaged = (ent:GetStatus(leaderTIdx) == 1)
        end
    end

    -- Engage/Disengage Mules
    for _, c in ipairs(chars) do
        if c.active and c.name_lower ~= 'shaymin' and not c.is_guest then
            if c.e[1] and mainEngaged and currentMobID ~= 0 then
                if c.last_attack_targ ~= currentMobID then
                    qcmd(string.format('/mst %s /attack [t]', c.name))
                    c.last_attack_targ = currentMobID
                end
            elseif (not mainEngaged and c.last_attack_targ ~= 0) or (c.e_prev and not c.e[1]) then
                qcmd(string.format('/mst %s /attack off', c.name))
                c.last_attack_targ = 0
            end
            c.e_prev = c.e[1]
        end
    end

    if now - lastTick < TICK_INTERVAL then return end
    lastTick = now

    -- Party Scanner
    for _, c in ipairs(chars) do c.active = false end
    for p = 0, 17 do
        if party:GetMemberIsActive(p) == 1 then
            local tIdx = party:GetMemberTargetIndex(p)
            if tIdx ~= 0 then 
                local rawName = party:GetMemberName(p); local pName = rawName:lower(); local found = false
                for _, c in ipairs(chars) do
                    if pName == c.name_lower then 
                        c.job, c.sId, c.active, c.pIdx = party:GetMemberMainJob(p), party:GetMemberServerId(p), true, p
                        found = true; break 
                    end
                end
                if not found then
                    local guest = { name=rawName, is_guest=true, active=true, f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} }
                    init_char(guest); guest.job, guest.sId, guest.pIdx = party:GetMemberMainJob(p), party:GetMemberServerId(p), p; table.insert(chars, guest)
                end
            end
        end
    end
    for i = #chars, 1, -1 do if chars[i].is_guest and not chars[i].active then table.remove(chars, i) end end

    -- RDM Rotation logic (UPDATED PRIORITY)
    if goomy and goomy.active and now > goomy.action_lock then
        local isEngaged = (mainEngaged and currentMobID ~= 0 and ent:GetHPPercent(leaderTIdx) > 0)
        
        if isEngaged and goomy.deb[1] then
            if currentMobID ~= goomy.last_target_id then
                goomy.last_target_id = currentMobID; goomy.step = 1; goomy.done = false; goomy.silence_done = false
            end
            
            if not goomy.done then
                local tName = ent:GetName(leaderTIdx)
                if not goomy.silence_done and SILENCE_LIST[tName] then
                    qcmd(string.format('/mst %s /ma "Silence" [t]', goomy.name))
                    goomy.silence_done = true; goomy.action_lock = now + CAST_LOCK; return
                end
                local debuffs = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Slow II", "Paralyze II" }
                local s = debuffs[goomy.step]
                if s then 
                    qcmd(string.format('/mst %s /ma "%s" [t]', goomy.name, s))
                    goomy.step = goomy.step + 1; goomy.action_lock = now + CAST_LOCK; return 
                else 
                    goomy.done = true 
                end
            end
        end
        handle_buffs(goomy, now)
    end

    -- Follow Toggles
    for _, c in ipairs(chars) do
        if c.active and not c.is_guest and c.name_lower ~= 'shaymin' then
            if c.f[1] ~= c.f_prev then qcmd(string.format('/mst %s /ms follow %s', c.name, c.f[1] and 'on' or 'off')); c.f_prev = c.f[1] end
        end
    end
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
                    local is_core = not c.is_guest and (c.name_lower ~= 'shaymin')
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##F'..i, c.f) else imgui.Text("-") end
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##E'..i, c.e) else imgui.Text("-") end
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##H'..i, c.hs) else imgui.Text("-") end
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##B'..i, c.bs) else imgui.Text("-") end
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##Q'..i, c.qs) else imgui.Text("-") end
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##A'..i, c.abs) else imgui.Text("-") end
                    imgui.TableNextColumn(); if c.name_lower == 'goomy' then imgui.Checkbox('##D'..i, c.deb) else imgui.Text("-") end
                    imgui.TableNextColumn(); imgui.Checkbox('##U'..i, c.buf)
                end
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
    qcmd('/ms followme on'); qcmd('/mso /ms follow on')
end)addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '1.1.12' 

require('common')
local imgui = require('imgui')
local ffi = require('ffi')

ffi.cdef[[
    int32_t memcmp(const void* buff1, const void* buff2, size_t count);
]]

------------------------------------------------------------
-- CONFIGURATION & SETTINGS
------------------------------------------------------------
local show_ui = true
local CAST_LOCK = 4.2 
local TICK_INTERVAL = 0.5
local lastTick = os.clock() 
local lastSync = 0
local zone_lock = os.clock() + 3.0 

local SELF_TRUST_DURATION = 180.0 
local REFRESH_JOBS = { [3]=true, [4]=true, [5]=true, [7]=true, [8]=true, [15]=true, [16]=true, [21]=true, [22]=true }
local SILENCE_LIST = { 
    ['Crimson-toothed Pawberry']=true, ['Korrigan']=true, ['Sozu Rognot']=true, 
    ['Ghost']=true, ['Shadow']=true, ['Vampyr']=true, ['Warlock']=true 
}

local chars = {
    { name='shaymin',  active=false, f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='muunch',   active=false, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='slowpoke', active=false, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='goomy',    active=false, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
}

local global_buff_cache = {} 
local mm = AshitaCore:GetMemoryManager()
local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

local function init_char(c)
    c.name_lower = c.name:lower()
    c.f_prev, c.e_prev = c.f[1], c.e[1]
    c.step, c.done, c.action_lock = 1, false, 0
    c.buffs = {} 
    c.last_cast = {} 
    c.last_target_id = 0 
    c.sId = 0
    c.last_attack_targ = 0
    c.silence_done = false
end

for _, c in ipairs(chars) do init_char(c) end

------------------------------------------------------------
-- PACKET HANDLING (BUFF TRACKING)
------------------------------------------------------------
ashita.events.register('packet_in', 'HandlePackets', function (e)
    if (e.id == 0x00A) then
        for _, c in ipairs(chars) do
            c.e[1] = false; c.done = false; c.step = 1; c.last_target_id = 0; c.last_attack_targ = 0
        end
        zone_lock = os.clock() + 4.0
        return
    end

    if (e.id == 0x076) then
        local data = e.data:totable()
        for k = 0, 4 do
            local offset = (4 + (k * 48))
            local sId = ashita.bits.unpack_be(data, offset * 8, 32)
            if sId > 0 then
                local rawBuffs = {}
                for i = 0, 31 do
                    local bitPos = (offset + 16) * 8 + (i * 10)
                    local bid = ashita.bits.unpack_be(data, bitPos, 10)
                    if bid > 0 and bid < 1023 then rawBuffs[bid] = true end
                end
                global_buff_cache[sId] = rawBuffs
            end
        end
    end
end)

local function has_buff(target_char, buff_id)
    if target_char.name_lower == 'shaymin' then
        local pBuffs = mm:GetPlayer():GetBuffs()
        for j = 0, 31 do if pBuffs[j] == buff_id then return true end end
    end
    -- Prevent rapid recasting within 3 minutes of a local cast attempt
    if os.clock() - (target_char.last_cast[buff_id] or 0) < 180 then return true end
    local buffs = global_buff_cache[target_char.sId] or {}
    return buffs[buff_id] == true
end

------------------------------------------------------------
-- RDM ACTION LOGIC
------------------------------------------------------------
local function handle_buffs(caster, now)
    if not caster or not caster.buf[1] then return false end

    -- Composure Check (Renew every 5 mins)
    if not has_buff(caster, 419) then
        if now - (caster.last_cast[419] or 0) > 305 then
            qcmd(string.format('/mst %s /ja "Composure" <me>', caster.name))
            caster.last_cast[419] = now; caster.action_lock = now + 2.0; return true
        end
    end

    for _, c in ipairs(chars) do
        if c.active and c.buf[1] then
            local target = (c.name_lower == caster.name_lower) and "<me>" or c.name
            local buffs = { 
                {id=580, name="Haste II"}, 
                {id=591, name="Refresh III", job=true}, 
                {id=116, name="Phalanx II"} 
            }
            for _, b in ipairs(buffs) do
                if (not b.job or REFRESH_JOBS[c.job]) and not has_buff(c, b.id) then
                    local spell = (b.id == 116 and c.name_lower == caster.name_lower) and "Phalanx" or b.name
                    qcmd(string.format('/mst %s /ma "%s" %s', caster.name, spell, target))
                    c.last_cast[b.id] = now; caster.action_lock = now + CAST_LOCK; return true
                end
            end
        end
    end
    return false
end

ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os.clock()
    if not mm or mm:GetPlayer():GetIsZoning() ~= 0 or now < zone_lock then return end
    
    local party, ent = mm:GetParty(), mm:GetEntity()
    
    -- Safety: Get Goomy by name
    local goomy = nil
    for _, c in ipairs(chars) do if c.name_lower == 'goomy' then goomy = c; break end end
    
    -- Engagement Logic
    local leaderTIdx = party:GetMemberTargetIndex(0)
    local currentMobID = 0
    local mainEngaged = false

    if leaderTIdx ~= 0 and leaderTIdx < 2304 then 
        local leaderEntId = ent:GetServerId(leaderTIdx)
        if leaderEntId ~= 0 then
            currentMobID = leaderEntId
            mainEngaged = (ent:GetStatus(leaderTIdx) == 1)
        end
    end

    -- Engage/Disengage Mules
    for _, c in ipairs(chars) do
        if c.active and c.name_lower ~= 'shaymin' and not c.is_guest then
            if c.e[1] and mainEngaged and currentMobID ~= 0 then
                if c.last_attack_targ ~= currentMobID then
                    qcmd(string.format('/mst %s /attack [t]', c.name))
                    c.last_attack_targ = currentMobID
                end
            elseif (not mainEngaged and c.last_attack_targ ~= 0) or (c.e_prev and not c.e[1]) then
                qcmd(string.format('/mst %s /attack off', c.name))
                c.last_attack_targ = 0
            end
            c.e_prev = c.e[1]
        end
    end

    if now - lastTick < TICK_INTERVAL then return end
    lastTick = now

    -- Party Scanner (ServerID based)
    for _, c in ipairs(chars) do c.active = false end
    for p = 0, 17 do
        if party:GetMemberIsActive(p) == 1 then
            local tIdx = party:GetMemberTargetIndex(p)
            if tIdx ~= 0 then -- Only active if in same zone
                local rawName = party:GetMemberName(p); local pName = rawName:lower(); local found = false
                for _, c in ipairs(chars) do
                    if pName == c.name_lower then 
                        c.job, c.sId, c.active, c.pIdx = party:GetMemberMainJob(p), party:GetMemberServerId(p), true, p
                        found = true; break 
                    end
                end
                if not found then
                    local guest = { name=rawName, is_guest=true, active=true, f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} }
                    init_char(guest); guest.job, guest.sId, guest.pIdx = party:GetMemberMainJob(p), party:GetMemberServerId(p), p; table.insert(chars, guest)
                end
            end
        end
    end
    for i = #chars, 1, -1 do if chars[i].is_guest and not chars[i].active then table.remove(chars, i) end end

    -- RDM Rotation logic
    if goomy and goomy.active and now > goomy.action_lock then
        if mainEngaged and currentMobID ~= 0 and ent:GetHPPercent(leaderTIdx) > 0 and goomy.deb[1] then
            if currentMobID ~= goomy.last_target_id then
                goomy.last_target_id = currentMobID; goomy.step = 1; goomy.done = false; goomy.silence_done = false
            end
            
            if not goomy.done then
                local tName = ent:GetName(leaderTIdx)
                if not goomy.silence_done and SILENCE_LIST[tName] then
                    qcmd(string.format('/mst %s /ma "Silence" [t]', goomy.name))
                    goomy.silence_done = true; goomy.action_lock = now + CAST_LOCK; return
                end
                local debuffs = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Slow II", "Paralyze II" }
                local s = debuffs[goomy.step]
                if s then 
                    qcmd(string.format('/mst %s /ma "%s" [t]', goomy.name, s))
                    goomy.step = goomy.step + 1; goomy.action_lock = now + CAST_LOCK
                else goomy.done = true end
            end
        else handle_buffs(goomy, now) end
    end

    -- Follow Toggles
    for _, c in ipairs(chars) do
        if c.active and not c.is_guest and c.name_lower ~= 'shaymin' then
            if c.f[1] ~= c.f_prev then qcmd(string.format('/mst %s /ms follow %s', c.name, c.f[1] and 'on' or 'off')); c.f_prev = c.f[1] end
        end
    end
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
                    local is_core = not c.is_guest and (c.name_lower ~= 'shaymin')
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##F'..i, c.f) else imgui.Text("-") end
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##E'..i, c.e) else imgui.Text("-") end
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##H'..i, c.hs) else imgui.Text("-") end
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##B'..i, c.bs) else imgui.Text("-") end
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##Q'..i, c.qs) else imgui.Text("-") end
                    imgui.TableNextColumn(); if is_core then imgui.Checkbox('##A'..i, c.abs) else imgui.Text("-") end
                    imgui.TableNextColumn(); if c.name_lower == 'goomy' then imgui.Checkbox('##D'..i, c.deb) else imgui.Text("-") end
                    imgui.TableNextColumn(); imgui.Checkbox('##U'..i, c.buf)
                end
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
    qcmd('/ms followme on'); qcmd('/mso /ms follow on')
end)
