addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '.01123' 

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

-- restored from 0.9.2: Don't even look at the packet for 3 mins after casting
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

local RDM_INDEX = 4 
local global_buff_cache = {} 
local mm = AshitaCore:GetMemoryManager()
local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

local function init_char(c)
    c.name_lower = c.name:lower()
    c.f_prev, c.e_prev = c.f[1], c.e[1]
    c.step, c.done, c.action_lock = 1, false, 0
    c.buffs = {} 
    c.last_cast = {} 
    c.sId = 0
    c.last_attack_targ = 0
    c.silence_done = false
end

for _, c in ipairs(chars) do init_char(c) end

------------------------------------------------------------
-- PACKETS
------------------------------------------------------------
ashita.events.register('packet_in', 'HandlePackets', function (e)
    if (e.id == 0x00A) then
        for _, c in ipairs(chars) do
            c.e[1], c.hs[1], c.bs[1], c.qs[1], c.abs[1], c.deb[1], c.buf[1] = false, false, false, false, false, false, false
            c.done, c.step, c.last_attack_targ = false, 1, 0
            c.last_cast = {} -- Wipe cast memory on zone
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
    -- Shaymin looks at his own memory for himself
    if target_char.name_lower == 'shaymin' then
        local pBuffs = mm:GetPlayer():GetBuffs()
        for j = 0, 31 do if pBuffs[j] == buff_id then return true end end
    end
    -- TRUST WINDOW: If we cast this recently, assume it's there (prevents cycling)
    if os.clock() - (target_char.last_cast[buff_id] or 0) < SELF_TRUST_DURATION then return true end
    -- Fallback to packet cache
    local cache = global_buff_cache[target_char.sId]
    return cache and cache[buff_id] == true
end

------------------------------------------------------------
-- THE BRAIN (0.9.2 Style Buffing)
------------------------------------------------------------
local function handle_buffs(caster, now)
    if not caster or not caster.active then return false end

    -- 1. COMPOSURE CHECK 
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

-- 2. TARGET LOOP (Includes Self)
    for _, c in ipairs(chars) do
        if c.active and c.buf[1] then
            local is_self = (c.name_lower == caster.name_lower)
            local target_str = is_self and "<me>" or c.name

            -- PHALANX (ID 116)
            if not has_buff(c, 116) then
                local spell = is_self and "Phalanx" or "Phalanx II"
                qcmd(string.format('/mst %s /ma "%s" %s', caster.name, spell, target_str))
                c.last_cast[116] = now; caster.action_lock = now + CAST_LOCK; return true
            end

            -- REFRESH III (ID 591)
            if (is_self or REFRESH_JOBS[c.job]) and not has_buff(c, 591) then
                qcmd(string.format('/mst %s /ma "Refresh III" %s', caster.name, target_str))
                c.last_cast[591] = now; caster.action_lock = now + CAST_LOCK; return true
            end

            -- HASTE II (ID 580)
            if not has_buff(c, 580) then
                qcmd(string.format('/mst %s /ma "Haste II" %s', caster.name, target_str))
                c.last_cast[580] = now; caster.action_lock = now + CAST_LOCK; return true
            end

            -- PROTECT V (ID 40)
            if not has_buff(c, 40) and (now - (c.last_cast[40] or 0) > 3000) then
                qcmd(string.format('/mst %s /ma "Protect V" %s', caster.name, target_str))
                c.last_cast[40] = now; caster.action_lock = now + CAST_LOCK; return true
            
            -- SHELL V (ID 41)
            elseif not has_buff(c, 41) and (now - (c.last_cast[41] or 0) > 3000) then
                qcmd(string.format('/mst %s /ma "Shell V" %s', caster.name, target_str))
                c.last_cast[41] = now; caster.action_lock = now + CAST_LOCK; return true
            end
        end
    end
end
ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os.clock()
    if not mm or mm:GetPlayer():GetIsZoning() ~= 0 or now < zone_lock then return end
    
    local party, ent = mm:GetParty(), mm:GetEntity()
    local goomy = chars[RDM_INDEX]
    
    local leaderTIdx = party:GetMemberTargetIndex(0)
    local currentMobID = 0
    local mainEngaged = (ent:GetStatus(leaderTIdx) == 1)

    if leaderTIdx ~= 0 and leaderTIdx < 2304 then 
        local leaderEntId = ent:GetServerId(leaderTIdx)
        if leaderEntId ~= 0 then currentMobID = leaderEntId end
    end

    -- Engage Mules
    for i, c in ipairs(chars) do
        if c.active and not c.is_guest and i ~= 1 then
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
            local pName = party:GetMemberName(p):lower()
            for _, c in ipairs(chars) do
                if pName == c.name_lower then 
                    c.job, c.sId, c.active = party:GetMemberMainJob(p), party:GetMemberServerId(p), true
                    break 
                end
            end
        end
    end

    -- Direct Goomy (Debuffs then Buffs)
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
                else goomy.done = true end
            end
        end
        handle_buffs(goomy, now)
    end

    -- Follow
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
                    imgui.TableNextColumn(); if i == RDM_INDEX then imgui.Checkbox('##D'..i, c.deb) else imgui.Text("-") end
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
