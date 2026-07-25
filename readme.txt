sync -- multibox orchestrator for Ashita v4 (FFXI retail)
author: aryl    version: 1.9.6

Run a crew of up to 18 characters from one HUD. sync handles healing,
buffing, pulling, weaponskills, skillchains and movement for every box
-- you play your main.

Design rationale and the full changelog live in devnotes.txt.


================================================================
HOW IT WORKS -- READ THIS FIRST
================================================================
Three ideas explain almost everything about sync:

1. ONE BRAIN, MANY BODIES.
   sync runs on your MAIN only. It holds all the logic and the UI. The
   other boxes run no logic at all -- they report their state back and
   do what they are told.

2. EVERY BOX NEEDS TWO OTHER ADDONS.
   rdmhelper reports each box's buffs, recasts and job back to sync.
   Multisend is the pipe sync sends commands over. A box missing
   either one is INVISIBLE to sync -- it will sit there doing nothing,
   and its crew row shows a red "! silent" tag.

3. NOTHING RUNS UNTIL YOU ASSIGN IT.
   A box does not heal because it is a WHM. It heals because you put
   it in a healer slot. Same for RDM, BRD, COR and GEO. An unassigned
   box is inert no matter what job it is on.

So the loop is: assign roles -> arm with /sync on -> play your main.


================================================================
INSTALL
================================================================
1. Copy every file EXCEPT rdmhelper.lua to:
     Ashita\addons\sync\

2. Copy rdmhelper.lua to EVERY box, main included:
     Ashita\addons\rdmhelper\rdmhelper.lua

3. On each box:
     /addon load sync          (main only)
     /addon load rdmhelper     (every box)
     /addon load multisend     (every box)

Whenever rdmhelper changes, REDEPLOY IT TO EVERY BOX. After a
wire-version bump you will see one WIRE MISMATCH line per box until
each one reloads rdmhelper -- that is the check working, not a fault.


================================================================
QUICKSTART
================================================================
1. Load sync on your main and open the HUD.

2. Add your alts in the Crew window (chevron -> +/- slot buttons),
   then reload sync so the roster applies.

3. Assign roles: your RDM box, healer boxes, and any BRD / COR / GEO
   boxes, each in its own panel.

4. Run  /sync selftest
     PASS = fine
     WARN = optional or empty (e.g. no RDM assigned), usually fine
     FAIL = actually broken, fix these first

5. /sync on  to arm the crew. This turns on engage, weaponskills,
   buffing and healing, and puts the RDM on debuff duty.

/sync on is the action starter. Configure first -- or load a profile
-- then arm.


================================================================
READING THE HUD
================================================================
"! silent" (red) on a crew row
    That box is in zone but sync has heard nothing from it, so it is
    inert. Check Multisend and rdmhelper are both loaded on THAT box.

"HALTED"
    sync hit an error and parked itself so it cannot spam your log.
    The traceback prints once. Fix the cause, then /sync on resumes --
    no reload needed.

Buffer HUD  (/sync buffer)
    A compact readout: one row per assigned BRD / COR / GEO box, plus
    one per main-job SCH, showing what is up and what is due. The >>
    chevron on a row opens that box's panel.


================================================================
WHAT SYNC DOES
================================================================
A tour of every subsystem. Each has a panel; most also have a
command. Remember that nothing runs for a box until it is assigned to
the relevant role AND has rdmhelper loaded.

HEALING
    Assign a primary and a backup healer. They watch every party
    member's HP and cure to the right tier, switching to Curaga when
    enough people are hurt. Options cover self-healing, a BLU box's
    cure spells, a DNC box's Waltzes and a SCH box's Adloquium, so a
    non-WHM healer still pulls its weight. Cure-first triage lets an
    emergency jump the queue ahead of anything else that box was about
    to do. Reraise is kept up on whoever you tick.
        /sync healer   (aka /sync adv)

STATUS REMOVAL
    The healers strip Poison, Paralyze, Silence, Blind, Curse,
    Disease, Doom, Petrify and the Def / MDef / Max-HP-down trio,
    Two healers no longer duplicate a strip: a cast claims its
    target for as long as the spell actually takes to land, not a
    flat 1.5s, so the second healer stops firing into the gap. If a
    healer holds YAGRUSH, tick the box in its panel -- every -na and
    Erase is then treated as party-wide, which stops sync buying
    Accession it does not need and stops the other healer patching
    someone the cast already covered. sync cannot see your gear, so
    it believes the checkbox.

    Blink and Aquaveil are kept up OUT OF COMBAT only. Engaged, both
    are stripped within seconds of landing, and re-casting them on a
    loop just keeps a healer from healing.

    using -na spells, Erase, Healing Waltz, or a Remedy if you allow
    the item. Contradance turns a Healing Waltz into an AoE cleanse
    CENTERED ON ITS TARGET -- so the dancer waltzes the afflicted
    member and sweeps the cluster around them, rather than dancing
    on the spot and hoping the party is standing on the dancer. It
    fires only when two or more of the dancer's OWN party need
    cleansing; anyone else still gets a normal single-target
    Healing Waltz. You set
    the removal order per family on the Advanced panel -- the High
    tier is also what is allowed to fire during a cure-first
    emergency.

RDM BUFFS
    Haste, Refresh, Protect, Shell, Phalanx, Enspells, Aurorastorm
    and the rest, maintained on whoever you tick, with Composure
    handled for you. The RDM also keeps its own Aquaveil and Blink
    up. SCH boxes contribute stratagem-boosted versions where they
    can.

    WHO CAN GET WHAT. Haste / Flurry / Protect / Shell are plain
    single-target casts and go to anyone you tick, CREW OR GUEST.
    Refresh III and Phalanx II are PARTY-RANGE, so they reach only
    members sharing the RDM's current party -- a cross-party row
    shows '-' rather than a checkbox that would never fire. Those
    two are also opt-in for guests; everything else defaults on.

    ACCESSION BLANKETS (RDM /SCH only). With Accession the RDM can
    cover her whole party with ONE self-cast instead of a cast per
    member. Protect V and Shell V do this automatically -- no
    button -- but only when at least TWO party members are actually
    missing the buff, so a single straggler after a raise still
    gets a cheap single-target cast rather than a stratagem charge.
    Phalanx and the Enspells are the same idea under your control:
    set them to 'acc' on the sch5 rows.

    THE RDM ALWAYS COMES FIRST. Self Haste and Refresh are the top
    of the RDM's own priority order, and the sch5 rows respect
    that: when the RDM is the sch5 caster, the engine waits until
    the RDM has its own Haste/Refresh before spending the box on
    anything else (with a short cap so a silenced or MP-dry RDM
    cannot stall it forever). Stances are never wastefully re-
    popped either -- Composure, Afflatus Solace, and Light Arts /
    Addendum fire only when verifiably down AND work is queued
    behind them; Majesty alone is timer-refreshed, because its
    duration outlives its recast by design.

    IF A BUFF NEVER FIRES, check the caster first. An 'acc' mode
    with no box that qualifies (RDM /SCH at 40+, or SCH /RDM at
    33+) casts nothing -- and the per-member cast it replaces
    stands down for it, so the buff goes missing from both paths.
    Set the row back to 'buff' or 'off' and the per-member cells
    take over again.
        /sync rdm <box>      assign the RDM box
        /sync buff           open the RDM Buff panel

RDM DEBUFFS
    A queue applied to what the crew is fighting -- Dia III, Frazzle
    III, Distract III, Slow II, Paralyze II, Blind II, Silence,
    Gravity, Gravity II, Dispel. Tick what you want and set the cast
    order.
    ONE SHOT PER MOB. Each enfeeble is cast once and then left alone;
    nothing is re-applied as it wears. A fresh mob starts a fresh
    queue -- including a respawn that reuses the same entity slot.
        /sync debuff   (aka /sync dpanel)

JOB DEBUFFS
    The same idea for non-RDM boxes, cast by a crew box of that job:
    BLM DoTs (Burn, Frost, Rasp, Choke, Shock, Drown), SCH helixes,
    and BRD Requiem / Elegy / Nocturne. All default off, all one shot
    per mob. Set them up on the RDM Debuffs panel.

REACTIONS
    Event-driven responses -- a box acts the moment a condition is
    seen, rather than on a timer.
        /sync react [on|off]

CHARM SLEEP PRIORITY
    When a crew box gets charmed, sync prioritises putting it to sleep
    so it stops beating on you.
        /sync charm [on|off]

HUNT & CAMP
    Pack hunting. Boxes acquire mobs inside an acquisition radius,
    respect claims, and each takes a DISTINCT mob rather than all
    piling on one. Set a box to Converge instead and it teams up on a
    mob the crew already has, for faster kills while the rest keep
    spreading out. A global whitelist says what to hunt and a global
    blacklist what to avoid; each box can have its own lists on top.
    A puller draws mobs in from range.

    HUNT LISTS -- two layers, both saved with the profile.
      WHITELIST   what a box IS allowed to hunt. EXACT name match.
                  An empty effective list means "anything in radius".
      BLACKLIST   what it must avoid. Plain SUBSTRING match, so one
                  entry can catch a whole naming family.
    Both come in a GLOBAL layer (every box) and a PER-BOX layer that
    LAYERS ON TOP.
        /sync wl | bl [add|rm|clear]            global
        /sync wl | bl <box|all> [add|rm|clear]  per box

    NEGATION. A PER-BOX entry starting with '-' cancels the matching
    GLOBAL entry for that box only, so one box can be let at
    something the rest of the crew is kept off. It is not a delete --
    use rm <n> for that -- and it only works in the per-box layer; a
    '-' entry on the global list does nothing. It matches the global
    entry EXACTLY AS TYPED, so what you negate is a whole entry, not
    a mob name that some entry happens to catch.

    Blacklist BEATS whitelist: a mob must be whitelisted AND not
    blacklisted to be hunted.

    ENEMY PETS -- BST jug pets, DRG wyverns, SMN avatars, PUP
    automatons, GEO luopans. A PET DIES WITH ITS MASTER, so fighting
    one is usually wasted effort twice over: it drops nothing itself,
    and the box can lose its target mid-fight the moment somebody
    else kills the master. The master is the correct target. Left to
    itself a crew will still spread onto a field of pets instead of
    the mobs that count -- Dynamis Divergence and Limbus are the
    cases that bite. Handle it with the lists:

      PREFERRED -- WHITELIST the mobs you came for. Whitelist match is
      exact, so every pet is excluded automatically and there is no
      pet naming to keep up with. This is the right tool in Dynamis
      and Limbus, where you know what you are farming anyway.

      QUICK SWEEP -- BLACKLIST  's  (apostrophe-s). Pets are named
      "<Master>'s <Pet>" -- Volte's Wyvern, Vanguard's Scorpion,
      Demon's Elemental, Aern's Elemental -- and that construction is
      what apostrophe-s means in a FFXI mob name. The blacklist is
      plain SUBSTRING, so ONE global entry sweeps every pet, in every
      zone, across prefixes that were never published. Nothing to
      maintain and nothing to update when a zone is added.
        /sync bl add 's
      Not checked against the whole bestiary -- if it ever eats
      something you want, negate it per box (below) or fall back to
      full pet names.

      For the rare pull where you DO want pets fought, negate the
      entry for that box:
        /sync bl <box> add -'s
      Read the '-' as "ignore the global entry that follows", not as
      "remove" -- removal is /sync bl rm <n>. That box is then free
      to take pets while the rest of the crew stays off them, which
      is the shape the exception actually takes: no single pet is
      worth singling out, since it dies with its master anyway.

      FULL PET NAMES ("Volte's Bomb") also work and are exact enough
      to be safe -- they just cost upkeep: one entry per prefix per
      zone, and the prefix lists are not published anywhere, so a
      wrong or missing name is a silent no-op.

    THE TRAP is blacklisting the pet NOUN on its own -- bomb,
    scorpion, avatar, hecteyes. Matching is SUBSTRING, and those are
    all ordinary huntable mobs somewhere else. A 'bomb' entry added
    for Dynamis stops the crew hunting Bombs everywhere, forever,
    with nothing pointing at the cause. Use the full name, or 's.

    Each box also has a MOVEMENT MODE:
      Move     roams freely
      Camped   stays inside a ring around a saved spot, walks home
               between kills
      Rooted   plants on an exact spot and tows the fight back
               instead of drifting
      Follow   hands movement to its follow target
        /sync hunt <box|all> [on|off]     /sync radius <yalms>
        /sync camp [set|clear]            start|stop = on|off
        /sync wl | bl [add|rm|clear]      /sync tname

DEFEND
    Per box, off by default. A box with Def ticked answers anything
    that starts hitting the party, even with Hunt off, and ignores the
    whitelist while doing it -- something already swinging at you is
    not optional. It never picks fresh mobs of its own.
        /sync defend [on|off]

MOVEMENT
    Follow keeps a box on its target. Fight-range (KIR) closes the gap
    to the mob and holds a ring. Standoff keeps a box at a chosen
    distance from the enemy -- for casters and ranged boxes that
    should not be in the pile. Return modes send a box back where it
    belongs after a fight.
        /sync move                        open the Movement panel
        /sync f <box|all> [on|off]        follow
        /sync kir <box|all> [on|off|<yalms>]
        /sync standoff <box|all> [on|off|<yalms>]

WEAPONSKILLS
    AutoWS fires a chosen weaponskill at a TP threshold, per box, with
    an optional alternate WS while Footwork is up. It remembers a
    setup per main job (see AUTOWS REMEMBERS EACH JOB below). AutoRA
    fires ranged attacks on a cadence. Main-only mode limits a box to
    the main's target.
        /sync ws [box] [on|off]     /sync ra <box> [on|off]

SKILLCHAINS
    Put boxes on the SC roster and build an ORDERED chain -- step 1
    fires, step 2 follows into it, and so on. SCH boxes can open with
    Immanence. Missing scdata only disables skillchains; it never
    breaks the rest of sync.
        /sync sc [on|off]

MAGIC BURST
    Nukers burst into the skillchains the crew makes.
        /sync mb [on|off]     /sync mbreak

JOB ABILITIES
    Per-box ability toggles on the Combat panel, level-gated and
    populated from that box's current job. Tick what you want used and
    it fires when it is useful and off cooldown.
        /sync ja <box|all> <ability> [on|off]

ACTION PRIORITY
    Each box can only do one thing per tick. When healing, status
    removal, debuffing and damage all want the same moment, this
    decides the order -- per box.
        /sync prio <box> <heal|-na|debuff|damage> [on|off]

BARD
    Up to 3 bard boxes, one per party (songs are party-scoped). One
    panel -- /sync brd -- holds everything: which box sings, the
    instrument mode, the five song slots, dummies, JA toggles
    (Nightingale, Troubadour, Soul Voice, Clarion Call, Marcato,
    Pianissimo), Pianissimo per-member overrides, and named sets you
    can switch between (including automatically after the opener).

    It does not re-sing on a fixed clock. It reads the SONGS THAT
    ARE ACTUALLY UP and their remaining time, and re-sings the whole
    set inside one Nightingale/Troubadour window before the shortest
    one drops. Thresholds live under Advanced.

    A member who loses songs (dispel, death) is repaired on their
    own with Pianissimo -- dummies to reopen the slots, then the set
    back on top -- without pulling the rest of the party into an
    early re-sing. That works for GUESTS too: their timers cannot be
    read but their buffs can. Restoring a FIFTH slot is deliberately
    not attempted: a re-sing cannot open a 5th slot without Clarion
    Call, and a party-wide cooldown is the wrong price for one
    person -- they get it back at the next full round. (Holding
    five is not the same as opening five: once the 5th song is up
    it can be upkept indefinitely with Clarion down, which is why a
    Clarion-off maintenance set still carries all five.) If four or more songs are missing across
    the party it says so and asks you to hit Full re-sing instead --
    past that, patching one at a time is just a slower full sing.

        /sync brd | sing | songs        open the panel
        /sync brd on|off                start / stop singing
        /sync brd2 on|off               box 2 (brd1..brd3)
        /sync brd <name>                assign the bard
        /sync brd none                  clear the slot
        /sync patch <member> [brd]      Pianissimo their set now
        /sync resing [brd]              full re-sing now

    /sync patch and /sync resing are the two panel buttons as
    typed commands -- no menu, no clicking through. The name is a
    prefix match ('/sync patch kup' finds Kupofried) and [brd] is
    the bard box, 1 if left off. '/sync patch2 <member>' and
    '/sync resing2' are the same thing in brd<N> shorthand.

    NOTE (upgrading): the old playlist engine and its window are
    gone. Playlists are NOT converted -- rebuild your sets in the
    panel. Which character sings is kept.

CORSAIR
    Up to 6 Corsair boxes. Pick two rolls each; Snake Eye, Fold,
    Crooked Cards and Random Deal are handled, with an optional
    engaged-only mode, gambling mode, range checking and a refresh
    lead so rolls are re-cast before they drop.

    SNAKE EYE is always followed by a DOUBLE-UP, never by another
    Snake Eye. This matters because with Snake Eye merits plus the
    COR job-specific legs the ability can come back up instantly,
    as though it was never used -- and that free use is meant to be
    SPENT on the guaranteed +1, not thrown away on a second Snake
    Eye. The roller latches the pairing rather than trusting the
    recast, so a lagging status icon cannot break it either.

    No roll ability is on a modelled timer anywhere. Availability
    is read live -- the main from its own recast array, alts from
    the cooldown set their rdmhelper reports every cycle -- so a
    Random Deal reset is picked up as it happens instead of being
    argued with by a stale countdown.
        /sync cor | roll     /sync cor 1..6 <options>

GEOMANCER
    Up to 3 GEO boxes. Each has an Indi- slot, a Geo- bubble slot and
    an Entrust slot (an Indi- placed on someone else), each with its
    own duration and recast window, plus Bolster, Widened Compass,
    Blaze of Glory, Ecliptic Attrition and Dematerialize toggles.
    Named sets let you swap a whole loadout at once.

    Bolster and Widened Compass are PRE-casts: they modify the next
    geomancy spell, so they fire ahead of the Indi- or Geo- they are
    meant to buff (Blaze of Glory is luopan-only, so it rides the
    Geo- cast only). All three are recast-gated -- a cooling ability
    is skipped rather than eaten, because a wasted /ja line would
    otherwise delay the bubble by 1.5s and buff nothing.

    ENTRUST IS MANUAL by default, because it is a 10-minute JA and
    a rotation clock is the wrong thing to spend it on (the same
    reasoning that keeps the BRD's Nightingale and Troubadour off
    the automatic path). The Entrust line in the GEO glance carries
    a STAR: click it to release. Green star = the JA is ready and
    it fires now. Blue star + a countdown = it is still on recast;
    clicking QUEUES the release, and it goes off the moment the JA
    comes up. Click a queued star again to cancel. Availability is
    read live (the main from its own recast array, an alt from the
    cooldown its rdmhelper reports), so nothing is guessed -- the
    GEO can confirm with /recast Entrust at any time. Untick
    "Manual" in the Entrust editor to restore the old automatic
    behaviour.
        /sync geo | geo1..geo3
        /sync ent | entrust [1..3]      release (or queue) Entrust
        /sync ent cancel [1..3]         clear a queued release

    A bubble that never went up no longer counts as cast. Indi- and
    Geo- casts are watched to their outcome: if one is interrupted
    -- most often by the GEO moving with the party -- the slot goes
    straight back to due instead of sitting on a full timer for a
    buff nobody has. New casts are also held while the crew is
    moving, so the interrupt is usually avoided in the first place.

ABSORB-TP
    Per box: cast Absorb-TP on a chosen target on a cadence, or fire
    it manually. /sync off disarms auto-fire on every box.

    An ATP row appears in the Buffer glance: collapsed it is one
    summary line (how many boxes are armed, plus the most recent
    absorb); the + expands it to one line per box showing the
    countdown to that box's next attempt, the last CONFIRMED absorb
    (amount, age, victim) and how many weaponskills the crew has
    landed on that victim since -- i.e. how much of the stolen TP has
    actually been spent. The row's chevron opens the full panel.

    "Confirmed" is literal: the amount and the countdown both come
    off the 0x028 action packet, so the cadence counts from the cast
    that actually landed rather than from the moment the command was
    issued.
        /sync abs [box] [target <name> | delay <sec> | fire]

CONSUMABLES
    Auto-Echo clears Silence with an Echo Drop. Auto-Food re-applies
    food. Auto-Soda keeps Regain up with a Frontier Soda. All per box,
    all off by default, all SESSION-armed -- a zone change disarms
    them. Each gives up after 2 failures and tells you which box.
        /sync soda [box|all] [on|off]

ONE-SHOT HELPERS
    Manual combos you fire yourself, on the main healer or RDM box.
    The box is reserved for the whole window so a routine cure cannot
    eat the stratagem charge mid-combo.
        /sync r4        Accession -> Regen IV, party-wide
        /sync r5        Perpetuance + Accession -> Regen V (SCH main)
        /sync msleep    Dark Arts -> Manifestation -> Sleep (AoE)
        /sync msleep2   the same with Sleep II
        /sync mbreak    the same with Break
    These land on YOUR current target -- it is relayed to the box as
    [t] through Multisend, so the box's own cursor is irrelevant.

PROFILES
    Save and load the whole config under a name -- one for farming,
    one for a specific fight, and so on.
        /sync profile save|load|del|list <name>

PRESETS
    A preset is much smaller than a profile: a named list of FLAG
    rows, run by typing its name. No config subtrees, no arm plan,
    no roster -- just "these boxes, these toggles, now".

        /sync <name>                       run it
        /sync preset                       list them
        /sync preset show <name>           print the rows, numbered
        /sync preset save <name>           capture the crew as it stands
        /sync preset add <name> <flag> <target> [on|off]
        /sync preset rm <name> <row>       drop one row
        /sync preset del <name>            delete it
        /sync preset reset                 restore the shipped pair

    SAVE captures the live flags of every IN-ZONE box and writes
    them as explicit on/off, never as toggles -- a toggle row flips
    whatever it finds, so a preset built from toggles does something
    different every time you run it. Flags every box agrees on
    collapse to one 'all' row; the rest are written per box.

    Flags: f e buf heal deb ref fl hs bs qs abs face
    (d = deb, b = buf, c = heal, as everywhere else). Hunt and Ret
    are deliberately NOT included -- both are session choices that
    reset on load by design, and a preset must not re-arm them
    behind you.

    Targets are name-free so a preset survives a roster change:
    'all', a crew SLOT NUMBER, 'rdm', or 'main'. A literal box name
    works but bakes that box in; save always writes slots.

    A preset name may not collide with a /sync command. The preset
    lookup runs BEFORE the command dispatch, so a preset called
    'hunt' would shadow /sync hunt with no way back short of
    editing settings.lua -- save refuses those names.

    Shipped: cb and bc, both 'buf all + heal all'. Delete or
    overwrite them; /sync preset reset puts them back.


================================================================
CREW LIMITS
================================================================
  crew    18 boxes (a full alliance). Edit in the Crew window, then
          reload sync to apply. Party membership is read live -- you
          do not configure it.
  BRD     3 boxes, one per party (songs are party-scoped)
  GEO     3 boxes
  COR     6 boxes


================================================================
AUTOWS REMEMBERS EACH JOB
================================================================
Every box keeps its own weapon / weaponskill / TP threshold PER MAIN
JOB, and swaps to the right one when that box changes job.

Take a box from MNK to BLU and it moves off Hand-to-Hand onto
Sword / Expiacion by itself. Change it to something you prefer and
that becomes the BLU setup from then on -- go back to MNK and your
h2h setup returns.

A job the box has never been on gets a sensible starting point at
1000 TP. It is a floor so the box is not stuck on the wrong weapon's
WS, not an opinion about your gear -- retune it once and it sticks.

The swap happens once, when the job change is noticed, so nothing
overrides you mid-session. Arming, AutoRA and main-only are never
touched by a job change.


================================================================
OFF BY DEFAULT
================================================================
COR Dia+ (Light Shot)
    Combat panel, any box maining or subbing COR. That Corsair fires
    Light Shot ~2s AFTER a Dia of any tier LANDS on a mob the crew is
    fighting. Light Shot ENHANCES a Dia that is already up; fired with
    no Dia the charge is simply wasted, which is why it follows the
    cast rather than leading it. One shot per Dia application per mob.

Auto-Soda
    Combat panel, per box. Uses a Frontier Soda when the box has no
    Regain. The item is fixed and not configurable on purpose. SESSION
    arm -- any zone change disarms it for every box. A box also on the
    Adloquium roster waits ~25s before falling back to the item, so
    the free cast wins.
        /sync soda [box|all] [on|off]

humanize
    Anti-metronome jitter on timings.
        /sync humanize [on|off] | <lo_ms> <hi_ms>


================================================================
SCH ARTS
================================================================
A MAIN-job SCH's stance is driven by commands, not a button. The
glance row is read-only: it reports the SELECTED Arts and whether that
stance is up.

    /sync arts on|off               ARM / DISARM every SCH box
    /sync arts <box|all> on|off     one box, or all
    /sync arts <box|all> la|da      select the mode
    /sync arts <box|all>            (no verb) toggle the mode
    /sync la [box|all]  /  /sync da [box|all]
    /sync sch on|off                alias of /sync arts on|off

SELECTING A MODE NEVER CASTS. The master arm decides whether anything
pops, so you can set a box up in town without it firing Light Arts at
you. Default is ARMED.

BE AWARE: on a main-job SCH, 'off' also stops Addendum: White -- so
that box's -na removal and Reraise stop with it. The greyed glance row
is the reminder.

'off' stops IDLE stance MAINTENANCE only. Manifestation commands and
AutoSC Immanence steps still establish Dark Arts when they need it.

In practice: leave every SCH on 'la' unless you run a dedicated nuker
box. Subjob SCHs are untouched -- they keep the Light Arts checkbox in
the Healer menu.


================================================================
KITE OPENERS
================================================================
A one-shot opener for the four fights that still want a kite (Cloud of
Darkness, Aita, Gartell, Dhartok).

    /sync kite  [mob]         Flash + Saboteur -> Gravity II, GEO
                              bubbles, RDM debuffs, crew rushes
    /sync skite [mob]         same, with Stymie before Saboteur (for a
                              Gravity II that would otherwise resist)
    /sync kite off            stand down without re-forming
    /sync kite pad <0..30>    extra seconds on every stage (default 0)
    /sync kite crew grav|dia  which debuff the plain-melee boxes wait
                              for (default dia)

No mob name uses your current target. Otherwise the name is a
case-insensitive PREFIX, so '/sync kite aita' and '/sync skite cloud'
both work.

STAGED RUSH -- each group releases on its own clock:
    crew (no opener job)   ~10s, after Gravity and Dia
    GEO                    ~14s, after its OWN opener and JA tail
    RDM                    ~20s, end of its own debuff tail
'/sync kite crew grav' moves the crew to ~6s -- snared but not yet
defence-down. Take it when the tank's hate is not in doubt.

The whole crew is FROZEN from the moment the command is issued until
its own rush stage, so nobody runs in on top of the kiting main. The
freeze also drops on '/sync kite off' and on zoning.

Per box (everything except the main) at the peel: follow OFF, engage
ON, defend OFF, KIR ON at 2.3y, rear-guard ON. AutoWS is armed on
every box in zone.

EACH GEO BOX runs, in order: Entrust Indi-Fury on your Corsair, then
Indi-Gravity on itself, then the bubble on the mob LAST -- so the
luopan lands near where the mob will actually be held.

AFTER THE FIGHT:
    /sync f all on     re-form and stand everyone down from rear-guard
    re-tick Def per box, or /sync defend on crew-wide
    set your GEO boxes back to their usual spells

    THESE PERSIST: kite WRITES Indi-Gravity, Geo-Frailty and Entrust
    Indi-Fury (targeting your COR) into the GEO config, and they stay
    there. Those four spells are the only things overridden. Your
    Geomancer JA ticks are honoured exactly as set and nothing is
    ticked or unticked for you.

If you retune the rear-guard, retune both geo_mod.KITE_KIR and
KITE_REAR_DIST, and keep the rear distance UNDER the KIR range.


================================================================
COMMON PROBLEMS
================================================================
Box will not cast / "Unable to cast" loop
    There is nothing to tune. Cast locks are packet-released: the
    box is freed by its own 0x028 completion the moment the spell
    resolves, so Fast Cast gear needs no configuring and the lock
    itself cannot release mid-cast. (/sync fastcast is retired and
    only prints a signpost; stale fastcast keys in old settings
    files are ignored.)

    The lock is a CEILING -- the spell's real base cast time plus a
    1.5s pad -- and it only ever bites when NO packet arrives, which
    means the box is outside the main's render range. If a box loops,
    check that first: pull it in and see if the loop stops.

    The other cause is a wrong base cast time in the table, which
    makes the ceiling expire while the spell is still going out (the
    old Curaga bug: ~2.5s under, so the next command interrupted the
    AoE heal). Cast times are in sync_data.lua, verified against the
    Windower spells resource; unknown spells fall back to 4.0s.

    A client-side reject ("Unable to cast spells at this time.") is
    packet-silent by design -- no 0x028 at all. The begin-watch
    catches it: no packet within 2s of the send and the box's claims
    are released so the target is not left skipped by both healers.

Box does nothing at all
    Run /sync selftest. Nine times out of ten it is rdmhelper or
    Multisend missing on that box.

Box is not weaponskilling
    AutoWS boots OFF on every reload, on purpose. Arm it per box on
    the crew row's W cell, or run a kite opener -- that arms it
    crew-wide.

Config file keeps growing after renaming boxes
    Renamed slots leave their old per-box settings behind.
        /sync gc         remove orphaned keys (safe)
        /sync gc dry     list them without deleting

WIRE MISMATCH lines after an update
    Expected. One line per box until each box reloads rdmhelper.
    Redeploy rdmhelper (and wire_def.lua) to every box.

Automations are eating my stacks
    Auto-Echo, Auto-Food and Auto-Soda spend inventory, and healer
    status removal can use a configured Remedy. Turn them off per box.
    Each also disarms itself after 2 consecutive failures and prints a
    line naming the box -- usually a missing or misspelled item.

Lost the last second of settings after a crash
    Saves are batched (at most once per second, plus once on unload)
    to avoid disk hitches. A hard client kill can lose ~1s of toggles;
    a normal reload or exit always saves cleanly.


================================================================
DIAGNOSTICS
================================================================
    /sync selftest      PASS / WARN / FAIL health check (aka diag)
    /sync roles         every box and what it is assigned to
    /sync version       addon + wire versions, per box
    /sync gc [dry]      clear settings left by renamed boxes
    /sync humanize      anti-metronome jitter on timings
    /sync faced         calibrate facing for your build
    /sync perf [1|2]    where frame time is going
    /sync huntdbg       hunt assignment decisions, live
    /sync repdbg <box>  what the main actually has for a box
    /sync sb <box>      why a self-buff is not firing
    /sync off | on      halt / resume all automation


================================================================
COMMANDS (partial -- /sync <cmd>)
================================================================
panels:       panel  apanel  combat  ui  glance  buffer  menu
              crew  healer  adv  buff  debuff  dpanel  hunt  move
              (min / expand are SUB-commands of the COR and GEO
               panels -- /sync cor min, /sync geo expand -- not
               bare verbs. Other panels use their header button.)
crew/chars:   crew  char  box  all  none  list  cast  assign  roles
hunt/pull:    hunt  camp  radius  rangeyd  standoff  move  movement
              charm  wl  bl  tname  defend  kir  faced
              (CORRECTION 1.9.8: 'target', 'gtarg', 'entarg' and
               'notgt' were listed here and are NOT hunt verbs.
               gtarg / entarg are GEO SUB-commands -- /sync geo gtarg
               <name> sets the bubble target, /sync geo entarg <name>
               the Entrust target. 'notgt' is an internal return value,
               never a command. There is no bare /sync target; use
               /sync tname to print what the main has targeted. Follow
               is a per-box toggle on the Movement panel, not /sync f.)
buffs:        buff  rdm  geo  geo1..geo3  brd  brd1..brd3  cor
              cor1..cor6  sing  songs  roll
              refresh  sb  debuff  na  react
              (geoN / brdN / corN select box N, then take the same
               verbs as the bare command. brd/sing/songs with no
               argument toggles the Songs panel; on|off drives that
               box's singing; any other word assigns the bard, and
               'none' clears the slot. 'playlist' is gone.)
combat:       ws  sc  mb  ra  faced  prio  priority
              (mbreak is a ONE-SHOT combo, not a magic-burst verb --
               it is Manifestation + Break, listed below with msleep.
               'fired' is not a command.)
              delay  ja  adv  dis  healer
one-shots:    r4  r5  msleep  msleep2  mbreak
absorb-tp:    abs [box] [target <n>|delay <sec>|fire]  apanel
sch/arts:     arts <box|all> on|off|la|da   la [box|all]   da [box|all]
consumables:  soda [box|all] [on|off]
              (echo / food are Combat-panel checkboxes)
profiles:     profile save|load|del|list|none <name>
              profile export <name>            anonymized -> shared\
              profile import <file> [as <name>] [preview]
              profile shared                   list shared\ files

    SHARING A PROFILE, START TO FINISH
    ----------------------------------
    Author:
      1. Tune the crew until it plays the way you want.
      2. /sync profile save raidnight
           Snapshots the config subtrees PLUS the arm set (the live
           per-box buf/heal/deb/eng toggles on the HUD -- those are
           session flags, not config, and nothing else records them).
           WHEN you save no longer matters. The arm set comes from
           the ARM PLAN (/sync arm) -- an explicit grid of what
           /sync on should turn on, per box -- not from whatever
           was toggled at save time. Author it once; town saves and
           mid-fight saves store the same thing.
           The save message reports the plan size and the armed
           reaction count. Reactions only travel if they are
           enabled when you save.
      3. /sync profile export raidnight
           Writes config\addons\sync\shared\raidnight.lua and
           prints what it did: entries that did not map, anchors it
           blanked, reaction command lines it rewrote, guest
           warnings.
      4. Export already Ctrl-F'd it for you: the finished text is
         scanned for every live crew and guest name BEFORE the file
         is opened, and a hit aborts the write and prints the
         offending line. So a successful export is the pass. The
         file is plain readable Lua, so eyeball it anyway if you
         like.
           The translator walks EVERY key and value in the
           snapshot, so an abort means a name is stored somewhere
           it does not look like a name -- or it is a false
           positive (a box name that is also an ordinary word, or
           a mob that shares a box's name). Re-run with 'force'
           once you have read the flagged lines.
      5. Send the file.

    Recipient:
      6. Drop it in config\addons\sync\shared\.
         /sync profile shared        lists what is in there.
      7. /sync profile import raidnight preview
           DRY RUN. Prints which box every token resolves to on
           YOUR crew and what rides on each. Stores nothing.
      8. /sync profile import raidnight
           (add: as <name>   to store it under a different name)
      9. /sync profile load raidnight

    STEP 9 IS NOT OPTIONAL. Import only STORES the profile -- it
    changes nothing until you load it. An import that printed
    "imported" and did nothing to your crew is working correctly.

    Two more things that bite:
      * Export reads the SAVED profile, not live config. Tweak
        something after saving and you must save again before
        exporting, or you ship the old state.
      * The token map is built from live config AT EXPORT TIME. If
        your GEO box is not actually assigned as GEO in the panel
        when you export, it tokenizes as a bare slot (@s4) and
        lands on the recipient's slot 4 instead of their geomancer.
        Check role assignments before exporting.

    A SAVED profile is not anonymous -- it has to restore onto your
    own crew, so it keeps real names (in the arm set, in every
    per-box map, and in the GEO bubble/Entrust targets). EXPORT is
    what makes one shareable: it writes a separate copy with every
    box replaced by a ROLE token -- @main @rdm @geo1 @brd @cor1
    @heal1 -- falling back to slot (@s3) for boxes with no role and
    position (@g1) for guests. Import maps those tokens onto
    whoever holds the same roles on your side.

    ALWAYS PREVIEW FIRST. /sync profile import <file> preview is a
    dry run: it prints exactly which box each token resolves to on
    YOUR crew, how many settings ride on each, and anything that
    resolves to nobody -- then stores nothing and changes nothing.
    Importing onto an unchanged crew is a weak test (tokens map
    straight back to the boxes they came from, so it passes even
    if role resolution is broken); the preview shows the
    resolution itself, which is the part worth reading.

    Role, not slot, because role transfers MEANING. If the author's
    Geomancer is slot 4 and yours is slot 2, slot-keying would hand
    your slot 4 their geomancer's settings -- wrong, and wrong in a
    way that looks like it worked.

    Anything that cannot map is reported, never silently dropped:
    boxes not in your crew are listed, and target/anchor fields
    pointing at an unmappable box are blanked to '' (the documented
    auto value) rather than left chasing a stranger. Guest entries
    are kept but WARNED about -- guests hold no role, so their
    settings land on whoever occupies the same guest position.

    Reactions ride along too. The reaction LIST stays a shared
    repository (author one, use it from any profile), but a
    profile now stores the full DEFINITIONS of the reactions it
    arms, not just their ids -- ids are local counters, so an
    id-only profile meant nothing on anyone else's install.
    Loading a profile matches its reactions against the
    repository BY CONTENT: a match is armed in place, a miss is
    appended and armed. Nothing is ever deleted -- a profile says
    what it wants ON, never what to remove. Importing the same
    profile twice cannot duplicate a reaction.

    On export, a reaction's box is tokenized and crew names
    inside its command line are substituted too. Command lines
    are free text, so that part is substring replacement --
    worth eyeballing the Reactions panel after an import. A
    reaction pointing at a box that cannot be mapped is
    retargeted to main and reported, so it still fires instead
    of silently pointing at nobody.

    Kite settings ride along: kite_rear / kite_pad are per-box and
    tokenize like everything else. The per-mob KITE_PROFILES table
    is CODE, keyed by mob name, and contains no crew names at all
    -- share that file as-is.

arm plan:     arm                     (window: what /sync on arms)
              arm show [default]      dry-run the next /sync on
              on default              arm from the GENERIC spec, ignoring
                                      the plan (does not edit the plan)

    /sync on arms per the ARM PLAN: a grid of box x engine
    (Buffs / Heal / Debuff / Engage / AutoWS) that says what
    SHOULD be armed. Empty plan = the generic arm spec, exactly as
    before -- nothing changes until you author one. Once any box
    is ticked the plan governs completely, and a box left blank
    arms nothing.

    /sync on always says which source it used:
        [sync] ON -- arm plan (5 box(es)) ...
        [sync] ON -- generic arm spec (no arm plan authored)
        [sync] ON -- generic arm spec (forced -- plan ... ignored)
    /sync on default forces the third for one run without touching
    the plan, so the next bare /sync on is back on the plan.
    Note /sync profile none does NOT restore the generic spec: the
    plan is global and survives unloading a profile.

    Buttons: Seed from generic (start from the working default),
    Copy from live (make the crew's current toggles the plan),
    Clear (back to the generic spec).

    Ticking a box in the plan does NOT arm it. The plan is what
    /sync on will do, not what is running now.

    The plan is GLOBAL config, not per-profile state. Editing it
    changes what /sync on does immediately, profile loaded or not.
    It also travels: saving a profile stores the current plan, and
    LOADING a profile overwrites the plan with that profile's. So
    edit freely with no profile active; with one active, re-save
    it to keep the change.

    Columns mirror the main HUD rail exactly -- flw / eng / ws /
    buf / hea / deb / a-tp, same order, names and colours.
    Follow and Absorb-TP are included even though the generic spec
    never arms them: "the generic spec has no opinion" is not the
    same as "you cannot state one", and the plan is where you
    state one. Seeding from generic leaves both off, so the
    default is unchanged. /sync off still always disarms
    Absorb-TP, plan or no plan.

priorities:   prio | priority          (window: both editors)
              prio <name> <heal|-na|debuff|damage> [on|off]
kiting:       kite [mob]  skite [mob]  kite off  kite pad <0..30>
              kite crew grav|dia
              (per-mob JA profiles live in sync_commands.lua ->
               geo_mod.KITE_PROFILES -- the three kite SPELLS never
               change, the job abilities and the Entrust recipient
               do. Edit the table, /addon reload sync.)
profiles:     profile save|load|del|list|none|clear <name>
              profile export|import|shared
presets:      preset list|show|save|add|rm|del|reset [name]
diagnostics:  selftest (test/diag)  version  roles  gc [dry]
              perf [1|2]
debug:        huntdbg  repdbg  sb  perf  table  tname  off  on
other:        humanize [on|off] | <lo_ms> <hi_ms>
aliases:      ver = version   human = humanize
              diag/test = selftest   assign = roles   adv = healer
              glance/menu = buffer   dpanel = debuff   move = movement


================================================================
FILES
================================================================
sync.lua           entry point: boilerplate, per-frame handler, module
                   wiring, 0x028 dispatcher, rdmhelper listener
sync_core.lua      shared container -- constants + live reference slots
sync_config.lua    default settings table (pure data)
sync_data.lua      static lookups: job abilities, spell cast times
sync_sched.lua     per-frame scheduler
sync_commands.lua  /sync command dispatch
ui.lua             imgui panels, per-char boxes, buffer HUD
hunt.lua           combat / pack-hunt: movement, claim, pull, camp,
                   leash, follow
buffs.lua          GEO / COR / BRD / RDM buff passes, song cycles
healer.lua         heal loop, -na removal, reraise, AoE heals, SCH
abilities.lua      weaponskills, job abilities, skillchain engine
scdata.lua         auto-SC data (generated). Missing scdata only
                   disables SC -- it never breaks sync
readme.txt         this file
devnotes.txt       design rationale + changelog
rdmhelper.lua      SEPARATE addon (addon 1.9.6, WIRE v14). Buff
                   reporter. Install on every box; redeploy
                   whenever wire_def.lua changes -- the two copies
                   of wire_def.lua must stay BYTE-IDENTICAL.
                   /sync selftest flags a version mismatch.


================================================================
CREDITS
================================================================
scdata.lua derived from the chains addon: Ivaar (SkillChains data),
Sippius (Ashita v4 port).
