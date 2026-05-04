addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '.050326_v16.1'
addon.desc    = 'sync'
require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- LUA OPTIMIZATIONS & CONSTANTS
------------------------------------------------------------
local os_clock      = os.clock
local math_sqrt      = math.sqrt
local math_floor    = math.floor
local string_format = string.format
local bit_lshift    = bit.lshift
local bit_rshift    = bit.rshift
local bit_band      = bit.band

local TICK_ACTION   = 0.1
local TICK_SCAN     = 0.5
local UI_INTERVAL   = 0.06 
local lastTick, lastScanTick, lastUIRender = 0, 0, 0

local BUFF_IDS = { HASTE = 33, PROTECT = 40, SHELL = 41, REFRESH = 43, PHALANX = 116, COMPOSURE = 419 }
local BUFF_RETIMER = { r=300, h=270, p=270, pro=3300, sh=3300, comp=3600 }
local BUFF_RETRY_GAP = 9.0
local RDM_FAST_CAST  = 0.50
local ANIMATION_LOCK = 2.3

local SPELL_CAST_TIMES = {
    ["Refresh III"] = 3.0, ["Refresh"] = 3.0, ["Haste II"] = 3.0,
    ["Phalanx II"] = 3.0, ["Phalanx"] = 3.0, ["Protect V"] = 3.0,
    ["Shell V"] = 3.0, ["Silence"] = 3.0, ["Dia III"] = 2.5,
    ["Frazzle III"] = 3.0, ["Distract III"] = 3.0,
}

local refresh_jobs = { [3]=true, [4]=true, [5]=true, [7]=true, [8]=true, [15]=true, [16]=true, [21]=true, [22]=true }
local silence_whitelist = { ["imp"] = true, ["eschan corse"] = true }

local chars = {
    { name='shaymin',  is_main=true, f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='goomy',    is_rdm=true,  f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='muunch',                 f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
    { name='slowpoke',               f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false} },
}

local guests, buff_cache, debuff_queue, known_cores, index_map = {}, {}, {}, {}, {}
local show_ui, is_zoning_prev = true, false

local ui_columns = {
    { label = 'F',  key = 'f',   allow_main = false, rdm_only = false },
    { label = 'E',  key = 'e',   allow_main = false, rdm_only = false },
    { label = 'HS', key = 'hs',  allow_main = false, rdm_only = false },
    { label = 'BS', key = 'bs',  allow_main = false, rdm_only = false },
    { label = 'QS', key = 'qs',  allow_main = false, rdm_only = false },
    { label = 'Ab', key = 'abs', allow_main = false, rdm_only = false },
    { label = 'De', key = 'deb', allow_main = false, rdm_only = true  },
    { label = 'Bu', key = 'buf', allow_main = true,  rdm_only = false }
}

------------------------------------------------------------
-- HELPERS & STATE
------------------------------------------------------------
local function init_char_state(c)
    c.name_lower = c.name:lower()
    c.disp_name = c.name:sub(1,5):upper()
    c.action_lock, c.comp_lock, c.step_last = 0, 0, 0
    c.buff_locks, c.buffs = {}, { h=false, r=false, p=false, comp=false, pro=false, sh=false }
    c.ui_ids = {}
    for _, col in ipairs(ui_columns) do c.ui_ids[col.key] = '##' .. col.label .. '_' .. c.name_lower end
end

for _, c in ipairs(chars) do init_char_state(c); known_cores[c.name_lower]=true end

local function get_cache(t)
    if not t or not t.name_lower then return {} end
    buff_cache[t.name_lower] = buff_cache[t.name_lower] or {r=0, h=0, p=0, pro=0, sh=0, comp=0}
    return buff_cache[t.name_lower]
end

local function get_debuff_queue(name)
    if not name or name == "" then return {} end
    if not debuff_queue[name] then
        debuff_queue[name] = {
            { name="Silence", done=false }, { name="Dia III", done=false },
            { name="Frazzle III", done=false }, { name="Distract III", done=false },
        }
    end
    return debuff_queue[name]
end

local function get_cast_delay(spell)
    return ((SPELL_CAST_TIMES[spell] or 3.0) * (1.0 - RDM_FAST_CAST)) + ANIMATION_LOCK
end

local function get_yalms(entIdx, ent)
    if not entIdx or entIdx == 0 then return 999 end
    local dSq = ent:GetDistance(entIdx)
    return dSq and math_sqrt(dSq) or 999
end

local qcmd = function(cmd, isFollow)
    if not isFollow and AshitaCore:GetMemoryManager():GetPlayer():GetIsZoning() ~= 0 then return end
    AshitaCore:GetChatManager():QueueCommand(1, cmd)
end

local function do_action(c, cmd, lock_time, current_time, stop_movement)
    if stop_movement and c.f[1] and c.actual_follow ~= false then
        qcmd(string_format('/mst %s /ms follow off', c.name), true)
        c.actual_follow = false
    end
    qcmd(string_format('/mst %s %s', c.name, cmd))
    c.action_lock = current_time + lock_time
end

------------------------------------------------------------
-- SCANNING & LOGIC
------------------------------------------------------------
local function update_membership_and_zones(party)
    local my_zone = party:GetMemberZone(0)
    index_map = {}
    for i = 0, 17 do
        local name = party:GetMemberName(i)
        if name and name ~= "" and party:GetMemberIsActive(i) ~= 0 and party:GetMemberZone(i) == my_zone then
            local nl = name:lower()
            index_map[nl] = { index=i, job=party:GetMemberMainJob(i), sId=party:GetMemberServerId(i) }
        end
    end
    for _, c in ipairs(chars) do c.pt_data = index_map[c.name_lower]; c.in_zone = (c.pt_data ~= nil) end
    for i = #guests, 1, -1 do
        guests[i].pt_data = index_map[guests[i].name_lower]
        if not guests[i].pt_data then table.remove(guests, i) else guests[i].in_zone = true end
    end
    for nl, data in pairs(index_map) do
        if not known_cores[nl] then
            local already_guest = false
            for _, g in ipairs(guests) do if g.name_lower == nl then already_guest = true break end end
            if not already_guest then
                local g = { name = party:GetMemberName(data.index), buf = {false} }
                init_char_state(g); g.in_zone, g.pt_data = true, data
                table.insert(guests, g)
            end
        end
    end
end

local function scan_buffs(t, party, player)
    local ptr = AshitaCore:GetPointerManager():Get('party.statusicons')
    if ptr == 0 then return end
    local buff_ptr = ashita.memory.read_uint32(ptr)
    if buff_ptr == 0 then return end
    local myNameL = (party:GetMemberName(0) or ''):lower()

    for _, c in ipairs(t) do
        if not c.in_zone then goto skip end
        c.buffs = { h=false, r=false, p=false, comp=false, pro=false, sh=false }
        if c.name_lower == myNameL then
            local b = player:GetBuffs()
            for i=0,31 do
                local id = b[i]
                if id == BUFF_IDS.HASTE then c.buffs.h=true
                elseif id == BUFF_IDS.REFRESH then c.buffs.r=true
                elseif id == BUFF_IDS.PHALANX then c.buffs.p=true
                elseif id == BUFF_IDS.COMPOSURE then c.buffs.comp=true
                elseif id == BUFF_IDS.PROTECT then c.buffs.pro=true
                elseif id == BUFF_IDS.SHELL then c.buffs.sh=true end
            end
        elseif c.pt_data and c.pt_data.index <= 5 then
            for slot=0,5 do
                local m = buff_ptr + (0x30 * slot)
                if ashita.memory.read_uint32(m) == c.pt_data.sId then
                    for j=0,31 do
                        local low = ashita.memory.read_uint8(m + 16 + j)
                        if low == 255 then break end
                        local id = (bit_lshift(bit_band(bit_rshift(ashita.memory.read_uint8(m + 8 + math_floor(j/4)), (j%4)*2), 0x03), 8)) + low
                        if id == BUFF_IDS.HASTE then c.buffs.h=true
                        elseif id == BUFF_IDS.REFRESH then c.buffs.r=true
                        elseif id == BUFF_IDS.PHALANX then c.buffs.p=true
                        elseif id == BUFF_IDS.COMPOSURE then c.buffs.comp=true
                        elseif id == BUFF_IDS.PROTECT then c.buffs.pro=true
                        elseif id == BUFF_IDS.SHELL then c.buffs.sh=true end
                    end
                    break
                end
            end
        end
        ::skip::
    end
end

ashita.events.register('d3d_present', 'logic_loop', function()
    local now = os_clock()
    if now - lastTick < TICK_ACTION then return end
    lastTick = now

    local mm = AshitaCore:GetMemoryManager()
    local player, party, ent = mm:GetPlayer(), mm:GetParty(), mm:GetEntity()
    if not player or not party or not ent then return end

    if player:GetIsZoning() ~= 0 then is_zoning_prev = true return 
    elseif is_zoning_prev then guests, buff_cache, debuff_queue, is_zoning_prev = {}, {}, {}, false end

    if now - lastScanTick >= TICK_SCAN then
        update_membership_and_zones(party)
        scan_buffs(chars, party, player); scan_buffs(guests, party, player)
        lastScanTick = now
    end

    local rdm = nil
    for _, c in ipairs(chars) do if c.is_rdm then rdm = c break end end
    local main_idx = index_map['shaymin'] and party:GetMemberTargetIndex(index_map['shaymin'].index) or party:GetMemberTargetIndex(0)
    local engageTarget = (main_idx > 0 and ent:GetStatus(main_idx) == 1) and ent:GetTargetedIndex(main_idx) or 0

    ------------------------------------------------------------
    -- RDM LOGIC
    ------------------------------------------------------------
    if rdm and rdm.in_zone and now > rdm.action_lock then
        local rdmIdx = rdm.pt_data.index
        local rdmMP = party:GetMemberMP(rdmIdx)
        if rdmMP < 200 then rdm.low_mp_mode = true elseif rdmMP >= 450 then rdm.low_mp_mode = false end
        if rdm.low_mp_mode then goto SKIP_RDM end

        -- Debuffs
        if rdm.deb[1] and engageTarget > 0 and ent:GetHPPercent(engageTarget) > 5 then
            local tName = ent:GetName(engageTarget)
            local q = get_debuff_queue(tName and tName:lower() or "")
            if get_yalms(engageTarget, ent) < 21.0 then
                for _, d in ipairs(q) do
                    if not d.done then
                        if d.name == "Silence" and not silence_whitelist[tName:lower()] then d.done = true
                        else
                            do_action(rdm, string_format('/ma "%s" <t>', d.name), get_cast_delay(d.name), now, true)
                            d.done = true; goto SKIP_RDM
                        end
                    end
                end
            end
        end

        local function check_needs(t, key)
            if not t or not t.in_zone or not t.buf[1] then return false end
            local cache = get_cache(t)
            local is_in_lead_party = (math_floor(t.pt_data.index / 6) == math_floor(index_map['shaymin'].index / 6))
            
            if is_in_lead_party then
                if t.buffs[key] then cache[key] = now + BUFF_RETIMER[key] return false end
            else
                if cache[key] and now < cache[key] then return false end
            end

            local tEntIdx = party:GetMemberTargetIndex(t.pt_data.index)
            if tEntIdx > 0 and not (t.is_rdm or get_yalms(tEntIdx, ent) < 21.0) then return false end
            if key == 'r' and (math_floor(rdmIdx/6) ~= math_floor(t.pt_data.index/6) or not refresh_jobs[t.pt_data.job]) then return false end
            if key == 'p' and math_floor(rdmIdx/6) ~= math_floor(t.pt_data.index/6) then return false end
            
            rdm.buff_locks[t.name] = rdm.buff_locks[t.name] or {}
            if now - (rdm.buff_locks[t.name][key] or 0) < BUFF_RETRY_GAP then return false end
            return true
        end

        local bKey, bTarget = nil, nil
        for _, key in ipairs({"h","r","pro","sh","p"}) do
            for _, t in ipairs(chars) do if check_needs(t, key) then bKey, bTarget = key, t goto found end end
            for _, g in ipairs(guests) do if check_needs(g, key) then bKey, bTarget = key, g goto found end end
        end
        ::found::

        if bKey and bTarget and rdmMP > 50 then
            local rdmCache = get_cache(rdm)
            if not (rdm.buffs.comp or (rdmCache.comp and now < rdmCache.comp)) then
                if now > rdm.comp_lock then
                    rdm.comp_lock, rdmCache.comp = now + 5.0, now + 3600
                    do_action(rdm, '/ja "Composure" <me>', 1.5, now, false)
                end
            else
                local spell = ({h="Haste II", r="Refresh III", p=(bTarget==rdm and "Phalanx" or "Phalanx II"), pro="Protect V", sh="Shell V"})[bKey]
                rdm.buff_locks[bTarget.name][bKey] = now
                if math_floor(bTarget.pt_data.index/6) ~= math_floor(index_map['shaymin'].index/6) then
                    get_cache(bTarget)[bKey] = now + BUFF_RETIMER[bKey]
                end
                do_action(rdm, string_format('/ma "%s" %s', spell, bTarget==rdm and "<me>" or bTarget.name), get_cast_delay(spell), now, false)
            end
        end
    end
    ::SKIP_RDM::

    -- Step Logic
    for _, c in ipairs(chars) do
        if not c.is_main and c.in_zone and now > c.action_lock then
            local entIdx = party:GetMemberTargetIndex(c.pt_data.index)
            if entIdx > 0 and ent:GetStatus(entIdx) == 1 then
                local tp, dist = party:GetMemberTP(c.pt_data.index), get_yalms(engageTarget, ent)
                if (c.bs[1] or c.qs[1]) and tp >= 100 and dist < 6.0 and now > (c.step_last or 0) + 10 then
                    local s = (c.bs[1] and c.qs[1]) and (c.next_step == "Box Step" and "Quick Step" or "Box Step") or (c.bs[1] and "Box Step" or "Quick Step")
                    c.next_step, c.step_last = s, now
                    do_action(c, string_format('/ja "%s" <t>', s), 1.5, now, false)
                end
            end
        end
    end
end)

------------------------------------------------------------
-- UI RENDERING (THROTTLED)
------------------------------------------------------------
ashita.events.register('d3d_present', 'render_ui', function()
    local now = os_clock()
    if not show_ui or (now - lastUIRender < UI_INTERVAL) then return end
    lastUIRender = now

    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {2, 2})
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {2, 2})
    if imgui.Begin('Sync', {true}, bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)) then
        if imgui.BeginTable('SyncTable', #ui_columns + 1, bit.bor(ImGuiTableFlags_Borders, ImGuiTableFlags_RowBg)) then
            imgui.TableSetupColumn('Name', 0, 50)
            for _, col in ipairs(ui_columns) do imgui.TableSetupColumn(col.label, 0, 18) end
            imgui.TableHeadersRow()
            local function draw(t, tint)
                imgui.TableNextRow(); imgui.TableNextColumn()
                local c = not t.in_zone and {1,0.2,0.2,1} or (t.low_mp_mode and {0.4,0.6,1,1}) or (os_clock() <= t.action_lock and {1,0.8,0,1} or tint)
                if c then imgui.TextColored(c, t.disp_name) else imgui.Text(t.disp_name) end
                for _, v in ipairs(ui_columns) do
                    imgui.TableNextColumn()
                    if not (t.is_main and not v.allow_main) and not (v.rdm_only and not t.is_rdm) and (not tint or v.key == 'buf') then
                        imgui.Checkbox(t.ui_ids and t.ui_ids[v.key] or ('##'..v.label..'_'..t.name_lower), t[v.key])
                    else imgui.TextDisabled("-") end
                end
            end
            for _, c in ipairs(chars) do draw(c, nil) end
            for _, g in ipairs(guests) do draw(g, {0.6,0.9,1,1}) end
            imgui.EndTable()
        end
    end
    imgui.End(); imgui.PopStyleVar(2)
end)

-- Command logic and Load logic from v16 remains unchanged
ashita.events.register('command', 'cmd_logic', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/sync' then return end
    e.blocked = true
    if #args == 1 then show_ui = not show_ui return end
    local cmds = { f='f', e='e', deb='deb', buf='buf', b='buf', qs='qs', bs='bs', abs='abs', hs='hs' }
    local a2, a3, a4 = args[2]:lower(), args[3] and args[3]:lower(), args[4] and args[4]:lower()
    local cmd, tr, st
    if cmds[a2] then cmd, tr, st = cmds[a2], a3 or 'all', a4 else cmd, tr, st = a3 and cmds[a3], a2, a4 end
    if tr == 'ui' then show_ui = (st == 'on') or (not st and not show_ui) return end
    local state = (st == 'on') and true or ((st == 'off') and false or nil)
    local target = tr == 'all' and 'all' or nil
    if not target then
        for _, c in ipairs(chars) do if c.name_lower:sub(1,#tr) == tr then target = c break end end
        if not target then for _, g in ipairs(guests) do if g.name_lower:sub(1,#tr) == tr then target = g break end end end
    end
    if target == 'all' then
        for _, c in ipairs(chars) do if c[cmd] then c[cmd][1] = (state == nil) and (not c[cmd][1]) or state end end
        for _, g in ipairs(guests) do if g[cmd] then g[cmd][1] = (state == nil) and (not g[cmd][1]) or state end end
    elseif target and target[cmd] then target[cmd][1] = (state == nil) and (not target[cmd][1]) or state end
end)

ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on', true)
    qcmd('/mso /ms follow on', true)
end)
