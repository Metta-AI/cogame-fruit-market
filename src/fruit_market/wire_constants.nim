## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with. Rendered ONCE from the same Nim consts the engine
## runs on; `server.nim` splices it into the served client page and
## `tools/gen_wire_constants.nim` emits it for the static wasm bundle.
##
## THE GLOBAL KEEPS ITS NAME. `client/chrome_common.js` reads
## `window.CTF_WIRE` and that file ships BYTE-FOR-BYTE, so renaming the global
## would force a byte change in a file that must not change.

import std/strutils

import ./sim_types, ./global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  # 0.5 is the replay-only half speed (ReplayHalfSpeed, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  "window.CTF_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",shotFxTicks:0" &
  ",shotTrailFalloff:1.6" &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
const ChromeCommonMarker* = "<!-- CHROME_COMMON -->"
const BroadcastCoreMarker* = "<!-- BROADCAST_CORE -->"

proc spliceWireConstants*(page: string): string =
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
