# skein-mandala

The Mandala token (BRC-162) overlay components for a
[skein](https://github.com/shruggr/skein): a topic manager and a lookup
service, as programs an overlay app carries in its tree, and the token
library they are built on, as a Zig package, and two pages an app that
carries the components serves. Version **0.5.2**.

## What it is

- **The topic manager** (`bin/mandala-topic.wasm`): one topic per token,
  `tm_<txid>` (a token deployed at output 0, under BRC-162, id `<txid>`, or
  BRC-161, id `<txid>_0`) or `tm_<txid>_<vout>` (a BRC-161 token deployed at a non-zero
  output). It admits every output of
  the token that the BSV-21 rules allow and retains the token coins a
  transaction spends: the protocol only, no governance.
- **The lookup service** (`bin/mandala-lookup.wasm`, `ls_mandala`): a
  token's unspent value outputs, its unspent authority outputs, one output
  by outpoint. Its index is under its own head, `<app>/ls_mandala`.
- **The discovery topic** `tm_mandala_deploys` (a mode of
  `mandala-topic`): every token's deploy output, so the metadata each token
  was deployed with can be found. Its lookup `ls_mandala_deploys` (a mode of
  `mandala-lookup`) answers `{tokenId}` with the deploy output.
- **Token ids** (BRC-162 "Token identification"). A token that originated
  as Mandala (a binary deploy, always at output 0) is written as the bare
  `<txid>`. A token that originated as BSV-21 (a BRC-161 JSON deploy) is
  written `<txid>_<vout>`, and `<txid>_0` for one deployed at output 0. The lookups take any of
  `<txid>`, `<txid>_<vout>` and `<txid>.<vout>`. Topic names do not change:
  `tm_<txid>` for a token at output 0 of either origin, `tm_<txid>_<vout>`
  for a BSV-21 token at a non-zero output.
- **Topics registered live.** The manifest declares no topics. A topic is
  served once the owner registers it with the overlay engine, one call:
  `register {topic, program: "mandala-topic"}`; `deregister {topic}` drops
  it (skein-overlay 0.6.0). The overlay tracks registered tokens only.
- **The library** (Zig module `mandala`): the BRC-162 and BRC-161 output
  parsers and the BSV-21 rules, which the topic manager, the lookup service
  and an application's own programs share.
- **The pages** (`www/`, built from `web/`): deploy a token; the owner's
  registered token topics. Below, "Pages".

docs/MANDALA.md has each in full and what is not built.

Exported Zig modules:

| module | file | what |
|---|---|---|
| `mandala` | `src/lib.zig` | `brc162` (the binary output parser), `brc161` (the JSON inscription parser), `bsv21` (the rules for one token over a parsed transaction, both forms), `name` (topic names and token id strings), `token` (the topic's verdict). `std` only |

## Use it

**The engine.** The components need skein-overlay 0.7.2 or later, whose
`register` / `deregister` serve topics registered at runtime
(docs/MANDALA.md "Registering a topic"), taken in the owner's box
`<app>/register` (0.7.7; `<app>/overlay` from 0.6.2), and whose submissions are messages into the
submission box `<app>/submit`, by message and from `POST /submit` (0.7.6;
before, the app's own box `<app>`). `bin/overlay.wasm` here is the v0.7.7
build.

**On its own** (`etc/app.json`, the reference manifest; the chain app first,
which the overlay requires):

```
skein-host install https://github.com/shruggr/skein-chain --instance <handle>
skein-host install https://github.com/shruggr/skein-mandala --instance <handle>
```

**Register a token's topic**: the owner's message in the app's box (skein
docs/APPS.md §4), `skein plan` / `skein send` or any BRC-100 wallet, to the
overlay engine (skein-overlay docs/OVERLAY.md "Register a topic"):

```
box:  register   (installed: <app>/register)
body: {"fn": "register", "args": {"topic": "tm_<txid>", "program": "mandala-topic"}}
body: {"fn": "deregister", "args": {"topic": "tm_<txid>"}}
```

The topic is `tm_<txid>`, `tm_<txid>_<vout>` or `tm_mandala_deploys` (the
discovery topic, registered the same way); it follows from how the token
was deployed, and the deploy page shows it. `program` is always
`mandala-topic`. Both calls are idempotent; the step's result record is
`{kind: "overlay-result", op, topic, active, changed}`, and the engine
answers `{fn, request, replyTo, result: {topic, active}}` to a sender a
message can reach. The registered set is the engine's head `<app>/topics`
(`{kind: "overlay-topics", topics: [{topic, program}]}`). A registered topic
is served from the next step, and the host subscribes `tm_<txid>`,
`tm_<txid>-admit` and `tm_<txid>-proof` from the engine's `subscribe`
events.

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
{"service": "ls_mandala", "query": {"tokenId": "<txid>", "limit": 10}}
{"service": "ls_mandala", "query": {"authoritiesTokenId": "<txid>"}}
{"service": "ls_mandala", "query": {"txid": "<txid>", "outputIndex": 1}}
{"service": "ls_mandala_deploys", "query": {"tokenId": "<txid>"}}
```

Each answer is an output-list: `{type: "output-list", outputs: [{beef,
outputIndex}]}`, each output with its transaction's BEEF.

### Carry the components in another app

An app that serves Mandala tokens with its own programs beside them (an
AMM) carries these in its tree and manifest:

1. **The programs.** `bin/overlay.wasm` (the engine, skein-overlay
   0.7.7), `bin/mandala-topic.wasm`, `bin/mandala-lookup.wasm`, copied from
   this repo, under the roles `overlay`, `mandala-topic`, `mandala-lookup`.
2. **`config.overlay`**, with no topics:

   ```json
   "overlay": {
     "lookups": {
       "ls_mandala": {"program": "mandala-lookup"},
       "ls_mandala_deploys": {"program": "mandala-lookup"},
       "ls_<yours>": {"program": "<your lookup>"}
     }
   }
   ```

   The Mandala topics are registered at runtime (item 4), so none is
   declared. A lookup with no `topics` list listens to every topic the
   overlay serves, registered or declared. A manifest MAY pre-declare
   topics in `config.overlay.topics` (an overlay with fixed topics, e.g.
   OpNS's one global topic); Mandala's are dynamic, so it declares none.
   Gossip is on for every topic unless `gossip` turns one off.
3. **The rows**:
   - `{"address": "register", "sender": "$owner", "program": "overlay"}`:
     the owner's message reaches the engine's `register` / `deregister` (the
     function is the body's `fn`). The address is relative: the install
     resolves it to `<app>/register` (skein#128; skein-overlay 0.7.7, was
     `overlay`, which for an app named `overlay` is its own box).
   - `{"address": "submit", "sender": "*", "program": "overlay", "filter":
     "beef"}`: the submission box `<app>/submit`, open to anyone, where a
     submission is a message `{fn: "submit", args: {beef, topics}}` and
     where `POST /submit` admits it (skein-overlay 0.7.6). There is no `""`
     row: the app's own box `<app>` is the engine's own traffic, derived by
     the install.
   - the four listing and documentation http rows, as in `etc/app.json`.
4. **The register call**, made by the owner once the app is installed, one
   per topic it runs: `{"fn": "register", "args": {"topic": "tm_<txid>",
   "program": "mandala-topic"}}` (and `tm_mandala_deploys` the same way);
   `{"fn": "deregister", "args": {"topic"}}` drops one.
5. **`requires: ["chain/1"]`.**

The rest (`/submit`, `/lookup`, the box rows from `event` and `$self`) is
derived from `config.overlay` by the install; a registered topic's gossip
is routed by the engine's `subscribe` events (skein #119), not by rows.

A program of the app's own that reads token outputs depends on the
`mandala` module (below) for the parsers and the rules.

## Depend on the library

`build.zig.zon`:

```zig
.dependencies = .{
    .skein_mandala = .{
        .url = "https://github.com/shruggr/skein-mandala/archive/refs/tags/v0.5.2.tar.gz",
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
const id = mandala.token.tokenIdOfString("<txid>").?; // or "<txid>_<vout>", "<txid>.<vout>"
const origin = (try mandala.token.originOf(a, txid, 0, deploy_script)).?; // .mandala (binary) or .bsv21 (JSON)
var buf: [mandala.name.max_suffix_len]u8 = undefined;
const text = mandala.name.tokenIdText(&buf, mandala.name.tokenIdOfString("<txid>").?, origin); // "<txid>" or "<txid>_0"
const j = try mandala.bsv21.judge(a, id, tx, previous_coins); // the rules over a bsv21.Tx
```

## Pages

Two static pages, for an app that carries the components (README "Carry
the components in another app") to serve. The Mandala app is not installed
by itself, so the pages are not served from this repo's manifest.

| page | served at | what |
|---|---|---|
| deploy | `/<app>/mandala/deploy/` | **Deploy a token.** Open to anyone: a helper over the user's own wallet. Fields: symbol, decimals (0 to 18), fixed supply (an amount in whole tokens) or authority (amount 0, the deploy output mints), an optional icon outpoint (`txid_vout`). `@1sat/actions`' `deployMandala` builds the BRC-162 deploy at output 0, the wallet (connected through `@1sat/connect`) signs and broadcasts it and files it (basket `mandala <txid> 0`). The page shows the token id, the bare `<txid>` (a Mandala token), and the topic to register, `tm_<txid>`, which the owner copies to the tokens page to register. Nothing is sent to the overlay. If the filing step fails after the broadcast, "File it again" runs the SDK's `fileMandalaDeploy`. |
| tokens | `/<app>/mandala/tokens/` | **Tokens on this overlay.** The owner's page. Lists the registered topics judged by `mandala-topic` (the overlay engine's head `<app>/topics`, `{kind: "overlay-topics", topics: [{topic, program}]}`, read through the instance's explorer, `/explore/head/<app>/topics`, which is the owner's read). Register by topic name (`tm_<txid>` or `tm_<txid>_<vout>`), deregister a listed topic, and a switch that registers or deregisters the discovery topic `tm_mandala_deploys`. Each change is the owner's message to the app's box `<app>/register`, the engine's `{fn: "register", args: {topic, program: "mandala-topic"}}` or `{fn: "deregister", args: {topic}}`, sent the way skein-site sends the owner's messages (skein's `RawBox.send`: a BRC-104-signed `POST <base>/sendMessage`, BRC-231 CBOR, recipient the instance's identity from its signed answers). The outcome is the step's result record (`{kind: "overlay-result", op, topic, active, changed}` or `{op, error}`), whose CID the step prints on stdout, read from the thread the message launched; then the set is read again. A wallet that is not the owner's gets the explorer's 403, and its messages are refused. |

The page takes the app's name and the instance from its own URL:
`<base>/<app>/mandala/<page>/`, where `<base>` is the instance's origin or a
host's `/@<handle>` dev form. So the same files work under any app name.

**Embedding.** The app's build copies `www/*` into its own `www/mandala/`
(`www/mandala/deploy/index.html`, `www/mandala/tokens/index.html`,
`www/mandala/assets/…`), and its static rows serve that directory under
`/<app>/` (skein-static's README has the rows). Asset paths are relative, so
`/<app>/mandala/deploy` (redirected to `…/deploy/`) loads them from
`/<app>/mandala/assets/`. Nothing is built on the skein: `www/` is committed
as built.

**The wallet's grouped request.** A wallet reads `manifest.json` at the
origin's root, so these pages ship none. The deploy uses the protocol
`[2, "mandala deploy"]` (counterparty self) and the label `mandala`; the
tokens page uses a BRC-104 session (`[2, "auth message signature"]`,
`[2, "server hmac"]`). Without them in the embedding app's manifest, the
wallet asks for each when it is first used.

**Build and test** (Node 22 or later, npm):

```
cd web
npm ci
SKEIN_DIR=../../skein npm run build    # typecheck, then ../www; SKEIN_DIR: a skein checkout at web/lib/SKEIN_REV
npm test                               # vitest: the page's place from its URL, the deploy input and the SDK's deploy from it, the owner's calls, the registered set and the answers, the sendMessage request
npm run typecheck
```

The stack is the AMM pages' (amm-poc `web/ui`): Vite, React, `@1sat/react`
and `@1sat/connect` for the wallet, `@1sat/actions` for the deploy. The
owner's messages and the explorer reads are skein's own client
(`src/client/raw.ts`), bundled from the skein checkout as skein-site bundles
it. `deployMandala` is imported from the package's `dist/mandala/deploy.js`,
not its entry, which re-exports every action. The bundle is about 2 MB
(480 KB gzipped). Most of it is `@1sat/connect`, which ships as one
prebuilt 2 MB file. No analytics.

## Build and test

Zig 0.16.0 (`mise.toml`).

```
zig build          # zig-out/bin/{mandala-topic,mandala-lookup}.wasm
zig build bin      # the same, into bin/ (committed)
zig build test     # the parsers, the rules, the topic, the lookup, natively
```

`bin/overlay.wasm` is copied from skein-overlay v0.7.7's build (`zig build
bin` there; the same bytes as its committed `bin/overlay.wasm`), not built
here. With a local skein-overlay
checkout: `zig build --fork=../skein-overlay`.

## Docs

| what | where |
|---|---|
| the components, the topic rule, the lookup, registering topics, what is not built | [docs/MANDALA.md](docs/MANDALA.md) |
| the engine, its contracts and gossip | shruggr/skein-overlay `docs/OVERLAY.md` |
| registering a topic; apps and manifests | shruggr/skein-overlay `docs/OVERLAY.md` "Register a topic"; skein `docs/APPS.md` §4, §6 |
| the protocol | BRC-162 (Mandala), BRC-161 (BSV-21 JSON) |

## Versions

| | |
|---|---|
| this app, its programs and package | 0.5.2 (tag `v0.5.2`) |
| the pages | `@1sat/actions` 0.0.233, `@1sat/react` 0.0.102, `@1sat/connect` 0.0.104, `@1sat/templates` 0.0.43, `@bsv/sdk` 2.8.6 (`web/package.json`, exact); skein's client at `web/lib/SKEIN_REV` |
| skein-overlay | v0.7.7 by tag URL and hash in `build.zig.zon` (modules `topic`, `lookup`, `sk`); the engine in `bin/` is its build |
| skein-sdk | v0.7.1, through skein-overlay (modules `chain`, `sk`, `cbor`) |
| requires | `chain/1` (shruggr/skein-chain 0.3.0) |

The token library and its tests moved here from amm-poc
`programs/amm-topic` (shruggr/skein#120); its fixtures
(`src/fixtures/vectors.zig`) are generated there by `gen/main.go` from the
AMM's Pool contract.

## Contributing

Work is tracked in shruggr/skein; start at issue
[#31](https://github.com/shruggr/skein/issues/31), this repo's issue is
[#120](https://github.com/shruggr/skein/issues/120). MIT, as skein.
