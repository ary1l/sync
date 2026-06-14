addon.name    = 'rdmhelper'
addon.author  = 'aryl'
addon.version = '1.6'
addon.desc    = 'RDM Helper - Distributed Reporter'

require('common')
local bit = require('bit')

-- localized leaf calls (self via GetBuffs; guest slots via memory scan)
local bit_lshift   = bit.lshift
local bit_rshift   = bit.rshift
local bit_band     = bit.band
local mem_read_u8  = ashita.memory.read_uint8
local mem_read_u32 = ashita.memory.read_uint32
local math_floor   = math.floor
local os_clock     = os.clock

-- Crew roster -- MUST match sync.lua's `chars`. MAIN is the box running sync
-- that collects every report. Used to classify party members as crew vs guest
-- and to elect a single guest-reporter per detached alliance party.
local CREW = {
    shaymin  = true,
    goomy    = true,
    muunch   = true,
    slowpoke = true,
    dreepy   = true,
}
local MAIN = 'shaymin'

-- buff id -> report bit (same layout sync's rep handler decodes)
local BUFF_ID_TO_BIT = {
    [33]  = 1,    -- Haste
    [265] = 2,    -- Flurry
    [43]  = 4,    -- Refresh
    [116] = 8,    -- Phalanx
    [40]  = 16,   -- Protect
    [41]  = 32,   -- Shell
    [419] = 64,   -- Composure
}

local last_tick = 0
local dbg = false   -- toggle with /rdmhelper dbg (prints to THIS box's log)

-- Self buff flags from the player object.
local function self_flags(player)
    if not player then return 0 end
    local flags = 0
    local buffs = player:GetBuffs()
    for i = 0, 31 do
        local fb = BUFF_ID_TO_BIT[buffs[i]]
        if fb then flags = flags + fb end
    end
    return flags
end

-- Buff flags from a party status-icon block (address resolved by server id,
-- NOT by raw slot index -- the 6 blocks are not stored in party-slot order).
local function mem_flags(m)
    local flags = 0
    for j = 0, 31 do
        local low = mem_read_u8(m + 16 + j)
        if low == 255 then break end
        local bp = j % 4
        local hi = mem_read_u8(m + 8 + math_floor(j / 4))
        local fb = BUFF_ID_TO_BIT[bit_lshift(bit_band(bit_rshift(hi, bp * 2), 0x03), 8) + low]
        if fb then flags = flags + fb end
    end
    return flags
end

ashita.events.register('d3d_present', 'rdmhelper_loop', function()
    local now = os_clock()
    if now - last_tick < 1.0 then return end
    last_tick = now

    local mm = AshitaCore:GetMemoryManager()
    local party = mm and mm:GetParty()
    if not party then return end

    local my_name = party:GetMemberName(0)
    if not my_name or my_name == "" then return end
    local my_nl = my_name:lower()

    local player = mm:GetPlayer()

    -- buff table pointer -- gate matches the original (no reports while unready)
    local ptr = AshitaCore:GetPointerManager():Get('party.statusicons')
    if not ptr or ptr == 0 then return end
    local buff_ptr = mem_read_u32(ptr)
    if not buff_ptr or buff_ptr == 0 then return end

    -- Roster pass: name, server id, and ZONE for each local party slot.
    -- Zone matters because a member's buff block only exists in our status-icon
    -- table when they share our zone -- so only a co-zoned crew member can read
    -- a given guest. No buff memory is read here.
    local slot_nl, slot_sid, slot_zone = {}, {}, {}
    for slot = 0, 5 do
        local name = party:GetMemberName(slot)
        if name and name ~= "" and name ~= "\0" then
            local sid = party:GetMemberServerId(slot)
            if sid ~= 0 then
                slot_nl[slot]   = name:lower()
                slot_sid[slot]  = sid
                slot_zone[slot] = party:GetMemberZone(slot)
            end
        end
    end

    -- Elected reporter for a zone: the alphabetically-first non-main crew member
    -- in this party who is IN that zone (and can therefore actually read it).
    -- Every box sees the same zones, so all boxes elect the same reporter, and
    -- that reporter is guaranteed co-zoned with the guest. This also dedupes when
    -- several crew share the guest's party+zone -- only the first relays.
    local function reporter_for(zone)
        local r = nil
        for s = 0, 5 do
            local nl = slot_nl[s]
            if nl and CREW[nl] and nl ~= MAIN and slot_zone[s] == zone then
                if not r or nl < r then r = nl end
            end
        end
        return r
    end

    -- Lazy server-id -> block map (only built when we actually read a guest).
    local addr_by_sid = nil
    local function block_for(sid)
        if not addr_by_sid then
            addr_by_sid = {}
            for s = 0, 5 do
                local m = buff_ptr + (0x30 * s)
                addr_by_sid[mem_read_u32(m)] = m
            end
        end
        return addr_by_sid[sid]
    end

    if dbg then
        local r = {}
        for s = 0, 5 do if slot_nl[s] then r[#r + 1] = slot_nl[s] end end
        print(('[rdmhelper] %s party=[%s]'):format(my_nl, table.concat(r, ',')))
        for s = 0, 5 do
            local nl = slot_nl[s]
            if nl then
                local info
                if s == 0 then
                    info = 'self flags=' .. self_flags(player)
                elseif CREW[nl] then
                    info = 'crew (self-reports)'
                else
                    local m = block_for(slot_sid[s])
                    info = ('guest zone=%d rep=%s block=%s flags=%d'):format(
                        slot_zone[s] or -1, tostring(reporter_for(slot_zone[s])),
                        m and 'OK' or 'MISS', m and mem_flags(m) or 0)
                end
                print(('[rdmhelper]   slot%d %s sid=%d %s'):format(s, nl, slot_sid[s], info))
            end
        end
    end

    local chat = AshitaCore:GetChatManager()

    -- 1. SELF REPORT (always) -- every crew box reports its own buffs.
    if slot_nl[0] then
        chat:QueueCommand(1, '/mst shaymin /rdmhelper rep ' .. my_nl .. ' ' .. self_flags(player))
    end

    -- 2. GUEST RELAY -- relay each non-crew member I'm the co-zoned elected
    -- reporter for. Crew self-report (slot 0 above + their own boxes), so they're
    -- skipped here.
    for slot = 1, 5 do
        local nl = slot_nl[slot]
        if nl and not CREW[nl] and reporter_for(slot_zone[slot]) == my_nl then
            local m = block_for(slot_sid[slot])
            if m then
                chat:QueueCommand(1, '/mst shaymin /rdmhelper rep ' .. nl .. ' ' .. mem_flags(m))
            end
        end
    end
end)

ashita.events.register('command', 'rdmhelper_cmd', function(e)
    local args = e.command:args()
    if not args or args[1] ~= '/rdmhelper' then return end
    if args[2] == 'rep' then return end
    if args[2] == 'dbg' then
        dbg = not dbg
        print('[rdmhelper] debug ' .. (dbg and 'ON' or 'OFF'))
        e.blocked = true
        return
    end
    e.blocked = true
end)