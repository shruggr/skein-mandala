# skein-mandala

The Mandala token (BRC-162) overlay components for a
[skein](https://github.com/shruggr/skein): a topic manager and a lookup
service, as programs an overlay app carries in its tree, and the token
library they are built on, as a Zig package. Version **0.2.0**.

## What it is

- **The topic manager** (`bin/mandala-topic.wasm`): one topic per token,
  `tm_<txid>` (a token deployed at output 0, under BRC-162 or BRC-161, id
  `<txid>_0`) or `tm_<txid>_<vout>` (a BRC-161 token deployed at a non-zero
  output). It admits every output of
  the token that the BSV-21 rules allow and retains the token coins a
  transaction spends: the protocol only, no governance. It also keeps the
  app's active token list (`mandala.tokens/1`).
- **The lookup service** (`bin/mandala-lookup.wasm`, `ls_mandala`): a
  token's unspent value outputs, its unspent authority outputs, one output
  by outpoint. Its index is under its own head, `<app>/ls_mandala`.
- **The discovery topic** `tm_mandala_deploys` (a mode of
  `mandala-topic`): every token's deploy output, so the metadata each token
  was deployed with can be found. Its lookup `ls_mandala_deploys` (a mode of
  `mandala-lookup`) answers `{tokenId}` with the deploy output.
- **Live activation.** A topic is served once its token is activated: the
  owner's `mandala.tokens.activate {tokenId}` writes the token list under
  `<app>/mandala` and emits `subscribe` for the topic's three GossipSub
  topics; `deactivate` undoes it. The overlay tracks activated tokens only.
- **The library** (Zig module `mandala`): the BRC-162 and BRC-161 output
  parsers and the BSV-21 rules, which the topic manager, the lookup service
  and an application's own programs share.

docs/MANDALA.md has each in full and what is not built.

Exported Zig modules:

| module | file | what |
|---|---|---|
| `mandala` | `src/lib.zig` | `brc162` (the binary output parser), `brc161` (the JSON inscription parser), `bsv21` (the rules for one token over a parsed transaction, both forms), `name` (topic names and token id strings), `token` (the topic's verdict). `std` only |

## Use it

**The engine.** The components need skein-overlay 0.5.0 or later, which
serves activated topics through `config.overlay.prefixes` (docs/MANDALA.md
"The engine"). `bin/overlay.wasm` here is the v0.5.0 build.

**On its own** (`etc/app.json`, the reference manifest; the chain app first,
which the overlay requires):

```
skein-host install https://github.com/shruggr/skein-chain --instance <handle>
skein-host install https://github.com/shruggr/skein-mandala --instance <handle>
```

**Activate a token**: the owner's message in the app's box (skein
docs/APPS.md §4), `skein plan` / `skein send` or any BRC-100 wallet:

```
box:  mandala
body: {"fn": "mandala.tokens.activate", "args": {"tokenId": "<txid>_0"}}
```

The answer is `{fn, request, replyTo, result: {tokenId, topic, active:
true}}`. The discovery topic is switched the same way by its name:
`{"fn": "mandala.tokens.activate", "args": {"topic": "tm_mandala_deploys"}}`. The topic `tm_<txid>` is served from the next step, and the host's
libp2p node subscribes `tm_<txid>`, `tm_<txid>-admit` and `tm_<txid>-proof`.

**Submit** to the app's base URL (`https://<handle>.<host>/mandala`; local:
`http://127.0.0.1:8100/@<handle>/mandala`):

```
POST <base>/submit
X-Topics: ["tm_<txid>"]
Content-Type: application/octet-stream
<BEEF>
```

**Look up**:

```
POST <base>/lookup
{"service": "ls_mandala", "query": {"tokenId": "<txid>_0", "limit": 10}}
{"service": "ls_mandala", "query": {"authoritiesTokenId": "<txid>_0"}}
{"service": "ls_mandala", "query": {"txid": "<txid>", "outputIndex": 1}}
{"service": "ls_mandala_deploys", "query": {"tokenId": "<txid>_0"}}
```

Each answer is an output-list: `{type: "output-list", outputs: [{beef,
outputIndex}]}`, each output with its transaction's BEEF.

### Carry the components in another app

An app that serves Mandala tokens with its own programs beside them (an
AMM) carries these in its tree and manifest:

1. **The programs.** `bin/overlay.wasm` (the engine, skein-overlay
   0.5.0, which reads `config.overlay.prefixes`), `bin/mandala-topic.wasm`,
   `bin/mandala-lookup.wasm`, copied from this repo, under the roles
   `overlay`, `mandala-topic`, `mandala-lookup`.
2. **`config.overlay`**:

   ```json
   "overlay": {
     "topics": {},
     "prefixes": {"tm_": {"program": "mandala-topic", "active": "mandala"}},
     "lookups": {
       "ls_mandala": {"program": "mandala-lookup", "prefixes": ["tm_"]},
       "ls_mandala_deploys": {"program": "mandala-lookup", "prefixes": ["tm_"]},
       "ls_<yours>": {"program": "<your lookup>", "prefixes": ["tm_"]}
     }
   }
   ```

   `active` must be `"mandala"`: the topic manager keeps the list under
   `<app>/mandala`. The discovery topic `tm_mandala_deploys` is under the
   same prefix (served while on the list), not in `topics`: a `topics`
   entry would be served and subscribed from the install on, with no
   switch. A lookup service of the app's own listens to the
   activated topics with `"prefixes": ["tm_"]`. Gossip is on for every
   topic unless `gossip` turns one off.
3. **`provides`**: the `mandala.tokens/1` interface as in `etc/app.json`
   (`activate`, `deactivate`, each `writes: true`, args `{"tokenId?":
   "string", "topic?": "string"}`, one of the two). The SDK's dispatch helper reads the declaration from the
   app record.
4. **The rows**:
   - `{"address": "<app>", "sender": "$owner", "program": "mandala-topic"}`:
     the owner's activate and deactivate. If the app's box already has an
     `$owner` row to its own program, that program hands a
     `mandala.tokens.*` call on as an in-VM call to `mandala-topic` from its
     step instead; the list and the events are then the step's.
   - `{"transport": "libp2p", "address": "tm_", "prefix": true, "sender":
     "*", "program": "overlay", "fn": "submit", "filter": "beef"}`: every
     activated topic's gossip (skein #119). The app's subscribe events are
     scoped by it.
   - the four listing and documentation http rows, as in `etc/app.json`.
5. **`requires: ["chain/1"]`.**

The rest (`/submit`, `/lookup`, the box rows from `event` and `$self`) is
derived from `config.overlay` by the install.

A program of the app's own that reads token outputs depends on the
`mandala` module (below) for the parsers and the rules.

## Depend on the library

`build.zig.zon`:

```zig
.dependencies = .{
    .skein_mandala = .{
        .url = "https://github.com/shruggr/skein-mandala/archive/refs/tags/v0.2.0.tar.gz",
        .hash = "<zig fetch --save prints it>",
    },
},
```

`build.zig`:

```zig
const m = b.dependency("skein_mandala", .{ .target = wasi, .optimize = .ReleaseSafe });
// … .imports = &.{.{ .name = "mandala", .module = m.module("mandala") }}
```

```zig
const mandala = @import("mandala");
const tok = mandala.brc162.decode(script) orelse return; // {id, amount, role, payload, lock}
const id = mandala.token.tokenIdOfString("<txid>_0").?;
const j = try mandala.bsv21.judge(a, id, tx, previous_coins); // the rules over a bsv21.Tx
```

## Build and test

Zig 0.16.0 (`mise.toml`).

```
zig build          # zig-out/bin/{mandala-topic,mandala-lookup}.wasm
zig build bin      # the same, into bin/ (committed)
zig build test     # the parsers, the rules, the topic, the lookup, the token list, natively
```

`bin/overlay.wasm` is copied from skein-overlay v0.5.0's build (`zig build
bin` there; the same bytes as its committed `bin/overlay.wasm`), not built
here. With a local skein-overlay
checkout: `zig build --fork=../skein-overlay`.

## Docs

| what | where |
|---|---|
| the components, the topic rule, the lookup, activation, what is not built | [docs/MANDALA.md](docs/MANDALA.md) |
| the engine, its contracts and gossip | shruggr/skein-overlay `docs/OVERLAY.md` |
| activating a topic live; apps and manifests | skein `docs/OVERLAY.md`, `docs/APPS.md` §4, §6 |
| the protocol | BRC-162 (Mandala), BRC-161 (BSV-21 JSON) |

## Versions

| | |
|---|---|
| this app and package | 0.2.0 (tag `v0.2.0`) |
| skein-overlay | v0.5.0 by tag URL and hash in `build.zig.zon` (modules `topic`, `lookup`, `sk`); the engine in `bin/` is its build |
| skein-sdk | v0.5.1, through skein-overlay (modules `chain`, `app`, `sk`, `cbor`) |
| requires | `chain/1` (shruggr/skein-chain 0.3.0) |

The token library and its tests moved here from amm-poc
`programs/amm-topic` (shruggr/skein#120); its fixtures
(`src/fixtures/vectors.zig`) are generated there by `gen/main.go` from the
AMM's Pool contract.

## Contributing

Work is tracked in shruggr/skein; start at issue
[#31](https://github.com/shruggr/skein/issues/31), this repo's issue is
[#120](https://github.com/shruggr/skein/issues/120). MIT, as skein.
