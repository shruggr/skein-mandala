# skein-mandala

The Mandala token (BRC-162) overlay components for a
[skein](https://github.com/shruggr/skein): a topic manager and a lookup
service, as programs an overlay app carries in its tree, and the token
library they are built on, as a Zig package, and two pages an app that
carries the components serves. Version **0.8.1**.

## What it is

- **The topic manager** (`bin/mandala-topic.wasm`): one topic per token,
  `tm_<txid>` (a token deployed at output 0, under BRC-162 or BRC-161, id
  `<txid>_0`) or `tm_<txid>_<vout>` (a BRC-161 token deployed at a non-zero
  output). It admits every output of
  the token that the BSV-21 rules allow and retains the token coins a
  transaction spends: the protocol only, no governance.
- **The lookup service** (`bin/mandala-lookup.wasm`, `ls_mandala`): a
  token's unspent value outputs, its unspent authority outputs, one output
  by outpoint. Its index is under its own head, `<app>/ls_mandala`.
- **The discovery topic** `tm_mandala` (0.6.0; was `tm_mandala_deploys`,
  renamed to the name Deggen's Mandala overlay uses, so both converge on
  one discovery topic; the lookup names are unchanged) (a mode of
  `mandala-topic`): every token's deploy output, so the metadata each token
  was deployed with can be found. Its lookup `ls_mandala_deploys` (a mode of
  `mandala-lookup`) answers `{tokenId}` with the deploy output.
- **The token list** (0.7.0; a read, not a BRC-24 query): `mandala-lookup`'s
  fn `tokens` at `/<app>/mandala/tokens`, `{limit?, skip?}` →
  `[{tokenId, topic, sym, dec, icon?, txid, vout}]`, every deploy
  `tm_mandala` admitted, newest first (docs/MANDALA.md "The token list").
- **Token ids** (0.8.1; David, 2026-10-07, shruggr/skein#120). A token id
  is written `<txid>_<vout>` for every token, Mandala and legacy BSV-21
  alike, `_0` included; the bare 32-byte txid is the wire form only (BRC-162
  "Token identification": "For display and APIs, the string form is
  `<txid>_<vout>`"). 0.3.1 to 0.8.0 wrote a Mandala token as the bare
  `<txid>`. The lookups take any of `<txid>`, `<txid>_<vout>` and
  `<txid>.<vout>`. Topic names do not change: `tm_<txid>` for a token at
  output 0 (`tm_<txid>_0` is never produced), `tm_<txid>_<vout>` for a
  BSV-21 token at a non-zero output.
- **Topics registered live.** The manifest declares no topics. A topic is
  served once root registers it with the overlay engine, one call:
  `register {topic, program: "mandala-topic"}`; `deregister {topic}` drops
  it (skein-overlay 0.6.0). The overlay tracks registered tokens only.
- **The library** (Zig module `mandala`): the BRC-162 and BRC-161 output
  parsers and the BSV-21 rules, which the topic manager, the lookup service
  and an application's own programs share.
- **The pages** (`www/`, built from `web/`): deploy a token; root's
  registered token topics. Below, "Pages".

docs/MANDALA.md has each in full and what is not built.

Exported Zig modules:

| module | file | what |
|---|---|---|
| `mandala` | `src/lib.zig` | `brc162` (the binary output parser), `brc161` (the JSON inscription parser), `bsv21` (the rules for one token over a parsed transaction, both forms), `name` (topic names and token id strings), `token` (the topic's verdict). `std` only |

## Use it

**The engine.** The components need skein-overlay 0.7.2 or later, whose
`register` / `deregister` serve topics registered at runtime
(docs/MANDALA.md "Registering a topic"), taken in root's box
`<app>/register` (0.7.7; `<app>/overlay` from 0.6.2), and whose submissions are messages into the
submission box `<app>/submit`, by message and from `POST /submit` (0.7.6;
before, the app's own box `<app>`). `bin/overlay.wasm` here is the v0.10.0
build (skein's routes, filters and roles, shruggr/skein#143: its reads are read
routes whose filters answer, its `register` box root's), whose `POST /submit` is BRC-22 and synchronous again (it answers the
STEAK; 0.9.1, shruggr/skein#112), whose `register` takes `seed` (the tokens page's register seeds a
token's topic with its deploy, 0.7.8), whose listings and documentation
are reads (0.8.0, shruggr/skein#135), and whose `config.overlay.market` /
`config.overlay.validator` make a skein a market and/or a validator (0.9.0,
shruggr/skein#120), which root switches by message (0.9.2).

**On its own** (`etc/app.json`, the reference manifest; the chain app first,
which the overlay requires):

```
skein-host install https://github.com/shruggr/skein-chain --instance <handle>
skein-host install https://github.com/shruggr/skein-mandala --instance <handle>
```

**Register a token's topic**: root's message in the app's box (skein
docs/APPS.md §4), `skein plan` / `skein send` or any BRC-100 wallet, to the
overlay engine (skein-overlay docs/OVERLAY.md "Register a topic"):

```
box:  register   (installed: <app>/register)
body: {"fn": "register", "args": {"topic": "tm_<txid>", "program": "mandala-topic"}}
body: {"fn": "deregister", "args": {"topic": "tm_<txid>"}}
```

The topic is `tm_<txid>`, `tm_<txid>_<vout>` or `tm_mandala` (the
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

**List the tokens** (a read: any method, signed or not):

```
GET <base>/mandala/tokens?limit=20&skip=0
→ [{"tokenId": "<txid>", "topic": "tm_<txid>", "sym": "GOLD", "dec": 8, "icon": "<txid>_<vout>", "txid": "<txid>", "vout": 0}, …]
```

Each answer is an output-list: `{type: "output-list", outputs: [{beef,
outputIndex}]}`, each output with its transaction's BEEF.

### Carry the components in another app

An app that serves Mandala tokens with its own programs beside them (an
AMM) carries these in its tree and manifest:

1. **The programs.** `bin/overlay.wasm` (the engine, skein-overlay
   0.10.0), `bin/mandala-topic.wasm`, `bin/mandala-lookup.wasm`, copied from
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

   Two roles make the skein a market and/or a validator (skein-overlay
   0.9.0; David, 2026-10-06, shruggr/skein#120: registering a token's topic
   is the one act that drives both). They are root's switches, not
   the manifest's (skein-overlay 0.9.2; David, 2026-10-07: "this shouldn't
   have been a config in the manifest. This should be a setting that the
   user is configuring"): a manifest leaves them out, and both are off.

   - **Market**: with it on, each registered topic has liveness on
     `<topic>-live` with a window — the runtime keeps the beats newer than
     it, served at `GET /<app>/.live/<topic>-live`.
   - **Validator**: with it on, each registered topic has a beacon on
     `<topic>-live`, a signed beat every `every` ms with no body; a
     validator program the app carries signs for any registered topic
     while it is on.

   Root turns a role on or off by a message to the engine in the box
   `<app>/register` (the `register` route below), no reinstall:
   `{fn: "market", args: {window: <ms>}}` / `{fn: "market", args: {off:
   true}}`, `{fn: "validator", args: {every: <ms>}}` / `{fn: "validator",
   args: {off: true}}`. On emits liveness / the beacon for every topic
   registered, off ends them; registers and deregisters from then on
   follow the roles in effect. The answer is the roles in effect,
   `{market?: {window}, validator?: {every}}`; the switch is kept beside
   the registered set in `<app>/topics` (`market?` / `validator?`). The
   tokens page (below) has the two switches, Market and Validator (a
   window of 40 s, a beat every 30 s). Root may also turn a role on at
   install, `skein-host install … --config` with `{"overlay": {"market":
   {"window": 40000}, "validator": {"every": 30000}}}`: that is the initial
   value; a switch sent later has precedence. Each value is an integer
   from 1 000 ms to a day.
3. **The routes, filters and roles** (shruggr/skein#143, skein docs/APPS.md
   §2: a route names its transport, address, filters and handler, no
   sender; who may run a function is `roles`), as in `etc/app.json`:
   - `{"address": "register", "handler": "overlay.register"}` with `roles:
     {"root": ["register", "market", "validator"]}`: root's message reaches
     the engine's `register` / `deregister` and the switches (the function
     the engine runs is the body's `fn`); a message from any other key is
     recorded and runs nothing. The address is relative: the install
     resolves it to `<app>/register` (skein#128).
   - `{"address": "submit", "filters": ["kernel.beef"], "handler":
     "overlay.submit"}`: the submission box `<app>/submit`, anyone whose
     BEEF validates, where a submission is a message `{fn: "submit", args:
     {beef, topics}}` (skein-overlay 0.7.6). No route of the app's own on
     `<app>`: that box is the engine's, derived by the install.
   - **The read routes** (an http route with no handler: its filters
     answer, anyone, signed or not, nothing logged): the four listing and
     documentation paths of the engine (`{"transport": "http", "address":
     "/listTopicManagers", "filters": ["listTopicManagers"]}`, … with
     `filters: {"listTopicManagers": "overlay.listTopicManagers",
     "listLookupServiceProviders": …, "topicDocumentation": …,
     "lookupDocumentation": …}`) and the token list `{"transport": "http",
     "address": "/mandala/tokens", "filters": ["tokens"]}` with `filters.tokens
     = "mandala-lookup.tokens"`. Called as a filter, `mandala-lookup`'s
     `tokens` answers `{answer: <the http answer>}` (0.8.0).
4. **The register call**, made by root once the app is installed, one
   per topic it runs: `{"fn": "register", "args": {"topic": "tm_<txid>",
   "program": "mandala-topic"}}` (and `tm_mandala` the same way);
   `{"fn": "deregister", "args": {"topic"}}` drops one.
5. **`requires: ["chain/1"]`.**

The rest (the http route `/submit`, the read route `/lookup` and its filter
`lookup`, the box `<app>` as an event route and a mailbox route) is derived
from `config.overlay` by the install; a registered topic's gossip is routed
by the engine's `subscribe` events (skein #119), not by routes. Keep the box
`<app>` the engine's: a route of your own there overrides the derived
mailbox route, and the engine's own watch, resume and wait would go to it.

A program of the app's own that reads token outputs depends on the
`mandala` module (below) for the parsers and the rules.

## Depend on the library

`build.zig.zon`:

```zig
.dependencies = .{
    .skein_mandala = .{
        .url = "https://github.com/shruggr/skein-mandala/archive/refs/tags/v0.8.1.tar.gz",
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
var buf: [mandala.name.max_suffix_len]u8 = undefined;
const text = mandala.name.tokenIdText(&buf, mandala.name.tokenIdOfString("<txid>").?); // "<txid>_0"
const j = try mandala.bsv21.judge(a, id, tx, previous_coins); // the rules over a bsv21.Tx
```

## Pages

Two static pages, for an app that carries the components (README "Carry
the components in another app") to serve. The Mandala app is not installed
by itself, so the pages are not served from this repo's manifest.

Every txid, token id, outpoint and topic the pages show is shortened, shown
whole on a click, and has a copy button; an outpoint is shown `<txid>.<vout>`,
and the underscore appears only in a token id, `<txid>_<vout>` for every
token (`<txid>_0` included; 0.8.1), and a legacy token's topic (0.7.4; David,
2026-10-08).

| page | served at | what |
|---|---|---|
| deploy | `/<app>/mandala/deploy/` | **Deploy a token.** Open to anyone: a helper over the user's own wallet. Fields: symbol, decimals (0 to 18), fixed supply (an amount in whole tokens) or authority (amount 0, the deploy output mints), an optional icon outpoint (`txid.vout`; `txid_vout` is taken too). `@1sat/actions`' `deployMandala` builds the BRC-162 deploy at output 0, the wallet (connected through `@1sat/connect`) signs and broadcasts it and files it (basket `mandala <txid> 0`). Then the page submits the deploy (the AtomicBEEF the action returns) to the overlay it is served from: `POST <base>/<app>/submit`, the BEEF as the body, `X-Topics: tm_mandala` only (the token's own topic `tm_<txid>` did not exist before this transaction, so nobody serves it yet). The page POSTs itself, unsigned, by plain `fetch` (0.7.5; David, 2026-10-08: "We shouldn't be using authfetch for the submit http method"): the skein admits an unsigned POST at a route whose filter validates the payload (shruggr/skein#135, #143), and the `/submit` route's filter is `kernel.beef`. (0.6.1 to 0.7.4 signed it through the wallet's AuthFetch, which refuses the `X-Topics` header.) Not through `deployMandala`'s `overlay` option (that hardcodes its topic list). The answer is BRC-22's STEAK (skein-overlay 0.9.1; 0.7.2 here): the page shows the topics that admitted outputs, or "taken by no topic", or, on a 503 + `Retry-After`, "not decided yet" (the submission stands; Submit again polls it); the discovery topic has the deploy once admitted (lookup `ls_mandala_deploys`). An overlay that does not serve `tm_mandala` takes the submit and admits nothing. The page shows the token id, `<txid>_0` (0.8.1; every token is `<txid>_<vout>`), and the topic to register, `tm_<txid>`, which root copies to the tokens page to register. If the filing step fails after the broadcast, "File it again" runs the SDK's `fileMandalaDeploy`; if the submit fails, "Submit again". |
| tokens | `/<app>/mandala/tokens/` | **Tokens on this overlay.** Root's page (the key that claimed the instance, or one root granted; shruggr/skein#143). Lists the registered topics judged by `mandala-topic` (the overlay engine's head `<app>/topics`, `{kind: "overlay-topics", topics: [{topic, program}]}`, read through the instance's explorer, `/explore/head/<app>/topics`, which is root's read). Register by topic name (`tm_<txid>` or `tm_<txid>_<vout>`), deregister a listed topic, and a switch that registers or deregisters the discovery topic `tm_mandala`. Each change is root's message to the app's box `<app>/register`, the engine's `{fn: "register", args: {topic, program: "mandala-topic", seed?}}` or `{fn: "deregister", args: {topic}}`, sent the way skein-site sends root's messages (skein's `RawBox.send`: a BRC-104-signed `POST <base>/sendMessage`, BRC-231 CBOR, recipient the instance's identity from its signed answers). The outcome is the step's result record (`{kind: "overlay-result", op, topic, active, changed}` or `{op, error}`), whose CID the step prints on stdout, read from the thread the message launched; then the set is read again. A wallet that does not hold root gets the explorer's 403, and its messages run nothing (the route `register` is gated by root: recorded, no step). **The token's own deploy** (0.6.2, skein-overlay 0.7.8): a register of `tm_<txid>` (or `tm_<txid>_<vout>`) carries `seed: [<txid>]`, the deploy; the engine judges the deploy under the new topic from what the instance's chain state already holds, and the answer says `seeded` or `missing` (`untaken`: held, but the topic took nothing of it). The page shows which. Seeded, nothing more is sent. Missing (the overlay never held the deploy: a token deployed elsewhere, or before discovery), the connected wallet's copy: `listOutputs` on the token's basket `mandala <txid> <vout>` with `include: "entire transactions"` (the wallet that deployed it holds it there until the deploy output is spent), submitted under both `tm_mandala` and `tm_<txid>`. Before 0.6.2 the page looked the deploy up (`ls_mandala_deploys`) and resubmitted it after the register; the seed replaces that. Each registered token has "Submit deploy to this overlay", on demand: the deploy's BEEF from the discovery lookup (`POST <base>/<app>/lookup {service: "ls_mandala_deploys", query: {tokenId}}`, the token id `<txid>_0` or `<txid>_<vout>` from the topic), submitted with `X-Topics: tm_<txid>`, else the wallet's copy as above. The lookup is a POST through the instance's BRC-104 client, as the reads do (0.6.1); the submit is a plain `fetch`, unsigned, as on the deploy page (0.7.5). The page shows the answer (the STEAK in words, or not decided yet; 0.7.2) and where the BEEF came from. **Market and Validator** (0.7.3, skein-overlay 0.9.2): two switches, the engine's roles, each root's message to `<app>/register` as register is (`{fn: "market", args: {window: 40000} | {off: true}}`, `{fn: "validator", args: {every: 30000} | {off: true}}`); the page shows the answer, the roles in effect, and reads them on load from the set's record `<app>/topics` (the switch, once sent) over the app record's `config.overlay.market` / `.validator` (`<app>/app`). |

The page takes the app's name and the instance from its own URL:
`<base>/<app>/mandala/<page>/`, where `<base>` is the instance's origin or a
host's `/@<handle>` dev form. So the same files work under any app name.

**Embedding.** The app's build copies `www/*` into its own `www/mandala/`
(`www/mandala/deploy/index.html`, `www/mandala/tokens/index.html`,
`www/mandala/assets/…`), and its static rows serve that directory under
`/<app>/` (skein-static's README has the rows). Asset paths are relative, so
`/<app>/mandala/deploy` (redirected to `…/deploy/`) loads them from
`/<app>/mandala/assets/`. Nothing is built on the skein: `www/` is committed
as built. The token list read is `/<app>/mandala/tokens` without the slash
(0.7.0): an exact read takes that path, so the tokens page is reached at
`/<app>/mandala/tokens/` only (the slash-less path answers the JSON list,
not the redirect to the page).

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
npm test                               # vitest: the page's place from its URL, the deploy input and the SDK's deploy from it, root's calls, the registered set and the answers, the sendMessage request, the deploy's submit, the register → lookup → submit chain and the wallet fallback
npm run typecheck
```

The stack is the AMM pages' (amm-poc `web/ui`): Vite, React, `@1sat/react`
and `@1sat/connect` for the wallet, `@1sat/actions` for the deploy. Root's
messages and the explorer reads are skein's own client
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

`bin/overlay.wasm` is copied from skein-overlay v0.10.0's build (`zig build
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
| this app, its programs and package | 0.8.1 (tag `v0.8.1`) |
| the pages | `@1sat/actions` 0.0.233, `@1sat/react` 0.0.102, `@1sat/connect` 0.0.104, `@1sat/templates` 0.0.43, `@bsv/sdk` 2.8.6 (`web/package.json`, exact); skein's client at `web/lib/SKEIN_REV` |
| skein-overlay | v0.10.0 by tag URL and hash in `build.zig.zon` (modules `topic`, `lookup`, `sk`); the engine in `bin/` is its build |
| skein-sdk | v0.7.1, through skein-overlay (modules `chain`, `sk`, `cbor`) |
| requires | `chain/1` (shruggr/skein-chain 0.3.0) |
| skein | log format 9, the routes / filters / roles manifest (shruggr/skein#143; 0.8.0: `dispatch` and `reads` became `routes`, the `register` box root's, the reads read routes whose filters answer) |

The token library and its tests moved here from amm-poc
`programs/amm-topic` (shruggr/skein#120); its fixtures
(`src/fixtures/vectors.zig`) are generated there by `gen/main.go` from the
AMM's Pool contract.

## Contributing

Work is tracked in shruggr/skein; start at issue
[#31](https://github.com/shruggr/skein/issues/31), this repo's issue is
[#120](https://github.com/shruggr/skein/issues/120). MIT, as skein.
