## Fruit Market wire types and constants.
##
## Forked from coworld-ctf `src/ctf/sim_types.nim`: one module owns the
## constants, the enums and the record layout every other module reads, and
## FIELD ORDER IS SACRED — the replay writer, the viewer and the tests all
## walk these records positionally.
##
## Every sim quantity is an INTEGER. No float ever enters sim state, so a seed
## reproduces a replay bit-exactly (tests/test_sim.nim depends on it).

import std/[strutils]

const
  GameVersion* = "1"
    ## GV1 (fruit market): eight cogs, two fruits, two farmer types, two
    ## concentric rivers; mirror-image offer clearing.

  Cols* = 32
  Rows* = 18
  CellPx* = 48
    ## Board pixels per cell. 32 x 18 x 48 = 1536 x 864, and the WHOLE board
    ## always fits the frame — which is why the viewer drops `#viewpanel`.
  BoardW* = Cols * CellPx
  BoardH* = Rows * CellPx

  Seats* = 8
    ## num_agents. One number, in every manifest variant, in the certification
    ## fixture, and as <SEATS> in tools/ci/docker_smoke.sh.

  CogAliases*: array[Seats, string] = [
    "Ash", "Bram", "Cedar", "Dune", "Elm", "Fern", "Gale", "Holt"]
    ## Anonymous, fruit-neutral, fixed to slots and never rotated. A seat sees
    ## only aliases; policy names are spectator-side only.

  CogColorNames*: array[Seats, string] = [
    "red", "orange", "yellow", "lime", "light blue", "blue", "pink", "white"]

  CogColorRgb*: array[Seats, array[3, int]] = [
    [217, 79, 61],    # red
    [226, 132, 44],   # orange
    [232, 195, 58],   # yellow
    [140, 198, 63],   # lime
    [116, 187, 226],  # light blue
    [74, 122, 214],   # blue
    [226, 120, 178],  # pink
    [238, 234, 224]   # white
  ]

  # --- cogs: inventory, hunger, stamina (## The game) ------------------------
  InvCap* = 12
  HungerMax* = 100
  Hunger0* = 60
  HungerDrainPeriod* = 4
  CraveNutrition* = 25
  OwnNutrition* = 10
  CraveScore* = 5
  OwnScore* = 1
  EatCooldown* = 24
  StaminaMax* = 100
  Stamina0* = 100
  StaminaRegenPeriod* = 2
  StarveDrain* = 2
  MoveStaminaLand* = 1
  MoveStaminaWater* = 10
  MoveCooldown* = 2
  WaterMoveCooldown* = 4
  HarvestCooldownOwn* = 12
  HarvestCooldownOther* = 96
  YieldOwn* = 3
  YieldOther* = 1
  RegrowTicks* = 60
  TradeRadius* = 3
  ViewRadius* = 6
  OfferMin* = 1
  OfferMax* = 6
  TradesPerRound* = 1

  Rounds* = 12
  TicksPerRound* = 60

  MaxSayLen* = 80
  MaxNotesLen* = 320
  MaxErrorLen* = 200
    ## Every recorded string is truncated on RUNE boundaries at these caps.

  PlaybackSpeeds*: array[6, int] = [1, 2, 3, 4, 8, 16]
  TargetFps* = 24
  SeekTicksPerFrame* = 240
    ## A mid-seek click that lands before the first chrome frame is QUEUED and
    ## converged with a bounded per-frame tick walk, never dropped.

type
  FruitMarketError* = object of CatchableError

  Fruit* = enum
    fApple = "apple"
    fBanana = "banana"

  Zone* = enum
    zWall = "wall"
    zWater = "water"
    zOrchard = "orchard"
    zMarket = "market"
    zIsland = "island"

  Job* = enum
    jHarvest = "harvest"
    jMarket = "market"
    jTrek = "trek"
    jRest = "rest"

  EatPolicy* = enum
    epCrave = "crave"
    epAny = "any"
    epNone = "none"

  StallId* = enum
    stNorth = "north"
    stEast = "east"
    stSouth = "south"
    stWest = "west"

  Action* = enum
    aWait = "wait"
    aMoveN = "move_n"
    aMoveE = "move_e"
    aMoveS = "move_s"
    aMoveW = "move_w"
    aHarvest = "harvest"

  OrderSource* = enum
    osScripted = "scripted"
    osLlm = "llm"
    osRetry = "retry"
    osFallback = "fallback"

  ScriptKind* = enum
    skNone = "none"
    skHauler = "hauler"
    skHomesteader = "homesteader"
    skMirror = "mirror"
      ## test-only: gate (d)'s book reader. Never a shipped policy.

  Offer* = object
    ## A posted offer. `active` false means the cog holds no offer.
    active*: bool
    giveFruit*: Fruit
    giveN*: int
    wantFruit*: Fruit
    wantN*: int
    unfunded*: bool
    postedRound*: int

  Order* = object
    ## One seat's standing order for a round. The kernel turns it into the
    ## per-tick action stream.
    job*: Job
    fruit*: Fruit
    hasFruit*: bool
    stall*: StallId
    hasStall*: bool
    eat*: EatPolicy
    hasOfferKey*: bool     ## the reply carried an `offer` key at all
    withdraw*: bool        ## `"offer": null`
    offer*: Offer
    clamped*: bool
    say*: string
    notes*: string
    source*: OrderSource
    latencyMs*: int

  Cog* = object
    x*, y*: int
    farm*: Fruit
    apples*, bananas*: int
    hunger*, stamina*: int
    score*: int
    offer*: Offer
    order*: Order
    hasOrder*: bool
    moveCd*, harvestCd*, eatCd*: int
    exhausted*, starving*: bool
    tradedThisRound*, tradedThisTick*: bool
    wading*: bool
    cravedEaten*, ownEaten*: int
    harvested*, trades*, volume*, crossings*, starvingTicks*: int
    roundScore0*, roundHarvest0*, roundEaten0*: int
    roundTrades0*, roundCross0*: int
    notes*: string

  Tree* = object
    x*, y*: int
    fruit*: Fruit
    bareFor*: int

  Stall* = object
    id*: StallId
    x*, y*: int

  TapeRow* = object
    ## One executed print on the public tape.
    t*: int
    giveFruit*: Fruit
    giveN*: int
    wantFruit*: Fruit
    wantN*: int
    applesPerBanana*: int   ## x100
    a*, b*: int             ## slots, a < b

  RoundRow* = object
    round*: int
    score*, hunger*, stamina*: int
    trades*, harvested*, eaten*, crossings*: int
    marketRate*: int

  Beat* = object
    t*: int
    kind*: string    ## round | firsttrade | starve | famine | gameover
    n*: int
    seat*: int

  Frame* = object
    ## One recorded tick. Fruit Market records STATE, not inputs, so playback
    ## never re-simulates and a seek is an array index.
    t*: int
    c*: array[Seats * 8, int]   ## x,y,apples,bananas,hunger,stamina,score,flags
    o*: array[Seats * 4, int]   ## giveFruitId,giveN,wantN,unfunded (-1 = none)
    r*: seq[int]                ## per-tree bareFor counters

const
  FlagExhausted* = 1
  FlagStarving* = 2
  FlagTraded* = 4
  FlagWading* = 8

proc fruitId*(fruit: Fruit): int =
  if fruit == fApple: 0 else: 1

proc fruitOfId*(id: int): Fruit =
  if id == 1: fBanana else: fApple

proc other*(fruit: Fruit): Fruit =
  if fruit == fApple: fBanana else: fApple

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values. Anything unknown is `hauler`, the working
  ## baseline every failed decision lands on.
  case text.strip().toLowerAscii()
  of "": skNone
  of "homesteader", "autarky": skHomesteader
  of "mirror": skMirror
  else: skHauler

proc chebyshev*(ax, ay, bx, by: int): int =
  max(abs(ax - bx), abs(ay - by))

proc mirrors*(a, b: Offer): bool =
  ## Exact mirror image, as the idea states: all four fields swapped.
  a.active and b.active and
    a.giveFruit == b.wantFruit and a.giveN == b.wantN and
    a.wantFruit == b.giveFruit and a.wantN == b.giveN

proc applesPerBananaX100*(apples, bananas: int): int =
  ## The printed rate, x100. Zero bananas cannot happen (an offer is always
  ## apple <-> banana) but guard anyway rather than divide by zero.
  if bananas <= 0: 0 else: (apples * 100) div bananas
