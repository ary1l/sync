-- sync v2.0
addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '2.0'
addon.desc    = 'multisend leverager'

require('common')
local imgui = require('imgui')

-- Localize for performance
local os_clock = os_clock
local string_format = string.format

------------------------------------------------------------
-- State & Constants
------------------------------------------------------------
local ui_open = { true }
local TICK_INTERVAL = 0.3
local lastTick = 0

local HS_TP_THRESHOLD   = 350
local HS_COOLDOWN       = 80.0  
local STEP_TP_THRESHOLD = 100
local STEP_COOLDOWN     = 10.0

local ABSTP_RECAST_WAIT = 15.0  
local ABSTP_RETRY_DELAY = 2.0   

local DEBUFF_RETRY_DELAY = 2.5
local DEBUFF_STUCK_TIME  = 10.0 

local debuff_sequence = {
    { name = "Dia III",      id = 221 },
    { name = "Frazzle III",  id = 849 },
    { name = "Distract III", id = 847 },
    { name = "Blind II",     id = 254 },
    { name = "Paralyze II",  id = 259 },
}

local chars = {
    { name='muunch',   job='BRD', engage=false, follow=true, hs_enabled=false, bs_enabled=false, qs_enabled=false, abstp_enabled=false, debuff_enabled=false,
      engaged=false, lastEngageTime=0, partyIndex=nil, currentFollowState=true, last_target_index=0,
      hs_lastcast=-HS_COOLDOWN, bs_lastcast=-STEP_COOLDOWN, qs_lastcast=-STEP_COOLDOWN, 
      abstp_last_attempt=0, abstp_last_success=0,
      debuff_step=1, debuff_last_attempt=0, debuff_step_start_time=0, debuff_complete=false },
    { name='slowpoke', job='GEO', engage=false, follow=true, hs_enabled=false, bs_enabled=false, qs_enabled=false, abstp_enabled=false, debuff_enabled=false,
      engaged=false, lastEngageTime=0, partyIndex=nil, currentFollowState=true, last_target_index=0,
      hs_lastcast=-HS_COOLDOWN, bs_lastcast=-STEP_COOLDOWN, qs_lastcast=-STEP_COOLDOWN, 
      abstp_last_attempt=0, abstp_last_success=0,
      debuff_step=1, debuff_last_attempt=0, debuff_step_start_time=0, debuff_complete=false },
    { name='goomy',    job='RDM', engage=false, follow=true, hs_enabled=false, bs_enabled=false, qs_enabled=false, abstp_enabled=false, debuff_enabled=false,
      engaged=false, lastEngageTime=0, partyIndex=nil, currentFollowState=true, last_target_index=0,
      hs_lastcast=-HS_COOLDOWN, bs_lastcast=-STEP_COOLDOWN, qs_lastcast=-STEP_COOLDOWN, 
      abstp_last_attempt=0, abstp_last_success=0,
      debuff_step=1, debuff_last_attempt=0, debuff_step_start_time=0, debuff_complete=false },
}

local mm = AshitaCore:GetMemoryManager()
local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

------------------------------------------------------------
-- Logic Helpers
------------------------------------------------------------
local function is_incapacitated(party, index)
    local buffs = party:GetMemberBuffs(index)
    if not buffs then return false end
    for _, id in pairs(buffs) do
        if id == 2 or id == 4 or id == 6 or id == 10 or id == 14 or id == 28 then return true end
    end
    return false
end

------------------------------------------------------------
-- Packet Sensing
------------------------------------------------------------
ashita.events.register('packet_in', 'sync_packet_logic', function(e)
    if (e.id == 0x28) then
        local userId = ashita.bits.unpack_be(e.data_raw, 0, 40, 32)
        local actionType = ashita.bits.unpack_be(e.data_raw, 0, 82, 4)
        local actionId = ashita.bits.unpack_be(e.data_raw, 0, 86, 32)

        local entityIdx = bit.band(userId, 0x7FF)
        local entName = mm:GetEntity():GetName(entityIdx)
        if not entName then return end

        for i = 1, #chars do
            local c = chars[i]
            if entName:lower() == c.name:lower() then
                if actionType == 4 and actionId == 275 then
                    c.abstp_last_success = os_clock()
                end
                
                if actionType == 4 and c.debuff_enabled and not c.debuff_complete then
                    local currentSpell = debuff_sequence[c.debuff_step]
                    if currentSpell and actionId == currentSpell.id then
                        if c.debuff_step < #debuff_sequence then
                            c.debuff_step = c.debuff_step + 1
                            c.debuff_step_start_time = os_clock()
                        else
                            c.debuff_complete = true
                        end
                    end
                end
            end
        end
    end
end)

------------------------------------------------------------
-- Main Loop
------------------------------------------------------------
ashita.events.register('d3d_present', 'sync_loop', function()
    local now = os_clock()
    if now - lastTick < TICK_INTERVAL then return end
    lastTick = now

    if mm:GetPlayer():GetIsZoning() ~= 0 then return end
    local party, ent, target = mm:GetParty(), mm:GetEntity(), mm:GetTarget()
    if not party or not ent or not target then return end

    local playerIdx = party:GetMemberTargetIndex(0)
    local playerStatus = ent:GetStatus(playerIdx)
    local playerZone = party:GetMemberZone(0)
    local current_target_index = target:GetTargetIndex()

    for i = 1, #chars do
        local c = chars[i]
        for idx=0,17 do
            local name = party:GetMemberName(idx)
            if name and name:lower() == c.name:lower() then c.partyIndex = idx; break end
        end

        if c.partyIndex then
            local mIdx = party:GetMemberTargetIndex(c.partyIndex)
            c.engaged = (mIdx > 0 and ent:GetStatus(mIdx) == 1)

            -- RESET: Only on actual Target change
            if current_target_index ~= c.last_target_index then
                c.debuff_step = 1
                c.debuff_complete = false
                c.debuff_step_start_time = now
                c.last_target_index = current_target_index
            end

            if party:GetMemberZone(c.partyIndex) == playerZone then
                -- Engagement
                if playerStatus == 1 and c.engage and not c.engaged then
                    if (now - c.lastEngageTime) >= 0.5 then
                        qcmd(string_format('/mst %s /attack [t]', c.name))
                        c.lastEngageTime = now
                    end
                elseif (playerStatus ~= 1 and c.engaged) or (not c.engage and c.engaged) then
                    qcmd(string_format('/mst %s /attack', c.name))
                    c.debuff_step = 1
                    c.debuff_complete = false
                end

                -- Actionable if Main is engaged
                if playerStatus == 1 and not is_incapacitated(party, c.partyIndex) then
                    -- PRIORITY 1: Absorb-TP
                    local casting_now = false
                    if c.abstp_enabled then
                        if (now - c.abstp_last_success) >= ABSTP_RECAST_WAIT then
                            if (now - c.abstp_last_attempt) >= ABSTP_RETRY_DELAY then
                                qcmd(string_format('/mst %s /ma "Absorb-TP" [t]', c.name))
                                c.abstp_last_attempt = now
                                casting_now = true
                            end
                        end
                    end

                    -- PRIORITY 2: Debuffs (Single Cycle Only)
                    if not casting_now and c.debuff_enabled and not c.debuff_complete then
                        if (now - c.debuff_step_start_time) > DEBUFF_STUCK_TIME then
                            c.debuff_step = c.debuff_step + 1
                            if c.debuff_step > #debuff_sequence then c.debuff_complete = true end
                            c.debuff_step_start_time = now
                        elseif (now - c.debuff_last_attempt) >= DEBUFF_RETRY_DELAY then
                            local spell = debuff_sequence[c.debuff_step]
                            if spell then
                                qcmd(string_format('/mst %s /ma "%s" [t]', c.name, spell.name))
                                c.debuff_last_attempt = now
                            end
                        end
                    end
                end
            end
        end
    end
end)
