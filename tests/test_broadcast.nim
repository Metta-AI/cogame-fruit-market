## tests/test_broadcast.nim — the chrome frame and the appended game block.

import std/[algorithm, json, os, strutils, unicode, unittest]

import fruit_market/sim, fruit_market/scripted, fruit_market/replays,
  fruit_market/broadcast

const RepoRoot = currentSourcePath().parentDir().parentDir()

proc playEpisode(rounds = 3): Sim =
  var config = defaultGameConfig()
  config.seed = 8
  config.rounds = rounds
  result = initSim(config)
  while not result.done:
    var orders: array[Seats, Order]
    for slot in 0 ..< Seats:
      orders[slot] = scriptedOrder(result, slot, skHauler)
      orders[slot].say = "3 apples for 2 bananas"
    result.setRoundOrders(orders)
    result.runRound()

suite "the chrome frame":
  var sim = playEpisode()
  let replay = parseReplay($replayJson(sim, sim.resultsJson()))
  let mid = parseJson(buildStateJson(
    chromeViewOfReplay(replay, 60, true, 1, false, true, newJArray())))
  let final = parseJson(buildStateJson(
    chromeViewOfReplay(replay, replay.frames.high, false, 1, false, false,
      newJArray())))

  test "teams are exactly apple and banana, each headlined by its guild":
    var keys: seq[string]
    for key, _ in mid["teams"]:
      keys.add(key)
    keys.sort()
    check keys == @["apple", "banana"]
    check mid["teams"]["apple"]["policies"][0].getStr() == "Apple Farmers"
    check mid["teams"]["banana"]["policies"][0].getStr() == "Banana Farmers"

  test "each guild plate's big number is that guild's total score":
    var apple = 0
    var banana = 0
    for slot in 0 ..< Seats:
      let score = replay.frames[60].cogAt(slot, 6)
      if replay.farmTypes[slot] == fApple: apple += score else: banana += score
    check mid["teams"]["apple"]["lives"].getInt() == apple
    check mid["teams"]["banana"]["lives"].getInt() == banana

  test "each plate carries its guild's trade count, volume and mean rate":
    ## Re-derived from the RECORDED trade events up to the playhead, so the
    ## numbers a seek shows are the numbers that tick really had.
    var
      trades = [0, 0]
      volume = [0, 0]
      rateSum = [0, 0]
    for row in replay.events:
      if row["k"].getStr() != "trade" or row["t"].getInt() > replay.maxTick():
        continue
      for (slot, given) in [(row["a"].getInt(), row["aGiveN"].getInt()),
          (row["b"].getInt(), row["bGiveN"].getInt())]:
        let guild = fruitId(replay.farmTypes[slot])
        trades[guild].inc
        volume[guild] += given
        rateSum[guild] += row["applesPerBanana"].getInt()
    check trades[0] + trades[1] > 0            ## the fixture really traded
    for fruit in [fApple, fBanana]:
      let
        guild = fruitId(fruit)
        plate = final["teams"][(if fruit == fApple: "apple" else: "banana")]
      check plate["trades"].getInt() == trades[guild]
      check plate["volume"].getInt() == volume[guild]
      check plate["rate"].getInt() ==
        (if trades[guild] > 0: rateSum[guild] div trades[guild]
         else: CanonicalRateX100)

  test "the roster carries the alias in name and the POLICY name in pol":
    check mid["roster"].len == Seats
    for entry in mid["roster"]:
      let slot = entry["s"].getInt()
      check entry["name"].getStr() == replay.names[slot]
      check entry["pol"].getStr() == replay.policyNames[slot]
      check entry["team"].getStr() in ["apple", "banana"]
      check entry.hasKey("score")
      check entry.hasKey("farm")

  test "lead is the exchange-rate series in the shape ingestLeadSeries wants":
    check mid["lead"]["teams"].len == 1
    check mid["lead"]["teams"][0].getStr() == "rate"
    check mid["lead"]["pts"].len == replay.rate.len
    for row in mid["lead"]["pts"]:
      check row.len == 2
      check row[0].getInt() >= 0
      check row[1].getInt() >= 0

  test "beats carry only the five declared kinds, gameover last":
    check mid.hasKey("beats")
    var kinds: seq[string]
    for beat in mid["beats"]:
      let kind = beat["k"].getStr()
      check kind in ["round", "firsttrade", "starve", "famine", "gameover"]
      if kind notin kinds:
        kinds.add(kind)
    let last = mid["beats"][mid["beats"].len - 1]
    check last["k"].getStr() == "gameover"
    check last["t"].getInt() == replay.maxTick()

  test "the lead frame ships once":
    let later = parseJson(buildStateJson(
      chromeViewOfReplay(replay, 61, true, 1, false, false, newJArray())))
    check not later.hasKey("lead")
    check not later.hasKey("beats")

  test "the terminal frame carries the verdict in words":
    check final["ph"].getStr() == "gameover"
    check final.hasKey("over")
    check final["over"]["ending"].getStr() in
      ["ROUND LIMIT", "FAMINE", "TIME", "FORFEIT"]
    check final["over"]["winner"].getStr() in ["apple", "banana"]
    check final["over"]["scores"].len == Seats
    check final["over"]["aliases"].len == Seats
    check final["fm"]["summary"].getStr().len > 10

  test "the order book is sorted by volume then slot and reads in words":
    let book = mid["fm"]["book"]
    var previous = high(int)
    for row in book:
      let volume = row["giveN"].getInt() + row["wantN"].getInt()
      check volume <= previous
      previous = volume
      check row["give"].getStr() != row["want"].getStr()
      check row["name"].getStr().len > 0

  test "a book row names the stall the offer stands at":
    ## `ASH  3 apples -> 2 bananas  north`: the stall is the only meeting
    ## protocol two wordless cogs have, so the row that advertises an offer
    ## says where to find it. Derived from the recorded cell, so the live and
    ## replay frames agree.
    var sawStall = false
    for index in 0 .. replay.frames.high:
      let frame = parseJson(buildStateJson(
        chromeViewOfReplay(replay, index, true, 1, false, false, newJArray())))
      for row in frame["fm"]["book"]:
        check row.hasKey("stall")
        let stall = row["stall"].getStr()
        check stall in ["", "north", "east", "south", "west"]
        if stall.len > 0:
          sawStall = true
          let slot = row["s"].getInt()
          let x = replay.frames[index].cogAt(slot, 0)
          let y = replay.frames[index].cogAt(slot, 1)
          check chebyshev(x, y, replay.board.stalls[parseEnum[StallId](stall)].x,
            replay.board.stalls[parseEnum[StallId](stall)].y) <= 1
    check sawStall

  test "every feed row's text is inside the caps the server enforces":
    ## The feed rows are BUILT HERE the way the page builds them — one row per
    ## trade, one per offer with the seat's `say` quoted on the end of it, one
    ## per starve/exhausted — and the longest one that this episode can produce
    ## has to fit the budget the 360 px feed was sized for. Every string that
    ## can land in a row is capped server-side; this is where the composed row
    ## is checked rather than its parts.
    const MaxFeedRowLen = 200
    var says: array[Seats, string]
    var rows = 0
    var longest = 0
    var longestRow = ""
    proc alias(slot: int): string = replay.names[slot].toUpperAscii()
    for row in replay.events:
      var text = ""
      case row["k"].getStr()
      of "order":
        let seat = row["seat"].getInt()
        says[seat] = row["say"].getStr()
        check says[seat].runeLen <= MaxSayLen
        check row["notes"].getStr().runeLen <= MaxNotesLen
        check validateUtf8(says[seat]) == -1
        check validateUtf8(row["notes"].getStr()) == -1
        continue
      of "offer":
        let seat = row["seat"].getInt()
        text = alias(seat) & " posts " & $row["giveN"].getInt() & " " &
          row["give"].getStr() & " for " & $row["wantN"].getInt() & " " &
          row["want"].getStr() & " auto"
        if says[seat].len > 0:
          text.add(" \u201c" & says[seat] & "\u201d")
      of "trade":
        text = alias(row["a"].getInt()) & " " & $row["aGiveN"].getInt() &
          " apples <-> " & $row["bGiveN"].getInt() & " bananas " &
          alias(row["b"].getInt()) & " \u00b7 " &
          $row["applesPerBanana"].getInt()
      of "starve":
        text = alias(row["seat"].getInt()) & " IS STARVING"
      of "exhausted":
        text = alias(row["seat"].getInt()) & " COLLAPSED \u2014 0 stamina"
      else:
        continue
      rows.inc
      check validateUtf8(text) == -1
      check text.runeLen <= MaxFeedRowLen
      if text.runeLen > longest:
        longest = text.runeLen
        longestRow = text
    check rows > 0
    ## The cap has to be doing work: the longest row this fixture drew is
    ## reported so a future change that blows past it is visible.
    checkpoint("longest feed row (" & $longest & " runes): " & longestRow)
    check longest > 0
    ## The roster chip and the endcard carry the POLICY name, the one string
    ## in the chrome that does not come from this repo.
    for slot in 0 ..< Seats:
      check replay.policyNames[slot].runeLen <= MaxPolicyNameLen

  test "the clock block spells the round out":
    check mid["fm"]["round"].getInt() >= 1
    check mid["fm"]["rounds"].getInt() == sim.config.rounds
    check mid["fm"]["ticks"].getInt() == replay.maxTick() + 1

suite "the appended game block":
  let page = readFile(RepoRoot / "client" / "replay_broadcast.html")

  test "the page is the starter's, with the game block appended":
    check "fruit-market additions to the inherited coworld-ctf chrome" in page
    ## The inherited chrome, unchanged.
    for id in ["stage", "board", "chrome", "scorebug", "plates-l", "plates-r",
        "clock", "clock-time", "clock-caption", "bannerlane", "killfeed",
        "transport", "btn-spoilers", "scrub", "momentum", "scrub-fill",
        "lulls", "scrub-win", "scrub-head", "endcard", "status"]:
      check ("id=\"" & id & "\"") in page

  test "the removed element families are gone, markup and CSS and wiring":
    for gone in ["id=\"viewpanel\"", "id=\"minimap\"", "id=\"zoombar\"",
        "id=\"zoom-slider\"", "id=\"fpv\"", "id=\"fpv-canvas\"",
        "id=\"povBadge\"", "id=\"mmwarn\"",
        "#viewpanel {", "#minimap {", "#zoombar {", "#fpv {", "#povBadge {",
        "#mmwarn {", "renderFpv", "renderMismatch", "renderPov",
        "syncViewUi", "attachMinimap"]:
      check gone notin page

  test "the two re-lettered literals and the lockerroom pointer-events":
    check "<span class=\"lives-label\">Score</span>" in page
    check "<span class=\"lives-label\">Lives</span>" notin page
    check "APPLES PER BANANA" in page
    check "LIVES LEAD" notin page
    check "pointer-events: none;\n  z-index: 25;" in page

  test "the plate colours and the 360 px scorebug rules ship":
    check ".plate.apple" in page
    check ".plate.banana" in page
    check ".plate-name" in page
    check "flex: 1 1 auto; min-width: 3.2em;" in page
    check "@media (max-width: 640px)" in page

  test "there is CSS for every beat kind the game emits":
    for kind in ["round", "firsttrade", "starve", "famine", "gameover"]:
      check (".beat-marker." & kind) in page

  test "the beat builder is buildMarketBeats, never markBeat":
    ## tandem, 2026-08-23: a game-block `function markBeat` is hoisted over the
    ## chrome alias block's `var markBeat = C.markBeat` and silently kills every
    ## scrubber beat.
    check "buildMarketBeats" in page
    check "function markBeat" notin page

  test "the appended beat markers are held back by ?spoilers=0":
    ## chrome_common.js's applySpoilers walks only the markers ITS markBeat
    ## placed. The block builds its own labelled <button>s, so it runs the same
    ## gate over them from the chrome's own toggle — otherwise every beat,
    ## `gameover` included, is on the rail from the first frame.
    check "applyMarketSpoilers" in page
    check "C.getSpoilers()" in page
    check "el.__tick = b.t;" in page

  test "no game-block function name collides with the chrome alias list":
    let banner = page.find("fruit-market additions to the inherited")
    check banner > 0
    let appended = page[banner .. ^1]
    ## Every name the starter's IIFE aliases out of chrome_common.js. A
    ## function declaration with any of these names inside the appended block
    ## would hoist over the alias for the whole scope.
    const ChromeAliases = [
      "teamCol", "activeTeams", "teamOf", "otherTeam", "stripSeatSuffix",
      "teamPolicies", "teamName", "teamHeadline", "rosterName", "setName",
      "setHandicap", "teamPerkGroups", "perkIconsHtml", "togglePov",
      "renderClock", "renderTransport", "ingestLullSpans", "renderLullSpans",
      "markBeat", "killMarkerTeam", "renderBeatMarkers", "captureTeam",
      "ingestBeats", "setVerdict", "ingestLeadSeries", "recordMomentum",
      "renderMomentum", "getSpoilers", "setSpoilers", "pushFeed", "applyEvent",
      "renderEndcard", "renderScorebug", "onFrame", "relayout"]
    for alias in ChromeAliases:
      check ("function " & alias & "(") notin appended
      check ("function " & alias & " (") notin appended

  test "the seat's say is the quoted tail of its offer row":
    ## One row per offer (tagged `auto` when the order was a fallback or a
    ## scripted baseline), with the say quoted on the end of it. The tag and
    ## the say ride the `order` event, which the sim emits at the same tick,
    ## so the block joins the batch by seat before drawing any of it.
    check "function applyMarketEvents(" in page
    check "autoTag(order.source)" in page
    check "order.say ?" in page

  test "the plate sub-line draws the trade count and the mean rate":
    check ".fm-plate-sub" in page
    check "renderPlateSub" in page
    check "' trades " in page

  test "a cleared offer's book row is struck through before it drops":
    ## An executed offer is CONSUMED on both sides, so it leaves the book on
    ## the next frame; the row is kept and struck through for a beat first.
    check ".fm-book-row.cleared" in page
    check "text-decoration: line-through" in page
    check "clearedUntil[e.a]" in page
    check "fm-book-stall" in page

  test "pushFeed keeps the starter's one-argument signature":
    ## Changing it is what broke cogball 0.1.4.
    check "function pushFeed(row) {" in page
