addon.name    = 'rdmhelper'
addon.author  = 'aryl'
addon.version = '1.0'
addon.desc    = 'RDM Helper - Distributed Reporter'

require('common')
local bit = require('bit')

-- localized leaf calls (self via GetBuffs; guest slots via memory scan)
local bit_lshift   = bit.lshift
local bit_rshift   = bit.rshift
local bit_band     = bit.band
local bit_bor      = bit.bor
local mem_read_u8  = ashita.memory.read_uint8
local mem_read_u32 = ashita.memory.read_uint32
local math_floor   = math.floor
local os_clock     = os.clock

local AshitaCore  = AshitaCore
local mm          = AshitaCore:GetMemoryManager()
local chat        = AshitaCore:GetChatManager()
local pointer_mgr = AshitaCore:GetPointerManager()

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

local REP_PREFIX = '/mst ' .. MAIN .. ' /rdmhelper rep '

-- buff id -> report bit (same layout sync's rep handler decodes)
local BUFF_ID_TO_BIT = {
    [33]  = 1,    -- Haste
    [265] = 2,    -- Flurry
    [43]  = 4,    -- Refresh
    [116] = 8,    -- Phalanx
    [40]  = 16,   -- Protect
    [41]  = 32,   -- Shell
    [419] = 64,   -- Composure
	[113] = 2048, -- Reraise
    -- Healer stances -- reported so sync can gate them cross-party (no re-fire
    -- when a detached healer already has the stance up). MUST match sync's decode.
    [358] = 128,  -- Light Arts
    [401] = 256,  -- Addendum: White
    [417] = 512,  -- Afflatus Solace
    [621] = 1024, -- Majesty (PLD)
}

-- removable detrimental status id -> report bit. MUST stay identical to sync's
-- STATUS_ID_TO_BIT. Bits 1..128 are dedicated -na ailments; bit 256 is the
-- aggregate "an Erase-removable effect is present".
local STATUS_ID_TO_BIT = {
    [3]  = 1,    -- Poison        -> Poisona
    [4]  = 2,    -- Paralysis     -> Paralyna
    [5]  = 4,    -- Blindness     -> Blindna
    [6]  = 8,    -- Silence       -> Silena
    [7]  = 16,   -- Petrification -> Stona
    [8]  = 32,   -- Disease       -> Viruna
    [31] = 32,   -- Plague        -> Viruna
    [9]  = 64,   -- Curse         -> Cursna
    [15] = 128,  -- Doom          -> Cursna
    -- Special-case bits (NOT -na/Erase removable):
    [14] = 512,  -- Charm
    [17] = 512,  -- Charm (II)
    [2]  = 1024, -- Sleep
    [19] = 1024, -- Sleep (II)
    [193] = 1024, -- Lullaby  
}
-- Every Erase-removable status id collapses to bit 256.
local ERASE_BIT = 256
local ERASE_IDS = {
    11,  -- Bind        
    12,  -- Weight
    13,  -- Slow
    21,  -- Addle
    128, -- Burn
    129, -- Frost
    130, -- Choke
    131, -- Rasp
    132, -- Shock
    133, -- Drown
    134, -- Dia
    135, -- Bio
    136, -- STR Down
    137, -- DEX Down
    138, -- VIT Down
    139, -- AGI Down
    140, -- INT Down
    141, -- MND Down
    142, -- CHR Down
    144, -- Max HP Down
    145, -- Max MP Down
    146, -- Accuracy Down
    147, -- Attack Down
    148, -- Evasion Down
    149, -- Defense Down
    156, -- Flash
    167, -- Magic Def Down
    174, -- Magic Acc Down
    175, -- Magic Atk Down
    186, -- Helix
    189, -- Max TP Down
    192, -- Requiem
    194, -- Elegy
    298, -- Critical Hit Evasion Down
    404, -- Magic Evasion Down
}
for _, id in ipairs(ERASE_IDS) do STATUS_ID_TO_BIT[id] = ERASE_BIT end

local last_tick = 0

local REPORT_KEEPALIVE = 3.0
local self_sig, self_emit = nil, 0
local guest_sig, guest_emit = {}, {}

-- Single emitter for a report line -- centralizes the wire format so the
-- two senders (self report + guest relay) cannot drift.
local function report(name, bflags, sflags, mjob, sjob, sjlvl)
    chat:QueueCommand(1, REP_PREFIX .. name .. ' ' .. bflags .. ' ' .. sflags .. ' ' .. mjob .. ' ' .. sjob .. ' ' .. sjlvl)
end

local function report_self(name, b, s, mj, sj, sl, now)
    local sig = b .. ' ' .. s .. ' ' .. mj .. ' ' .. sj .. ' ' .. sl
    if sig ~= self_sig or (now - self_emit) >= REPORT_KEEPALIVE then
        self_sig, self_emit = sig, now
        report(name, b, s, mj, sj, sl)
    end
end

local function report_guest(name, b, s, now)
    local sig = b .. ' ' .. s
    if sig ~= guest_sig[name] or (now - (guest_emit[name] or 0)) >= REPORT_KEEPALIVE then
        guest_sig[name], guest_emit[name] = sig, now
        report(name, b, s, 0, 0, 0)
    end
end

local function self_scan(player)
    if not player then return 0, 0 end
    local flags, bits = 0, 0
    local buffs = player:GetBuffs()
    for i = 0, 31 do
        local id = buffs[i]
        local fb = BUFF_ID_TO_BIT[id]
        if fb then flags = bit_bor(flags, fb) end
        local sb = STATUS_ID_TO_BIT[id]
        if sb then bits = bit_bor(bits, sb) end
    end
    return flags, bits
end

local function mem_scan(m)
    local flags, bits = 0, 0
    local hi
    for j = 0, 31 do
        local low = mem_read_u8(m + 16 + j)
        if low == 255 then break end
        local bp = j % 4
        if bp == 0 then hi = mem_read_u8(m + 8 + math_floor(j / 4)) end
        local id = bit_lshift(bit_band(bit_rshift(hi, bp * 2), 0x03), 8) + low
        local fb = BUFF_ID_TO_BIT[id]
        if fb then flags = bit_bor(flags, fb) end
        local sb = STATUS_ID_TO_BIT[id]
        if sb then bits = bit_bor(bits, sb) end
    end
    return flags, bits
end

ashita.events.register('d3d_present', 'rdmhelper_loop', function()
    local now = os_clock()
    if now - last_tick < 1.0 then return end
    last_tick = now

    local party = mm and mm:GetParty()
    if not party then return end

    local my_name = party:GetMemberName(0)
    if not my_name or my_name == "" then return end
    local my_nl = my_name:lower()

    local player = mm:GetPlayer()

    -- buff table pointer -- gate matches the original (no reports while unready)
    local ptr = pointer_mgr:Get('party.statusicons')
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

    -- 1. SELF REPORT -- every crew box reports its own buffs, EXCEPT the main box.
    if slot_nl[0] and my_nl ~= MAIN then
        local bf, sf = self_scan(player)
        report_self(my_nl, bf, sf,
               player:GetMainJob() or 0, player:GetSubJob() or 0, player:GetSubJobLevel() or 0, now)
    end

    -- 2. GUEST RELAY -- relay each non-crew member that they are the co-zoned elected
    -- reporter for. Crew self-report (slot 0 above + their own boxes), so they're
    -- skipped here.
    for slot = 1, 5 do
        local nl = slot_nl[slot]
        if nl and not CREW[nl] and reporter_for(slot_zone[slot]) == my_nl then
            local m = block_for(slot_sid[slot])
            if m then
                local bf, sf = mem_scan(m)
                report_guest(nl, bf, sf, now)
            end
        end
    end
end)

ashita.events.register('command', 'rdmhelper_cmd', function(e)
    local args = e.command:args()
    if not args or args[1] ~= '/rdmhelper' then return end
    if args[2] == 'rep' then return end   -- our report verb; sync consumes it on the main box, ignored elsewhere
    if args[2] == 'crew' then
        -- Roster push from sync. args[3] = MAIN (the sync box); args[3..] = full crew.
        if args[3] then
            CREW = {}
            for i = 3, #args do CREW[args[i]:lower()] = true end
            MAIN = args[3]:lower()
            REP_PREFIX = '/mst ' .. MAIN .. ' /rdmhelper rep '
            self_sig, self_emit = nil, 0
            guest_sig, guest_emit = {}, {}
        end
        e.blocked = true
        return
    end
end)
