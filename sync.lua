addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '0.9.2' 

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
local zone_lock = os.clock() + 3.0 

-- Trust Window: Don't even check for 180s after a successful cast
local SELF_TRUST_DURATION = 180.0 

local REFRESH_JOBS = { [3]=true, [4]=true, [5]=true, [7]=true, [8]=true, [15]=true, [16]=true, [21]=true, [22]=true }
local SILENCE_LIST = { 
    ['Crimson-toothed Pawberry']=true, ['Korrigan']=true, ['Sozu Rognot']=true, 
    ['Ghost']=true, ['Shadow']=true, ['Vampyr']=true, ['Warlock']=true 
}

local HS_TP_THRESHOLD = 350
local STEP_TP_THRESHOLD = 100

local chars = {
    { name='shaymin',  is_guest=false, active=true, f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='muunch',   is_guest=false, active=true, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='slowpoke', is_guest=false, active=true, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='goomy',    is_guest=false, active=true, f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
}

local RDM_INDEX = 4 
local global_buff_cache = {} 
local incomingReferenceBuffer = T{}
local incomingChunkBuffer

local mm = AshitaCore:GetMemoryManager()
local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

local function init_char(c)
    c.name_lower = c.name:lower()
    c.f_prev, c.e_prev = c.f[1], c.e[1]
    c.step, c.done, c.action_lock = 1, false, 0
    c.hs_last, c.step_last, c.abs_last, c.deb_last = 0, 0, 0, 0
    c.next_step = 'bs'
    c.buffs = {} 
    c.last_cast = {} 
    c.job = 0 
    c.pIdx, c.sId = -1, 0
    c.engaged_target = 0 
    c.silence_done = false
    c.e[1], c.hs[1], c.bs[1], c.qs[1], c.abs[1], c.deb[1], c.buf[1] = false, false, false, false, false, false, false
end

for _, c in ipairs(chars) do init_char(c) end

------------------------------------------------------------
-- PACKETS & HELPERS
------------------------------------------------------------
ashita.events.register('packet_in', 'HandlePackets', function (e)
    local isDuplicate = false
    if ffi.C.memcmp(e.data_raw, e.chunk_data_raw, e.size) == 0 then
        if #incomingReferenceBuffer > 2 then incomingReferenceBuffer[#incomingReferenceBuffer] = nil end
        if incomingChunkBuffer then table.insert(incomingReferenceBuffer, 1, incomingChunkBuffer) end
        incomingChunkBuffer = T{}
        local offset = 0
        while (offset < e.chunk_size) do
            local size = ashita.bits.unpack_be(e.chunk_data_raw, offset, 9, 7) * 4
            local chunk_packet = struct.unpack('c' .. size, e.chunk_data, offset + 1)
            incomingChunkBuffer:append(chunk_packet)
            offset = offset + size
        end
    end

    local packet_str = struct.unpack('c' .. e.size, e.data, 1)
    for _, chunk in ipairs(incomingReferenceBuffer) do
        for _, bufferEntry in ipairs(chunk) do
            if packet_str == bufferEntry then isDuplicate = true; break end
        end
    end
    if isDuplicate then return end

    if (e.id == 0x076) then
        local data = e.data:totable()
        for k = 0, 4 do
            local memberOffset = (4 + (k * 48))
            local sId = ashita.bits.unpack_be(data, memberOffset * 8, 32)
            if sId > 0 then
                local rawBuffs = {}
                for i = 0, 31 do
                    local bitPos = (memberOffset + 16) * 8 + (i * 10)
                    local bid = ashita.bits.unpack_be(data, bitPos, 10)
                    if bid > 0 and bid < 1023 then rawBuffs[bid] = true end
                end
                global_buff_cache[sId] = rawBuffs
                for _, c in ipairs(chars) do
                    if c.sId == sId then
                        c.buffs = rawBuffs
                        c.job = data[memberOffset + 12 + 1]
                        break
                    end
                end
            end
        end
    elseif (e.id == 0x28 or e.id == 0x29) then
        local actor = ashita.bits.unpack_be(e.data:totable(), 40, 32)
        if actor == chars[RDM_INDEX].sId then
            chars[RDM_INDEX].action_lock = os.clock() + 2.95
        end
    end
end)

local function get_effective_target()
    local targ = mm:GetTarget()
    local ent = mm:GetEntity()
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

local function has_buff(target_char, buff_id)
    local buffs = global_buff_cache[target_char.sId] or target_char.buffs
    return buffs[buff_id] == true
end

------------------------------------------------------------
-- BUFF LOGIC
------------------------------------------------------------
local function handle_buffs(caster, now)
    local LONG_RETRY = 180.0 

    -- GLOBAL COMPOSURE CHECK
    -- Only checks if ANYONE (self or party) is flagged for buffs
    local any_buffing = false
    for _, c in ipairs(chars) do if c.active and c.buf[1] then any_buffing = true; break end end

    if any_buffing then
        if not has_buff(caster, 419) then
            if now - (caster.last_cast[419] or 0) > 305 then 
                qcmd(string.format('/mst %s /ja "Composure" <me>', caster.name))
                caster.last_cast[419] = now; caster.action_lock = now + 2.0; return true
            end
        end
    end

    -- SELF BUFFS
    if caster.buf[1] then
        if not (has_buff(caster, 33) or has_buff(caster, 580)) then
            if now - (caster.last_cast[33] or 0) > SELF_TRUST_DURATION then
                qcmd(string.format('/mst %s /ma "Haste II" <me>', caster.name))
                caster.last_cast[33] = now; caster.action_lock = now + CAST_LOCK; return true 
            end
        end
        if not (has_buff(caster, 43) or has_buff(caster, 591)) then
            if now - (caster.last_cast[43] or 0) > SELF_TRUST_DURATION then
                qcmd(string.format('/mst %s /ma "Refresh III" <me>', caster.name))
                caster.last_cast[43] = now; caster.action_lock = now + CAST_LOCK; return true
            end
        end
        if not has_buff(caster, 116) then
            if now - (caster.last_cast[116] or 0) > SELF_TRUST_DURATION then
                qcmd(string.format('/mst %s /ma "Phalanx" <me>', caster.name))
                caster.last_cast[116] = now; caster.action_lock = now + CAST_LOCK; return true
            end
        end
    end

    -- PARTY BUFF LOOP
    for _, c in ipairs(chars) do
        if c.active and c.buf[1] and c.name_lower ~= caster.name_lower then
            local target = c.name
            if not (has_buff(c, 33) or has_buff(c, 580)) then
                if now - (c.last_cast[33] or 0) > SELF_TRUST_DURATION then
                    qcmd(string.format('/mst %s /ma "Haste II" %s', caster.name, target))
                    c.last_cast[33] = now; caster.action_lock = now + CAST_LOCK; return true 
                end
            end
            if REFRESH_JOBS[c.job] and not (has_buff(c, 43) or has_buff(c, 591)) then
                if now - (c.last_cast[43] or 0) > SELF_TRUST_DURATION then
                    qcmd(string.format('/mst %s /ma "Refresh III" %s', caster.name, target))
                    c.last_cast[43] = now; caster.action_lock = now + CAST_LOCK; return true
                end
            end
            if not has_buff(c, 116) then
                if now - (c.last_cast[116] or 0) > SELF_TRUST_DURATION then
                    qcmd(string.format('/mst %s /ma "Phalanx II" %s', caster.name, target))
                    c.last_cast[116] = now; caster.action_lock = now + CAST_LOCK; return true
                end
            end
            if not has_buff(c, 40) and now - (c.last_cast[40] or 0) > LONG_RETRY then
                qcmd(string.format('/mst %s /ma "Protect V" %s', caster.name, target))
                c.last_cast[40] = now; caster.action_lock = now + CAST_LOCK; return true
            elseif not has_buff(c, 41) and now - (c.last_cast[41] or 0) > LONG_RETRY then
                qcmd(string.format('/mst %s /ma "Shell V" %s', caster.name, target))
                c.last_cast[41] = now; caster.action_lock = now + CAST_LOCK; return true
            end
        end
    end
    return false
end

------------------------------------------------------------
-- MAIN LOOP
------------------------------------------------------------
ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os.clock()
    if now - lastTick < TICK_INTERVAL then return end
    lastTick = now

    if not mm or mm:GetPlayer():GetIsZoning() ~= 0 then 
        for _, c in ipairs(chars) do
            c.e[1], c.hs[1], c.bs[1], c.qs[1], c.abs[1], c.deb[1], c.buf[1] = false, false, false, false, false, false, false
        end
        zone_lock = now + 3.0
        return 
    end    
    if now < zone_lock then return end
    
    local party, ent = mm:GetParty(), mm:GetEntity()
    local caster = chars[RDM_INDEX]
    
    local leaderTIdx = party:GetMemberTargetIndex(0)
    local mainEngaged = (leaderTIdx ~= 0 and ent:GetStatus(leaderTIdx) == 1)
    local effectiveTarget = get_effective_target()

    -- Alliance Scanning
    for _, c in ipairs(chars) do c.active = false end
    for p = 0, 17 do
        if party:GetMemberIsActive(p) == 1 then
            local rawName = party:GetMemberName(p)
            local pName = rawName:lower()
            local found = false
            for _, c in ipairs(chars) do
                if pName == c.name_lower then
                    c.job, c.pIdx, c.sId, c.active = party:GetMemberMainJob(p), p, party:GetMemberServerId(p), true
                    if p == 0 then
                        local current_buffs = {}
                        local pBuffs = mm:GetPlayer():GetBuffs()
                        for j = 0, 31 do
                            local b = pBuffs[j]
                            if b and b > 0 and b ~= 255 then current_buffs[b] = true end
                        end
                        c.buffs = current_buffs; global_buff_cache[c.sId] = current_buffs
                    end
                    found = true; break
                end
            end
            if not found then
                local guest = { name=rawName, name_lower=pName, is_guest=true, active=true, pIdx=p, sId=party:GetMemberServerId(p), f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} }
                init_char(guest); table.insert(chars, guest)
            end
        end
    end
    for i = #chars, 1, -1 do if chars[i].is_guest and not chars[i].active then table.remove(chars, i) end end

    -- Follow/Attack Sync
    for i, c in ipairs(chars) do
        if not c.is_guest and i ~= 1 and c.active then
            if c.f[1] ~= c.f_prev then qcmd(string.format('/mst %s /ms follow %s', c.name, c.f[1] and 'on' or 'off')); c.f_prev = c.f[1] end
            if c.e[1] and mainEngaged then
                if c.engaged_target ~= effectiveTarget then
                    qcmd(string.format('/mst %s /attack [t]', c.name))
                    c.engaged_target = effectiveTarget
                    if i == RDM_INDEX then 
                        c.action_lock = now + 2.0; c.step = 1; c.done = false; c.silence_done = false 
                    end
                end
            elseif c.engaged_target ~= 0 then
                qcmd(string.format('/mst %s /attack off', c.name)); c.engaged_target = 0
            end
        end
    end

    -- RDM Main Loop
    if now > caster.action_lock and caster.active then
        if mainEngaged and caster.deb[1] and not caster.done and now > caster.deb_last + 3.5 then
            local tHP = ent:GetHPPercent(effectiveTarget)
            local tName = ent:GetName(effectiveTarget)
            
            if tHP > 0 and tHP < 50 then 
                caster.done = true
            else
                if not caster.silence_done and SILENCE_LIST[tName] then
                    qcmd(string.format('/mst %s /ma "Silence" [t]', caster.name))
                    caster.silence_done = true; caster.deb_last = now; caster.action_lock = now + CAST_LOCK; return
                end

                local debuffs = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Slow II", "Paralyze II" }
                local s = debuffs[caster.step]
                if s then 
                    qcmd(string.format('/mst %s /ma "%s" [t]', caster.name, s))
                    caster.deb_last = now; caster.action_lock = now + CAST_LOCK; caster.step = caster.step + 1 
                else caster.done = true end
            end
        else
            handle_buffs(caster, now)
        end
    end

    -- JA Logic
    for i, c in ipairs(chars) do
        if not c.is_guest and i ~= 1 and i ~= RDM_INDEX and now > c.action_lock and c.active then
            local tp = party:GetMemberTP(c.pIdx)
            if c.abs[1] and now > c.abs_last + 15 then
                qcmd(string.format('/mst %s /ma "Absorb-TP" [t]', c.name)); c.abs_last = now; c.action_lock = now + 4.0
            elseif mainEngaged then
                if c.hs[1] and tp >= HS_TP_THRESHOLD and now > c.hs_last + 85 then
                    if not has_buff(c, 370) then qcmd(string.format('/mst %s /ja "Haste Samba" <me>', c.name)); c.hs_last = now; c.action_lock = now + 2.0 end
                elseif tp >= STEP_TP_THRESHOLD and now > c.step_last + 12 then
                    if c.bs[1] and c.qs[1] then
                        local s = (c.next_step == 'bs') and "Box Step" or "Quick Step"
                        qcmd(string.format('/mst %s /ja "%s" [t]', c.name, s))
                        c.next_step = (c.next_step == 'bs') and 'qs' or 'bs'
                        c.step_last = now; c.action_lock = now + 2.0
                    elseif c.bs[1] then
                        qcmd(string.format('/mst %s /ja "Box Step" [t]', c.name)); c.step_last = now; c.action_lock = now + 2.0
                    elseif c.qs[1] then
                        qcmd(string.format('/mst %s /ja "Quick Step" [t]', c.name)); c.step_last = now; c.action_lock = now + 2.0
                    end
                end
            end
        end
    end
    if not mainEngaged then caster.step, caster.done = 1, false end
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
                if c.active then
                    imgui.TableNextRow(); imgui.TableNextColumn(); imgui.Text(c.name:sub(1,6):upper())
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

ashita.events.register('command', 'cmd_logic', function(e)
    if e.command:args()[1]:lower() == '/sync' then show_ui = not show_ui; e.blocked = true end
end)

local function force_sync()
    local party = AshitaCore:GetMemoryManager():GetParty()
    print('[Sync] Requesting fresh buff data from server...')
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 then
            local sId = party:GetMemberServerId(i)
            if sId > 0 then
                local packet = struct.pack('bbbbI4', 0x016, 0x0a, 0, 0, sId)
                AshitaCore:GetPacketManager():AddOutgoingPacket(0x016, packet:totable())
            end
        end
    end
end

ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on')
    qcmd('/mso /ms follow on')
    force_sync()
end)
