addon.name    = 'sync'
addon.author  = 'aryl'
addon.version = '1.0.1' 

require('common')
local imgui = require('imgui')

-- Logic Constants
local HS_TP_THRESHOLD   = 350
local HS_COOLDOWN       = 85
local STEP_TP_THRESHOLD = 100
local STEP_COOLDOWN     = 10
local ABS_COOLDOWN      = 15 
local TICK_INTERVAL     = 0.3 
local lastTick          = 0

local ui_show = { true }
local debuff_list = { "Dia III", "Frazzle III", "Distract III", "Blind II", "Paralyze II" }

local chars = {
    { name='muunch',   f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0, hs_last=0, bs_last=0, qs_last=0, deb_last=0, last_target_id=0, casting=false, cast_start=0, disengage_sent=0 },
    { name='slowpoke', f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0, hs_last=0, bs_last=0, qs_last=0, deb_last=0, last_target_id=0, casting=false, cast_start=0, disengage_sent=0 },
    { name='goomy',    f={true}, e={false}, hs={false}, bs={false}, qs={false}, abs={false}, deb={false}, 
      step=1, done=false, timer=0, last_abs=0, hs_last=0, bs_last=0, qs_last=0, deb_last=0, last_target_id=0, casting=false, cast_start=0, disengage_sent=0 },
}

local qcmd = function(cmd) AshitaCore:GetChatManager():QueueCommand(1, cmd) end

------------------------------------------------------------
-- Event: Packet Handling (Now safer)
------------------------------------------------------------
ashita.events.register('packet_in', 'packet_logic', function (e)
    if (e.id == 0x28) then
        local mm = AshitaCore:GetMemoryManager()
        local ent = mm and mm:GetEntity()
        if not ent then return end

        local actorId = bit.band(ashita.bits.unpack_be(e.data_raw, 0, 40, 32), 0x7FF)
        local category = ashita.bits.unpack_be(e.data_raw, 0, 82, 4)
        local actorName = ent:GetName(actorId)
        
        if not actorName then return end
        local actNameLower = actorName:lower()

        for _, c in ipairs(chars) do
            if actNameLower == c.name and c.casting then
                -- Spell/JA/Ranged Success (4, 6, 14)
                if (category == 4 or category == 6 or category == 14) then 
                    c.casting = false
                    if not c.abs[1] and c.deb[1] then
                        c.step = c.step + 1
                        if c.step > #debuff_list then c.done = true end
                    end
                    c.timer = os.clock() + 0.5 -- Short recovery
                -- Interrupted/Prevented (8, 12)
                elseif (category == 8 or category == 12) then 
                    c.casting = false
                    c.timer = os.clock() + 1.2 -- Longer recovery for failure
                end
            end
        end
    end
end)

------------------------------------------------------------
-- Event: Main Logic Loop (Optimized)
------------------------------------------------------------
ashita.events.register('d3d_present', 'logic_loop', function ()
    local now = os.clock()
    if now - lastTick < TICK_INTERVAL then return end
    lastTick = now

    local mm = AshitaCore:GetMemoryManager()
    if not mm or mm:GetPlayer():GetIsZoning() ~= 0 then return end

    local ent = mm:GetEntity()
    local party = mm:GetParty()
    local targ = mm:GetTarget()
    if not ent or not party or not targ then return end

    -- Pre-calculate target info
    local subActive = targ:GetIsSubTargetActive()
    local tIndex    = targ:GetTargetIndex(subActive)
    local tID       = (tIndex ~= 0) and ent:GetServerId(tIndex) or 0
    local tHP       = (tIndex ~= 0) and ent:GetHPPercent(tIndex) or 0

    local mainIdx     = party:GetMemberTargetIndex(0)
    local mainEngaged = (mainIdx ~= 0 and ent:GetStatus(mainIdx) == 1)

    -- Efficient Party Map
    local partyMap = {}
    for x = 0, 5 do -- Typically only need first 6 for mules
        local mName = party:GetMemberName(x)
        if mName then partyMap[mName:lower()] = x end 
    end

    for _, c in ipairs(chars) do
        local pIdx = partyMap[c.name]
        if pIdx then
            local muleTP = party:GetMemberTP(pIdx)
            local mIdx = party:GetMemberTargetIndex(pIdx)
            local muleEngaged = (mIdx ~= 0 and ent:GetStatus(mIdx) == 1)
            
            -- RESET: If target changes or dies
            if tID == 0 or tHP <= 0 or (tID ~= c.last_target_id) then
                c.step = 1; c.done = false; c.casting = false
                c.last_target_id = tID; c.deb_last = 0
            end

            -- ENGAGE MANAGEMENT
            if (not c.e[1] or not mainEngaged or tID == 0 or tHP <= 0) then
                if muleEngaged and (now - c.disengage_sent > 2.0) then
                    qcmd(string.format('/mst %s /attack off', c.name))
                    c.disengage_sent = now
                end
            elseif c.e[1] and mainEngaged and tID ~= 0 and tHP > 5 then
                if not muleEngaged then qcmd(string.format('/mst %s /attack [t]', c.name)) end
            end

            -- ACTION SELECTION
            if tID ~= 0 and tHP > 0 then
                -- Failsafe: Clear casting state if stuck
                if c.casting and (now - c.cast_start > 10.0) then
                    c.casting = false
                end

                if now > c.timer and not c.casting then
                    
                    -- BRANCH A: Absorb-TP (Takes absolute priority if box is checked)
                    if c.abs[1] then
                        if (now - c.last_abs > ABS_COOLDOWN) then
                            qcmd(string.format('/mst %s /ma "Absorb-TP" [t]', c.name))
                            c.last_abs = now; c.cast_start = now; c.casting = true
                        end

                    -- BRANCH B: Combat Routine (Requires Main to be Engaged)
                    elseif mainEngaged and tHP > 5 then
                        -- Priority 1: Haste Samba
                        if c.hs[1] and muleTP >= HS_TP_THRESHOLD and (now - c.hs_last > HS_COOLDOWN) then
                            qcmd(string.format('/mst %s /ja "Haste Samba" <me>', c.name))
                            c.hs_last = now; c.timer = now + 1.8
                        
                        -- Priority 2: Debuff Cycle
                        elseif c.deb[1] and not c.done then
                            if (now - c.deb_last > 2.5) then
                                qcmd(string.format('/mst %s /ma "%s" [t]', c.name, debuff_list[c.step]))
                                c.deb_last = now; c.cast_start = now; c.casting = true
                            end

                        -- Priority 3: Steps
                        elseif c.bs[1] and muleTP >= STEP_TP_THRESHOLD and (now - c.bs_last > STEP_COOLDOWN) then
                            qcmd(string.format('/mst %s /ja "Box Step" [t]', c.name))
                            c.bs_last = now; c.timer = now + 1.5
                        elseif c.qs[1] and muleTP >= STEP_TP_THRESHOLD and (now - c.qs_last > STEP_COOLDOWN) then
                            qcmd(string.format('/mst %s /ja "Quick Step" [t]', c.name))
                            c.qs_last = now; c.timer = now + 1.5
                        end
                    end
                end
            end
        end
    end
end)
