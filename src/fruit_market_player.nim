## Fruit Market player: a policy is just a prompt.
##
## Forked from `cogame-bullwhip/src/bullwhip_player.nim`. This process connects,
## delivers its prompt, and then only listens — every decision is made inside
## the game container, which is what makes ONE parallel batch of eight requests
## per round possible.
##
## `PLAYER_SCRIPTED=hauler` registers the seat as the market-making baseline
## and `PLAYER_SCRIPTED=homesteader` as the autarky foil; the server plays
## those deterministically, with no LLM at all.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <fruit-market-image> --name my-fruit-market \
##     --run /bin/fruit-market-player --secret-env PLAYER_PROMPT="<strategy>"

import
  std/[json, options, os, strutils, times],
  whisky

const DefaultPrompt = """
You are a market maker, not a farmer. Read every offer within sight first: if
any cog wants the fruit you grow, post its EXACT mirror - the same two numbers,
swapped - and stand within three cells of that cog until it executes. If nobody
near you has posted anything, walk to the nearest stall and post the book
price: three of your own fruit for two of theirs. Never post numbers you cannot
cover; an unfunded offer wastes the whole round. Set eat to 'any' the moment
hunger drops under 40 - a starving cog cannot walk to its counterparty. Note in
your notes which alias posted which side, because a cog that offers bananas is
a banana farmer and will be there again next round.
"""

const
  RegisterResendSeconds = 10.0
    ## An unappliable registration is HELD and RE-SENT rather than dropped
    ## (paintball, 2026-08-25 — a dropped registration silently made a champion
    ## seat play scripted).
  RegisterResendIntervalMs = 2000

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  if prompt.len == 0 and scripted.len == 0:
    prompt = DefaultPrompt

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "fruit-market player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "fruit-market player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  var
    registeredAt = epochTime()
    lastResend = epochTime()
    sawWelcome = false

  while true:
    ## The whole receive loop is wrapped: whisky's `receiveMessage` RAISES on a
    ## close frame or a truncated read, and the game's quit(0) can outrun the
    ## flushed `final` frame. Exiting 0 on a dead socket is what makes the
    ## hosted player container's exit code deterministic (raid, 2026-08-23).
    var received: Option[Message]
    try:
      received = socket.receiveMessage(200)
    except CatchableError as error:
      echo "fruit-market player: socket closed (", error.msg, "), exiting"
      break
    if received.isNone:
      ## No frame this poll. Keep re-sending the registration for ~10 s so a
      ## first send that raced the server's slot admission still lands.
      let now = epochTime()
      if now - registeredAt < RegisterResendSeconds and
          (now - lastResend) * 1000.0 >= RegisterResendIntervalMs.float:
        lastResend = now
        try:
          socket.send(promptFrame())
        except CatchableError:
          echo "fruit-market player: socket closed while re-registering"
          break
      continue
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      case payload{"type"}.getStr()
      of "welcome":
        if not sawWelcome:
          sawWelcome = true
          echo "fruit-market player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(promptFrame())
        registeredAt = epochTime()
      of "final":
        echo "fruit-market player: final scores ", payload{"scores"}
        break
      else:
        discard
    except CatchableError as error:
      echo "fruit-market player: ignoring bad frame: ", error.msg
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
