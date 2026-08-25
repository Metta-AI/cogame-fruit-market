## The event WIRE FORMAT, shared by live emission and replay playback.
##
## Fork of coworld-ctf `src/ctf/events.nim`: one serializer, so a consumer can
## never be asked to tell a live row from a re-read one. Every offer,
## withdrawal and trade is an event — that is what discharges the idea's "all
## offers logged" integrity clause.

import std/json

import ./sim_types

type
  EventKind* = enum
    evHarvest = "harvest"
    evSpill = "spill"
    evCross = "cross"
    evOffer = "offer"
    evWithdraw = "withdraw"
    evUnfunded = "unfunded"
    evTrade = "trade"
    evEat = "eat"
    evStarve = "starve"
    evExhausted = "exhausted"
    evOrder = "order"
    evRound = "round"
    evFamine = "famine"
    evEnd = "end"

  SimEvent* = object
    kind*: EventKind
    t*: int
    seat*: int
    fruit*: Fruit
    n*: int
    x*, y*: int
    lost*: int
    stamina*: int
    give*, want*: Fruit
    giveN*, wantN*: int
    clamped*: bool
    reason*: string
    a*, b*: int
    aGive*, bGive*: Fruit
    aGiveN*, bGiveN*: int
    applesPerBanana*: int
    dist*: int
    craved*: bool
    hunger*: int
    points*: int
    round*: int
    job*: Job
    stall*: StallId
    hasStall*: bool
    eat*: EatPolicy
    hasOffer*: bool
    source*: OrderSource
    say*: string
    notes*: string
    latencyMs*: int
    scores*: seq[int]
    hungers*: seq[int]
    staminas*: seq[int]
    trades*: int
    volume*: int
    rateX100*: int
    ending*: string

proc jsonRow*(event: SimEvent): JsonNode =
  ## One JSON row per event. `k` is the kind, `t` the tick, `seat` the slot.
  result = newJObject()
  result["k"] = %($event.kind)
  result["t"] = %event.t
  case event.kind
  of evHarvest:
    result["seat"] = %event.seat
    result["fr"] = %($event.fruit)
    result["n"] = %event.n
    result["x"] = %event.x
    result["y"] = %event.y
  of evSpill:
    result["seat"] = %event.seat
    result["fr"] = %($event.fruit)
    result["lost"] = %event.lost
  of evCross:
    result["seat"] = %event.seat
    result["x"] = %event.x
    result["y"] = %event.y
    result["stamina"] = %event.stamina
  of evOffer:
    result["seat"] = %event.seat
    result["give"] = %($event.give)
    result["giveN"] = %event.giveN
    result["want"] = %($event.want)
    result["wantN"] = %event.wantN
    result["clamped"] = %event.clamped
  of evWithdraw:
    result["seat"] = %event.seat
  of evUnfunded:
    result["seat"] = %event.seat
    result["reason"] = %event.reason
  of evTrade:
    result["a"] = %event.a
    result["b"] = %event.b
    result["aGive"] = %($event.aGive)
    result["aGiveN"] = %event.aGiveN
    result["bGive"] = %($event.bGive)
    result["bGiveN"] = %event.bGiveN
    result["applesPerBanana"] = %event.applesPerBanana
    result["x"] = %event.x
    result["y"] = %event.y
    result["dist"] = %event.dist
  of evEat:
    result["seat"] = %event.seat
    result["fr"] = %($event.fruit)
    result["craved"] = %event.craved
    result["hunger"] = %event.hunger
    result["points"] = %event.points
  of evStarve, evExhausted:
    result["seat"] = %event.seat
  of evOrder:
    result["seat"] = %event.seat
    result["round"] = %event.round
    result["job"] = %($event.job)
    result["fr"] = %($event.fruit)
    result["stall"] = (if event.hasStall: %($event.stall) else: newJNull())
    result["eat"] = %($event.eat)
    result["offer"] =
      if event.hasOffer:
        %*{
          "give": $event.give, "giveN": event.giveN,
          "want": $event.want, "wantN": event.wantN
        }
      else:
        newJNull()
    result["source"] = %($event.source)
    result["say"] = %event.say
    result["notes"] = %event.notes
    result["latencyMs"] = %event.latencyMs
  of evRound:
    result["round"] = %event.round
    result["scores"] = %event.scores
    result["hunger"] = %event.hungers
    result["stamina"] = %event.staminas
    result["trades"] = %event.trades
    result["volume"] = %event.volume
    result["rateX100"] = %event.rateX100
  of evFamine:
    discard
  of evEnd:
    result["reason"] = %event.reason
    result["ending"] = %event.ending
    result["scores"] = %event.scores

proc eventsJson*(events: openArray[SimEvent]): JsonNode =
  result = newJArray()
  for event in events:
    result.add(event.jsonRow())
