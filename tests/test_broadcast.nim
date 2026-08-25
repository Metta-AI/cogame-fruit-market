## tests/test_broadcast.nim — the chrome frame and the appended game block.

import std/[algorithm, json, os, strutils, unittest]

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

  test "pushFeed keeps the starter's one-argument signature":
    ## Changing it is what broke cogball 0.1.4.
    check "function pushFeed(row) {" in page
