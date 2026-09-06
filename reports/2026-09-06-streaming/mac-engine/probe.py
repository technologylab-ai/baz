import json, sys
from pathlib import Path
sys.path.insert(0, '/Users/rs/code/github.com/technologylab.ai/bounded-http-streaming/tests')
import integration as wire
with wire.Server(Path('/Users/rs/code/github.com/technologylab.ai/bounded-http-streaming/zig-out/bin/bounded-http')) as server:
    ready = next(line for line in server.lines if line.startswith("READY "))
    wire.require("optimize=ReleaseSafe" in ready, "ReleaseSafe required")
    wire.plaintext(server)
Path('/Users/rs/code/github.com/technologylab.ai/baz-streaming/.zig-cache/streaming-evidence/mac-engine/readiness.json').write_text(json.dumps(dict(ready=ready, stats=server.stats), indent=2) + "\n")
