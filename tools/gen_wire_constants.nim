## Emits the JS wire-constants block (src/fruit_market/wire_constants.nim) on
## stdout. The static replay-viewer bundle cannot run the server's
## compile-time splice, so Dockerfile.replay-viewer runs this to write
## dist/wire_constants.js and injects a <script src> for it into dist/index.html
## — same constants, same source, different delivery.
import ../src/fruit_market/wire_constants

echo WireConstantsJs
