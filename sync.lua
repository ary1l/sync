addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '1.0'
addon.desc    = 'sync'

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- LUA / API OPTIMIZATIONS
------------------------------------------------------------
local AshitaCore  = AshitaCore
local mm          = AshitaCore:GetMemoryManager()
local chat        = AshitaCore:GetChatManager()
local pointer_mgr = AshitaCore:GetPointerManager()

local os_clock      = os.clock
local math_floor    = math.floor
local ipairs        = ipairs
local pairs         = pairs
local pcall         = pcall
local print         = print
local t_insert      = table.insert
local t_remove      = table.remove
local t_clear       = table.clear

local bit_lshift    = bit.lshift
local bit_rshift    = bit.rshift
local bit_band      = bit.band

local mem_read_u8   = ashita.memory.read_uint8
local mem_read_u32  = ashita.memory.read_uint32

local igBegin                = imgui.Begin
local igEnd                  = imgui.End
local igBeginTable           = imgui.BeginTable
local igEndTable             = imgui.EndTable
local igTableSetupColumn     = imgui.TableSetupColumn
local igTableNextRow         = imgui.TableNextRow
local igTableNextColumn      = imgui.TableNextColumn
local igTextColored          = imgui.TextColored
local igText                 = imgui.Text
local igTextDisabled         = imgui.TextDisabled
local igCheckbox             = imgui.Checkbox
local igSmallButton          = imgui.SmallButton
local igSetNextWindowBgAlpha = imgui.SetNextWindowBgAlpha

local COLOR_OFFLINE = {1.0, 0.2, 0.2, 1.0}
local COLOR_BUSY    = {1.0, 0.8, 0.0, 1.0}
local COLOR_GUEST   = {0.6, 0.9, 1.0, 1.0}
local COLOR_RECOVERING = {0.4, 0.6, 1.0, 1.0}

local SYNC_WINDOW_FLAGS = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoTitleBar)

local SYNC_WINDOW_OPEN  = {true}

------------------------------------------------------------
-- CONFIGURATION & DICTIONARIES
------------------------------------------------------------
local show_ui = true
local show_guests = true
local rep_dbg = false   -- toggle with /sync dbg (prints incoming /rdmhelper rep)

local ENGAGE_RETRY_GAP = 0.5
local RETRY_DELAY      = 0.7
local FOLLOW_SETTLE    = 0.5

local BUFF_IDS = {
    HASTE = 33, PROTECT = 40, SHELL = 41, REFRESH = 43,
    PHALANX = 116, FLURRY = 265, HASTE_SAMBA = 370, COMPOSURE = 419
}

local BUFF_ID_TO_KEY = {
    [BUFF_IDS.HASTE]       = 'h',
    [BUFF_IDS.FLURRY]      = 'fl',
    [BUFF_IDS.REFRESH]     = 'r',
    [BUFF_IDS.PHALANX]     = 'p',
    [BUFF_IDS.COMPOSURE]   = 'comp',
    [BUFF_IDS.PROTECT]     = 'pro',
    [BUFF_IDS.SHELL]       = 'sh',
    [BUFF_IDS.HASTE_SAMBA] = 'samba',
}

local silence_whitelist = {
    ["imp"] = true,
    ["eschan corse"] = true
}

local chars = {
    { name='shaymin',  is_main=true, f={false}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, fl={false}, ref={false} },
    { name='goomy',    is_rdm=true,  f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, fl={false}, ref={false} },
    { name='muunch',                 f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, fl={false}, ref={false} },
    { name='slowpoke',               f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, fl={false}, ref={false} },
    { name='dreepy',                 f={true},  e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, buf={false}, fl={false}, ref={false} },
}

local BUFF_PRIORITY = {"h","r","pro","sh","p"}
local RDM_SELF_FIRST = {"h","r"}
local COMBAT_FLAG_KEYS = {'e', 'hs', 'bs', 'qs', 'abs', 'deb', 'buf', 'fl', 'ref'}

local guests = {}
local current_active = {}
local known_cores = {}
local debuff_queue = {}
local slot_addr = {}

local cached_rdm  = nil
local cached_main = nil

local last_engage_target = 0

local ui_columns = {
    { label = 'F', key = 'f',   allow_main = false, rdm_only = false },
    { label = 'E', key = 'e',   allow_main = false, rdm_only = false },
    { label = 'H', key = 'hs',  allow_main = false, rdm_only = false },
    { label = 'B', key = 'bs',  allow_main = false, rdm_only = false },
    { label = 'Q', key = 'qs',  allow_main = false, rdm_only = false },
    { label = 'A', key = 'abs', allow_main = false, rdm_only = false },
    { label = 'D', key = 'deb', allow_main = false, rdm_only = true  },
    { label = 'B', key = 'buf', allow_main = true,  rdm_only = false }
}

local NUM_UI_COLS = #ui_columns

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
-- OPT 1: single constructor for the empty buff table (was duplicated 3x)
local function blank_buffs()
    return { h=false, r=false, p=false, fl=false, comp=false, pro=false, sh=false, samba=false }
end

local function get_debuff_queue(targetIdx)
    if not targetIdx or targetIdx == 0 then return {} end
    if not debuff_queue[targetIdx] then
        debuff_queue[targetIdx] = {
            { name="Silence",      done=false },
            { name="Dia III",      done=false },
            { name="Frazzle III",  done=false },
            { name="Distract III", done=false },
        }
    end
    return debuff_queue[targetIdx]
end

local BUFF_RETRY_GAP = 15.0
local RDM_FAST_CAST  = 0.50
local ANIMATION_LOCK = 2.75

local SPELL_CAST_TIMES = {
    ["Refresh III"] = 3.0,   ["Distract III"] = 3.0,
    ["Haste II"] = 3.0,      ["Phalanx II"] = 3.0,
    ["Flurry II"] = 3.0,
    ["Phalanx"] = 3.0,       ["Protect V"] = 3.0,
    ["Shell V"] = 3.0,       ["Silence"] = 3.0,
    ["Dia III"] = 2.5,       ["Frazzle III"] = 3.0,
}

local function get_cast_delay(spell)
    local base_time = SPELL_CAST_TIMES[spell] or 3.0
    return (base_time * (1.0 - RDM_FAST_CAST)) + ANIMATION_LOCK
end

local function _resolve_target(targ)
    return targ:GetTargetIndex(targ:GetIsSubTargetActive())
end

local function get_target_index(targ)
    if not targ then return 0 end
    local ok, idx = pcall(_resolve_target, targ)
    return (ok and idx and idx > 0) and idx or 0
end

local get_player_target = get_target_index

local function GetTargetOfTarget(targ, ent)
    if not ent then return 0 end
    local idx = get_target_index(targ)
    if idx == 0 then return 0 end
    local tot = ent:GetTargetedIndex(idx)
    return (tot and tot > 0) and tot or 0
end

------------------------------------------------------------
-- ENGAGE RETRY
------------------------------------------------------------
local function queue_retry(c, cmd, now)
    c.retry = { cmd = cmd, time = now + RETRY_DELAY, is_attack = cmd:find('/attack', 1, true) ~= nil }
end

local function process_retry(c, now, party, ent)
    local r = c.retry
    if not r or now < r.time then return end
    if r.is_attack then
        local pIdx   = c.pt_data and c.pt_data.index
        local entIdx = pIdx and party:GetMemberTargetIndex(pIdx) or 0
        local status = (entIdx > 0) and ent:GetStatus(entIdx) or 0
        if status ~= 1 then
            chat:QueueCommand(1, r.cmd)
        end
    else
        chat:QueueCommand(1, r.cmd)
    end
    c.retry = nil
end

------------------------------------------------------------
-- STATE UTILS
------------------------------------------------------------
local function qcmd(cmd, isFollow)
    if not isFollow then
        local player = mm:GetPlayer()
        if player and player:GetIsZoning() ~= 0 then return end
    end
    chat:QueueCommand(1, cmd)
end

local function do_action(c, cmd, lock_time, current_time)
    qcmd(c.mst_prefix .. cmd)
    c.action_lock = current_time + lock_time
end

local function init_char_state(c)
    c.name_lower = c.name:lower()
    c.disp_name  = c.name:sub(1,3):upper()
    c.mst_prefix = '/mst ' .. c.name .. ' '
    c.cmd_follow_on  = c.mst_prefix .. '/ms follow on'
    c.cmd_follow_off = c.mst_prefix .. '/ms follow off'
    c.cmd_attack_on  = c.mst_prefix .. '/attack [t]'
    c.cmd_attack_off = c.mst_prefix .. '/attack off'
    c.action_lock  = 0
    c.comp_lock    = 0
    c.convert_lock = 0
    c.buff_locks   = {}
    c.low_mp_mode  = false
    c.emergency_refresh = false
    c.in_zone      = false
    c.actual_follow = nil
    c.buffs = blank_buffs()  -- OPT 1
    c.last_rep_time = 0
    c.ui_ids = {}
    c.last_engage_target = 0
    c.last_engage_time   = 0
    c.auto_engaged       = false
    c.retry              = nil
    c.debuff_pause       = false
    c.fl  = c.fl  or {false}
    c.ref = c.ref or {false}
    for _, col in ipairs(ui_columns) do
        c.ui_ids[col.key] = '##' .. col.key .. '_' .. c.name_lower
    end
    if c.is_rdm  then cached_rdm  = c end
    if c.is_main then cached_main = c end
end

for _, c in ipairs(chars) do init_char_state(c); known_cores[c.name_lower] = true end

------------------------------------------------------------
-- RDM HELPER FUNCTIONS
------------------------------------------------------------
local function check_needs(t, key, rdm, now)
    -- 1. Initial validation checks
    if not t or not t.in_zone or not t.pt_data or not t.buf or not t.buf[1] then return false end

    local is_self = (t.name_lower == rdm.name_lower)

    -- 2. Composure check
    if key == 'comp' and rdm.buffs.comp then return false end

    -- 3. Cross-Party restrictions for Refresh (r) and Phalanx (p)
    if (key == 'r' or key == 'p') and not is_self then
        if not rdm.pt_data or not t.pt_data then return false end
        
        local rdm_party_group = math_floor(rdm.pt_data.index / 6)
        local t_party_group   = math_floor(t.pt_data.index / 6)
        
        if rdm_party_group ~= t_party_group then
            return false
        end
    end

    -- 4. Flurry conversion check
    local want = key
    if key == 'h' and t.fl and t.fl[1] then want = 'fl' end
    
    -- 5. Existing buff validation check
    if t.buffs and t.buffs[want] then return false end

    -- 6. Refresh whitelist logic
    if key == 'r' and not is_self and not (t.ref and t.ref[1]) then return false end

    -- 7. Action lock/Retry gap verification
    local locks = rdm.buff_locks[t.name]
    if not locks then locks = {}; rdm.buff_locks[t.name] = locks end
    if now - (locks[key] or 0) < BUFF_RETRY_GAP then return false end

    return true
end

------------------------------------------------------------
-- SCANNING
------------------------------------------------------------
-- OPT 2: shared reset for chars and guests (was two identical blocks)
local function reset_list_combat(list)
    for _, e in ipairs(list) do
        for _, key in ipairs(COMBAT_FLAG_KEYS) do if e[key] then e[key][1] = false end end
        e.last_engage_target = 0
        e.last_engage_time   = 0
        e.auto_engaged       = false
        e.retry              = nil
        e.debuff_pause       = false
    end
end

local function reset_combat_flags()
    reset_list_combat(chars)
    reset_list_combat(guests)
end

local function update_membership_and_zones(party)
    local my_zone = party:GetMemberZone(0)
    for _, v in pairs(current_active) do v.active_this_scan = false end
    for i = 0, 17 do
        local name = party:GetMemberName(i)
        if name and name ~= "" then
            local zId = party:GetMemberZone(i)
            local sId = party:GetMemberServerId(i)
            if sId ~= 0 and sId < 0x01000000 and party:GetMemberIsActive(i) ~= 0 and zId == my_zone then
                local nl = name:lower()
                local e = current_active[nl]
                if e then
                    e.index            = i
                    e.group            = math_floor(i / 6)
                    e.sId              = sId
                    e.active_this_scan = true
                else
                    current_active[nl] = {
                        index            = i,
                        group            = math_floor(i / 6),
                        sId              = sId,
                        active_this_scan = true,
                    }
                end
            end
        end
    end
    for k, v in pairs(current_active) do if not v.active_this_scan then current_active[k] = nil end end
    for _, c in ipairs(chars) do
        if not current_active[c.name_lower] then
            c.buffs = blank_buffs()  -- OPT 1
            c.in_zone = false
        end
    end
    for _, c in ipairs(chars) do c.pt_data = current_active[c.name_lower]; c.in_zone = (c.pt_data ~= nil) end
    for i = #guests, 1, -1 do
        guests[i].pt_data = current_active[guests[i].name_lower]
        if not guests[i].pt_data then t_remove(guests, i) else guests[i].in_zone = true end
    end
    for nl, data in pairs(current_active) do
        local known = known_cores[nl]
        if not known then for _, g in ipairs(guests) do if g.name_lower == nl then known = true; break end end end
        if not known then
            local g = { name = party:GetMemberName(data.index), buf = {false} }
            init_char_state(g); g.in_zone, g.pt_data = true, data
            t_insert(guests, g)
        end
    end
end

local function scan_buff_list(t, slot_addr, myNameL, player, now)
    for _, c in ipairs(t) do
        -- 1. REMOTE PROTECTIONS (Goomy, Slowpoke, Muunch)
        -- If they belong to Party 2 or 3 (indices 6-17), skip memory scan entirely.
        -- Only wipe if we haven't received a network packet from them in 15 seconds.
        if c.pt_data and c.pt_data.index >= 6 then
            if (now - c.last_rep_time) >= 15.0 then
                c.buffs = blank_buffs()  -- OPT 1
            end
            goto continue
        end

        -- 2. LOCAL PARTY A MEMORY SCANNING (Shaymin & Local Guests)
        if c.in_zone and c.pt_data and c.pt_data.index < 6 then
            c.buffs.h = false; c.buffs.r = false; c.buffs.p = false; c.buffs.fl = false
            c.buffs.comp = false; c.buffs.pro = false; c.buffs.sh = false; c.buffs.samba = false

            if c.name_lower == myNameL then
                local b = player:GetBuffs()
                for i = 0, 31 do
                    local k = BUFF_ID_TO_KEY[b[i]]
                    if k then c.buffs[k] = true end
                end
            else
                local m = slot_addr[c.pt_data.sId]
                if m then
                    local hi
                    for j = 0, 31 do
                        local low = mem_read_u8(m + 16 + j)
                        if low == 255 then break end
                        local bp = j % 4
                        if bp == 0 then hi = mem_read_u8(m + 8 + math_floor(j / 4)) end
                        local k = BUFF_ID_TO_KEY[bit_lshift(bit_band(bit_rshift(hi, bp * 2), 0x03), 8) + low]
                        if k then c.buffs[k] = true end
                    end
                end
            end
        end
        ::continue::
    end
end

local function scan_buffs(party, player, now)
    local ptr = pointer_mgr:Get('party.statusicons')
    if ptr == 0 then return end
    local buff_ptr = mem_read_u32(ptr)
    if buff_ptr == 0 then return end
    local myNameL = (party:GetMemberName(0) or ''):lower()

    t_clear(slot_addr)
    for slot = 0, 5 do
        local m = buff_ptr + (0x30 * slot)
        slot_addr[mem_read_u32(m)] = m
    end

    scan_buff_list(chars,  slot_addr, myNameL, player, now)
    scan_buff_list(guests, slot_addr, myNameL, player, now)
end

------------------------------------------------------------
-- GATE BROADCAST (sync -> rdmhelper instances)
------------------------------------------------------------
local GATE_BUF, GATE_FL, GATE_REF = 1, 2, 4

local function member_mask(c)
    if not (c.buf and c.buf[1]) then return 0 end
    local m = GATE_BUF
    if c.fl  and c.fl[1]  then m = m + GATE_FL  end
    if c.ref and c.ref[1] then m = m + GATE_REF end
    return m
end

local last_sent_mask = {}
local last_sent_deb  = nil
local last_keepalive = 0
local KEEPALIVE      = 10.0

local function broadcast_list(list, refresh)
    for _, c in ipairs(list) do
        local m = member_mask(c)
        if m ~= (last_sent_mask[c.name_lower] or 0) or (refresh and m > 0) then
            last_sent_mask[c.name_lower] = m
            qcmd('/mso /rdmhelper gate ' .. c.name_lower .. ' ' .. m, true)
        end
    end
end

local function broadcast_gates(now)
    local refresh = (now - last_keepalive >= KEEPALIVE)
    if refresh then last_keepalive = now end
    local deb_on = (cached_rdm and cached_rdm.deb[1]) or false
    if deb_on ~= last_sent_deb or (refresh and deb_on) then
        last_sent_deb = deb_on
        qcmd('/mso /rdmhelper deb ' .. (deb_on and 'on' or 'off'), true)
    end
    broadcast_list(chars,  refresh)
    broadcast_list(guests, refresh)
end

------------------------------------------------------------
-- MAIN SELF-REPORT (sync -> rdmhelper)
------------------------------------------------------------
local last_main_rep  = nil
local last_main_time = 0
local MAIN_REP_KEEPALIVE = 4.0

local function broadcast_main_report(now)
    local m = cached_main
    if not m or not m.in_zone then return end
    local b = m.buffs
    local flags = 0
    if b.h   then flags = flags + 1  end
    if b.fl  then flags = flags + 2  end
    if b.r   then flags = flags + 4  end
    if b.p   then flags = flags + 8  end
    if b.pro then flags = flags + 16 end
    if b.sh  then flags = flags + 32 end
    if flags ~= last_main_rep or now - last_main_time >= MAIN_REP_KEEPALIVE then
        last_main_rep  = flags
        last_main_time = now
        qcmd('/mso /rdmhelper rep ' .. m.name_lower .. ' ' .. flags, true)
    end
end

------------------------------------------------------------
-- CORE LOGIC
------------------------------------------------------------
local TICK_ACTION = 0.1
local TICK_SCAN   = 0.5
local lastTick, lastScanTick = 0, 0
local is_zoning_prev = false
local rdm_buff_idle_until = 0

ashita.events.register('d3d_present', 'logic_loop', function()
    local now = os_clock()
    if now - lastTick < TICK_ACTION then return end
    lastTick = now

    local player, party, ent = mm:GetPlayer(), mm:GetParty(), mm:GetEntity()
    if not player or not party or not ent then return end

    if player:GetIsZoning() ~= 0 then
        is_zoning_prev = true
        return
    elseif is_zoning_prev then
        reset_combat_flags()
        guests = {}; debuff_queue = {}
        last_engage_target = 0
        is_zoning_prev = false
    end

    if now - lastScanTick >= TICK_SCAN then
        update_membership_and_zones(party)
        scan_buffs(party, player, now)
        broadcast_gates(now)
        broadcast_main_report(now)
        lastScanTick = now
    end

    local rdm       = cached_rdm
    local main_char = cached_main
    local main_idx  = (main_char and main_char.pt_data)
                      and party:GetMemberTargetIndex(main_char.pt_data.index)
                      or  party:GetMemberTargetIndex(0)

    local main_is_attacking = (main_idx > 0 and ent:GetStatus(main_idx) == 1)

    local targ = mm:GetTarget()
    local engageTarget = 0
    if main_is_attacking then
        engageTarget = get_player_target(targ)
        if engageTarget == 0 then
            engageTarget = GetTargetOfTarget(targ, ent)
        end
    end

    if engageTarget ~= last_engage_target then
        debuff_queue = {}
        last_engage_target = engageTarget
    end

    local rdm_in_zone = rdm and rdm.in_zone and rdm.pt_data

    ------------------------------------------------------------
    -- RDM DEBUFF MOVEMENT PAUSE
    ------------------------------------------------------------
    if rdm then
        if not rdm_in_zone then
            rdm.debuff_pause = false
        elseif now > rdm.action_lock then
            local pause = false
            if rdm.deb[1] and not rdm.low_mp_mode and engageTarget > 0
            and ent:GetHPPercent(engageTarget) > 5 then
                local q = debuff_queue[engageTarget]
                if not q then
                    pause = true
                else
                    for _, d in ipairs(q) do
                        if not d.done then pause = true; break end
                    end
                end
            end
            if pause and not rdm.debuff_pause then
                rdm.action_lock = now + FOLLOW_SETTLE
            end
            rdm.debuff_pause = pause
        end
    end

    ------------------------------------------------------------
    -- RDM LOGIC
    ------------------------------------------------------------
    if rdm_in_zone and now > rdm.action_lock then
        local rdmIdx = rdm.pt_data.index
        local rdmMP  = party:GetMemberMP(rdmIdx) or 0

        local rdm_has_work = rdm.deb[1]
        if not rdm_has_work then
            for _, c in ipairs(chars)  do if c.buf and c.buf[1] and c.in_zone then rdm_has_work = true; break end end
        end
        if not rdm_has_work then
            for _, g in ipairs(guests) do if g.buf and g.buf[1] and g.in_zone then rdm_has_work = true; break end end
        end
        if not rdm_has_work then
            rdm.low_mp_mode = false
            rdm.emergency_refresh = false
            goto SKIP_RDM_BUFF
        end

        if rdmMP < 250 then
            if now > (rdm.convert_lock or 0) then
                rdm.convert_lock = now + 600.0
                do_action(rdm, '/ja "Convert" <me>', 1.5, now)
                rdm.emergency_refresh = true
                goto SKIP_RDM_BUFF
            end
            rdm.low_mp_mode = true
        elseif rdmMP >= 450 then
            rdm.low_mp_mode = false
        end

        if rdm.emergency_refresh then
            if rdm.buffs.r then
                rdm.emergency_refresh = false
            else
                rdm.buff_locks[rdm.name] = rdm.buff_locks[rdm.name] or {}
                local last_cast = rdm.buff_locks[rdm.name]['r'] or 0
                
                if now - last_cast >= BUFF_RETRY_GAP then
                    do_action(rdm, '/ma "Refresh III" <me>', get_cast_delay("Refresh III"), now)
                    rdm.buff_locks[rdm.name]['r'] = now
                end
            end
            goto SKIP_RDM_BUFF
        end

        if rdm.low_mp_mode then goto SKIP_RDM_BUFF end

        if rdm.deb[1] and engageTarget > 0 and ent:GetHPPercent(engageTarget) > 5 then
            local tNameL = (ent:GetName(engageTarget) or ""):lower()
            local q      = get_debuff_queue(engageTarget)

            for _, d in ipairs(q) do
                if not d.done then
                    if d.name == "Silence" and not silence_whitelist[tNameL] then
                        d.done = true
                    else
                        do_action(rdm, '/ma "' .. d.name .. '" [t]', get_cast_delay(d.name), now)
                        d.done = true; goto SKIP_RDM_BUFF
                    end
                end
            end
        end

        if now >= rdm_buff_idle_until then
            local bKey, bTarget = nil, nil
            
            for _, key in ipairs(RDM_SELF_FIRST) do
                if rdm.buf and rdm.buf[1] and check_needs(rdm, key, rdm, now) then 
                    bKey, bTarget = key, rdm; goto found 
                end
            end
            
            for _, key in ipairs(BUFF_PRIORITY) do
                for _, t in ipairs(chars)  do 
                    if t.buf and t.buf[1] and check_needs(t, key, rdm, now) then 
                        bKey, bTarget = key, t; goto found 
                    end 
                end
                for _, g in ipairs(guests) do 
                    if g.buf and g.buf[1] and check_needs(g, key, rdm, now) then 
                        bKey, bTarget = key, g; goto found 
                    end 
                end
            end
            ::found::

            if bKey and bTarget and rdmMP > 50 then
                if not rdm.buffs.comp and now > (rdm.comp_lock or 0) then
                    rdm.comp_lock = now + 295.0
                    do_action(rdm, '/ja "Composure" <me>', 1.5, now)
                    goto SKIP_RDM_BUFF
                end

                local is_self = (bTarget.name_lower == rdm.name_lower)
                local spell = "Haste II"
                if     bKey == 'r'   then spell = "Refresh III"
                elseif bKey == 'p'   then spell = is_self and "Phalanx" or "Phalanx II"
                elseif bKey == 'pro' then spell = "Protect V"
                elseif bKey == 'sh'  then spell = "Shell V" end
                if bKey == 'h' and bTarget.fl and bTarget.fl[1] then spell = "Flurry II" end

                rdm.buff_locks[bTarget.name]       = rdm.buff_locks[bTarget.name] or {}
                rdm.buff_locks[bTarget.name][bKey] = now

                local target_str = is_self and "<me>" or bTarget.name
                do_action(rdm, '/ma "' .. spell .. '" ' .. target_str, get_cast_delay(spell), now)
            else
                rdm_buff_idle_until = now + TICK_SCAN
            end
        end
    end
    ::SKIP_RDM_BUFF::

    ------------------------------------------------------------
    -- CHARACTER LOGIC
    ------------------------------------------------------------
    for _, c in ipairs(chars) do
        local rdm_detached = c.is_rdm and not rdm_in_zone
        if rdm_detached then
            c.actual_follow = nil
        end

        if not c.is_main then
            if not rdm_detached then
                local want_follow = c.f[1] and not c.debuff_pause
                if want_follow and c.actual_follow ~= true then
                    qcmd(c.cmd_follow_on, true)
                    c.actual_follow = true
                elseif not want_follow and c.actual_follow ~= false then
                    qcmd(c.cmd_follow_off, true)
                    c.actual_follow = false
                end
            end
            
            if c.in_zone and now > c.action_lock then
                local pIdx   = c.pt_data.index
                local entIdx = party:GetMemberTargetIndex(pIdx)
                if entIdx > 0 then
                    local is_attacking = (ent:GetStatus(entIdx) == 1)

                    if c.abs[1] and now > (c.abs_last or 0) + 30 then
                        c.abs_last = now
                        do_action(c, '/ma "Absorb-TP" Aminon', 1.5, now)
                    end

                    if c.e[1] then
                        if main_is_attacking and engageTarget > 0 then
                            local time_since = now - (c.last_engage_time or 0)
                            if (c.last_engage_target ~= engageTarget or not is_attacking)
                                and time_since >= ENGAGE_RETRY_GAP then
                                local cmd = c.cmd_attack_on
                                chat:QueueCommand(1, cmd)
                                queue_retry(c, cmd, now)
                                c.last_engage_target = engageTarget
                                c.auto_engaged       = true
                                c.last_engage_time   = now
                            end
                        elseif not main_is_attacking and c.auto_engaged then
                            if is_attacking then
                                chat:QueueCommand(1, c.cmd_attack_off)
                            end
                            c.last_engage_target = 0
                            c.auto_engaged       = false
                            c.last_engage_time   = 0
                            c.retry              = nil
                        end
                    elseif is_attacking then
                        chat:QueueCommand(1, c.cmd_attack_off)
                        c.auto_engaged = false
                        c.retry        = nil
                    end

                    if is_attacking then
                        local tp = party:GetMemberTP(pIdx)

                        if c.hs[1] and tp >= 350 and not c.buffs.samba then
                            do_action(c, '/ja "Haste Samba" <me>', 1.5, now)
                        end

                        if (c.bs[1] or c.qs[1]) and tp >= 100 and now > (c.step_last or 0) + 10 then
                            local s = (c.bs[1] and c.qs[1])
                                and (c.next_step == "Box Step" and "Quick Step" or "Box Step")
                                or  (c.bs[1] and "Box Step" or "Quick Step")
                            c.next_step, c.step_last = s, now
                            do_action(c, '/ja "' .. s .. '" <t>', 1.5, now)
                        end
                    end

                    process_retry(c, now, party, ent)
                end
            end
        end
    end
end)

------------------------------------------------------------
-- UI & COMMANDS
------------------------------------------------------------
local function draw(t, col, now)
    igTableNextRow(); igTableNextColumn()
    local c = not t.in_zone and COLOR_OFFLINE
        or (t.low_mp_mode and COLOR_RECOVERING)
        or (now <= t.action_lock and COLOR_BUSY or col)
    if c then igTextColored(c, t.disp_name) else igText(t.disp_name) end
    for _, v in ipairs(ui_columns) do
        igTableNextColumn()
        if not (t.is_main and not v.allow_main)
        and not (v.rdm_only and not t.is_rdm)
        and (col ~= COLOR_GUEST or v.key == 'buf') then
            igCheckbox(t.ui_ids[v.key], t[v.key])
        else igTextDisabled("-") end
    end
end

ashita.events.register('d3d_present', 'render_ui', function()
    if not show_ui then return end
    local now = os_clock()
    igSetNextWindowBgAlpha(0.4)
    if igBegin('Sync', SYNC_WINDOW_OPEN, SYNC_WINDOW_FLAGS) then
        if igBeginTable('SyncTable', NUM_UI_COLS + 1, 0) then
            igTableSetupColumn('Name', 0, 24)
            for _, col in ipairs(ui_columns) do igTableSetupColumn(col.label, 0, 22) end
            for _, c in ipairs(chars) do draw(c, nil, now) end
            if #guests > 0 then
                igTableNextRow()
                igTableNextColumn()
                if igSmallButton(show_guests and 'v' or '>') then
                    show_guests = not show_guests
                end
                for _ = 1, NUM_UI_COLS do igTableNextColumn() end
                if show_guests then
                    for _, g in ipairs(guests) do draw(g, COLOR_GUEST, now) end
                end
            end
            igEndTable()
        end
    end
    igEnd()
end)

local function set_flag(entry, cmd, state)
    if not (entry and entry[cmd]) then return end
    if state == nil then
        entry[cmd][1] = not entry[cmd][1]
    else
        entry[cmd][1] = state
    end
end

local function find_target(tr)
    for _, c in ipairs(chars)  do if c.name_lower:sub(1, #tr) == tr then return c end end
    for _, g in ipairs(guests) do if g.name_lower:sub(1, #tr) == tr then return g end end
    return nil
end

local function apply_command(cmd, tr, state)
    if not cmd then return end
    if tr == 'all' then
        local zone_gated = (cmd ~= 'f')
        local function affected(entry) return entry[cmd] and (not zone_gated or entry.in_zone) end

        local new_state = state
        if new_state == nil then
            for _, c in ipairs(chars)  do if affected(c) then new_state = not c[cmd][1]; break end end
            if new_state == nil then
                for _, g in ipairs(guests) do if affected(g) then new_state = not g[cmd][1]; break end end
            end
        end

        if new_state ~= nil then
            for _, c in ipairs(chars)  do if affected(c) then c[cmd][1] = new_state end end
            for _, g in ipairs(guests) do if affected(g) then g[cmd][1] = new_state end end
        end
    else
        set_flag(find_target(tr), cmd, state)
    end
end

ashita.events.register('command', 'sync_rdmhelper_listener', function(e)
    local cmd = e.command:lower()
    
    -- PREFIX MOOT MATCHING: Scan the entire raw string for the signature payload
    if not cmd:find('/rdmhelper rep', 1, true) then return end
    
    local _, _, name, flags_str = cmd:find('/rdmhelper rep (%S+) (%d+)')
    if name and flags_str then
        e.blocked = true
        local flags = tonumber(flags_str) or 0
        if name == "shaymin" then return end
        
        local t = nil
        for _, c in ipairs(chars)  do if c.name_lower == name then t = c; break end end
        if not t then for _, g in ipairs(guests) do if g.name_lower == name then t = g; break end end end

        if rep_dbg then
            print(('[sync] rep %s flags=%d match=%s')
                :format(name, flags, t and ((t.pt_data and t.pt_data.index) or '?') or 'NONE'))
        end
        
        if t then
            t.last_rep_time = os_clock()
            t.buffs.h    = (bit.band(flags, 1) > 0)
            t.buffs.fl   = (bit.band(flags, 2) > 0)
            t.buffs.r    = (bit.band(flags, 4) > 0)
            t.buffs.p    = (bit.band(flags, 8) > 0)
            t.buffs.pro  = (bit.band(flags, 16) > 0)
            t.buffs.sh   = (bit.band(flags, 32) > 0)
            t.buffs.comp = (bit.band(flags, 64) > 0) 
        end
    end
end)

local function log_hidden(cmd, tr)
    local label = (cmd == 'fl') and 'Flurry II' or 'Refresh III'
    if tr == 'all' then
        print('[sync] ' .. label .. ': all members updated')
    else
        local t = find_target(tr)
        if t and t[cmd] then
            print('[sync] ' .. label .. ' ' .. t.disp_name .. ': ' .. (t[cmd][1] and 'ON' or 'OFF'))
        end
    end
end

local presets = {
    on = {
        { 'buf', 'all',    true },
        { 'deb', 'goomy',  true },
        { 'e',   'all',    true },
        { 'bs',  'muunch', true },
        { 'hs',  'muunch', true },
    },
}

ashita.events.register('command', 'cmd_logic', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/sync' then return end
    e.blocked = true
    if #args == 1 then show_ui = not show_ui; return end

    local preset = presets[args[2]:lower()]
    if preset then
        for _, p in ipairs(preset) do apply_command(p[1], p[2], p[3]) end
        return
    end

    local a2, a3, a4 = args[2]:lower(), args[3] and args[3]:lower(), args[4] and args[4]:lower()
    if a2 == 'ui' then
        show_ui = (a3 == 'on') or (a3 ~= 'off' and not show_ui)
        return
    end

    if a2 == 'dbg' then
        rep_dbg = not rep_dbg
        print('[sync] rep debug ' .. (rep_dbg and 'ON' or 'OFF'))
        return
    end

    local cmds = { f='f', e='e', d='deb', buf='buf', b='buf', qs='qs', bs='bs',
                   abs='abs', hs='hs', fl='fl', ref='ref' }
    local cmd, tr, st
    if cmds[a2] then cmd, tr, st = cmds[a2], a3 or 'all', a4 else cmd, tr, st = a3 and cmds[a3], a2, a4 end

    local state = (st == 'on') and true or ((st == 'off') and false or nil)
    apply_command(cmd, tr, state)
    if cmd == 'fl' or cmd == 'ref' then log_hidden(cmd, tr) end
end)

ashita.events.register('load', 'sync_load', function()
    qcmd('/ms followme on', true)
    qcmd('/mso /ms follow on', true)
    qcmd('/mss /addon load rdmhelper', true)
    qcmd('/mss /rdmhelper clear', true)
end)

ashita.events.register('unload', 'sync_unload', function()
    qcmd('/mss /rdmhelper clear', true)
    qcmd('/ms followme off', true)
    qcmd('/mso /ms follow off', true)
    qcmd('/mss /addon unload rdmhelper', true)
end)
