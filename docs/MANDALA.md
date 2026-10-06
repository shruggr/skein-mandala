# Mandala on a skein

Mandala tokens (BRC-162) served by a skein overlay: one topic per token, a
lookup service over the topics, and the topics the owner registers live.
Decided in shruggr/skein#120 (walkthrough 2026-10-05): components, not one
app; one topic per token; the protocol first; governance later, per token.

## The components

| component | file | role | what |
|---|---|---|---|
| topic manager | `bin/mandala-topic.wasm`, `src/mandala_topic.zig` | `mandala-topic` | judges `tm_<txid>` by the token rules |
| lookup service | `bin/mandala-lookup.wasm`, `src/mandala_lookup.zig` | `mandala-lookup` | `ls_mandala`: three queries over its own index; `ls_mandala_deploys`: a token's deploy output |
| discovery topic | the same program as the topic manager | `mandala-topic` | `tm_mandala`: every token's deploy output |
| the library | `src/lib.zig` (module `mandala`) | | the parsers, the rules, topic names, the verdict |
| the engine | `bin/overlay.wasm` | `overlay` | shruggr/skein-overlay 0.7.8: serves the topics, keeps the registered set (`register` / `deregister`) |

The topic manager and the lookup service are programs on skein-overlay's
contracts (`topic`, `lookup`). An app carries them in its tree with the
engine and names them in `config.overlay` (README "Carry the components in
another app"). This repo's `etc/app.json` is a manifest of the three alone.

## The topic

**Names** (`src/name.zig`). `<txid>` is the deploy txid, 64 lowercase hex
characters in display order.

- `tm_<txid>`: a token deployed at output 0. Its genesis is a binary
  deploy (id `OP_0`) or a BRC-161 `deploy+mint` / `deploy+auth`
  inscription there; on the wire its id is the 32-byte txid.
  BRC-162 "Token identification": a BRC-161 token deployed at output 0 is
  the same token in both forms.
- `tm_<txid>_<vout>`: a token deployed under BRC-161 at a non-zero output.
  Its binary outputs carry the 36-byte id, the only tokens that have one.
- `tm_<txid>_0` is not a topic name and is never produced.

**Token ids** (`src/name.zig` `tokenIdOfString`, `tokenIdText`; `src/token.zig`
`originOf`; BRC-162 "Token identification"). A token id is the deploy
outpoint, and how it is written depends on the token's origin, which is the form of its deploy:

- a token that originated as **Mandala** (a binary deploy, always at output
  0) is written as the bare `<txid>`;
- a token that originated as **BSV-21** (a BRC-161 JSON deploy) is written
  `<txid>_<vout>`, and `<txid>_0` for one deployed at output 0.

Input takes any form: `<txid>`, `<txid>_<vout>` or the BRC-36
`<txid>.<vout>`. `<txid>`, `<txid>_0` and `<txid>.0` all name the
token at output 0, whatever its origin. Output prints the origin's form. The
origin is known only from the deploy output. The topic and its name do
not record it.

**The rule** (`src/bsv21.zig`, `src/token.zig`): BRC-162 and BRC-161
"Validation rules" for the topic's token, over the transaction and the
outputs its inputs spend.

- An output is binary when it carries a valid BRC-162 prefix, else JSON
  when it carries a valid BSV-21 inscription, else not a token output.
- The deploy is admitted at the token's deploy outpoint only.
- An authority output (amount 0, JSON `auth`) and a mint (a binary value
  output, a JSON `mint`) are admitted only when the transaction spends an
  authority of the token.
- Every other value output, and every JSON `burn`, is balance-checked
  against the token's inputs, all together: admitted when the inputs cover
  them, none of them when they do not. An excess is an implicit burn.
- Once a transaction spends a binary output of the token, its JSON outputs
  of that token are not admitted (one-way migration) and count for nothing.
- A transaction whose balance-checked outputs fail and which has nothing
  else of the token admits and retains nothing. Otherwise its admitted
  outputs stand and the token coins it spends are retained.

Only inputs that are previous coins (outputs of the token the topic holds)
count. The topic knows no application: a contract's output is admitted
exactly when the rules admit it. There is no ownership, authority-chain or
control check.

**Metadata and documentation** (skein-overlay#2): the topic's name, a
one-line description naming the token (a token at output 0 by its deploy
txid, since the topic does not know its origin), version 0.4.0; the documentation is
the rule above in markdown.

## The lookup

`ls_mandala`, the query shapes of the ts-stack Mandala lookup
(`packages/overlays/topics/src/mandala/MandalaLookupDocs.md.ts`). The first
key present, in this order, answers:

| query | answer |
|---|---|
| `{authoritiesTokenId, limit?, skip?}` | the token's unspent authority outputs, its deploy among them, in outpoint order |
| `{tokenId, limit?, skip?}` | the token's unspent value outputs, in outpoint order |
| `{txid, outputIndex}` | the value or authority output at that outpoint, if unspent |

- A token id is taken as `<txid>`, `<txid>_<vout>` or `<txid>.<vout>`
  ("Token ids" above). Lowercase hex in display order; the vout decimal
  without leading zeros.
- `limit` 1 to 100 (default 100), `skip` 0 to 100000 (default 0). Any other
  key, or a value out of shape, is refused.
- Outpoint order is the txid in display order, then the output index (the
  ts-stack sort).
- The answer is an output-list of outpoints, with no token id strings. The
  engine builds each output's BEEF from the chain state, and the service never
  handles one. A client that writes the token's id reads the origin from
  the deploy output (`ls_mandala_deploys`, or the authorities answer): a
  binary deploy is `<txid>`, a JSON one `<txid>_<vout>`.

**The index** is three maps under the head `<app>/ls_mandala`, kept by the
lookup hooks the engine calls in the step that admits or rejects:

| map | key | value |
|---|---|---|
| `values` | token ‖ outpoint | — |
| `authorities` | token ‖ outpoint | — |
| `outputs` | outpoint | kind ‖ token, then the spender's txid once spent |

(token: its deploy txid in display order ‖ vout, 4 bytes big-endian; an
outpoint the same.) `admitted` classifies each admitted output by the rules
for the topic's token: a deploy or an authority into `authorities`, a value
(a transfer or a mint) into `values`, a JSON `burn` into neither. `spent`
takes the output out of its index and records the spender. `rejected`
removes the transaction's outputs and returns the outputs it had spent. A
hook for a topic that is not a token's does nothing.

## The discovery topic

`tm_mandala` (#120 item 11): one fixed topic, not per token, that
admits deploy outputs only, of every token. It is a registry of what tokens
exist and the metadata each was deployed with (the deploy's payload:
decimals, symbol, icon, ...).

- `mandala-topic` judges it when called with that topic name (token.zig
  `judgeDeploys`): an output is admitted when it is a valid deploy by the
  rules above, a BRC-162 deploy (id `OP_0`) at output 0 or a BRC-161
  `deploy+mint` / `deploy+auth` inscription at any output. Nothing else is
  admitted, and nothing about governance is checked. The coins an admitted
  transaction spends are retained.
- `ls_mandala_deploys` is `mandala-lookup` called as that service. Its map
  `deploys` (token → nothing; a token id is its deploy outpoint) holds every
  deploy the topic admitted. `{tokenId}` answers the deploy output, an
  output-list of one (empty if none); any other key is refused. A deploy
  stays listed once spent (a registry); a rejected transaction's deploys are
  removed. This is the shape of ts-stack's `metadataTokenId`, under its own
  key.
- It is switched like a token: registered with `register {topic:
  "tm_mandala", program: "mandala-topic"}`, dropped with
  `deregister`. It is not in `config.overlay.topics`: an entry there is
  served from the install on, which no message can turn off.

## Registering a topic

The overlay serves only the topics the owner registered (#120 item 2; the
call is the engine's, skein-overlay 0.6.0 (the owner's box `<app>/register`
since 0.7.7, `<app>/overlay` from 0.6.2), docs/OVERLAY.md "Register a topic"). The manifest declares no topics; there are no topic prefixes
anywhere, in the configuration or in the rows.

1. The owner sends `{fn: "register", args: {topic, program:
   "mandala-topic"}}` to the app's box `<app>/register`. The topic is
   `tm_<txid>`, `tm_<txid>_<vout>` or `tm_mandala`; it follows from
   how the token was deployed (the deploy page shows it). The row
   `{address: "register", sender: "$owner", program: "overlay"}` (relative;
   the install resolves it to `<app>/register`, skein#128) takes it to the
   engine.
2. The engine adds `{topic, program}` to its registered set, the head
   `<app>/topics` (`{kind: "overlay-topics", topics: [{topic, program}, …]}`,
   sorted, each once), and advances the head.
3. In the same step it emits `{event: "subscribe", topic, program, fn}` for
   `<topic>` (`submit`), `<topic>-admit` (`peerAdmit`) and `<topic>-proof`
   (`peerProof`), `program` the engine's role. The host subscribes them
   and routes their messages by these events (skein #119).
4. With `seed: [txid, …]` (skein-overlay 0.7.8; the tokens page sends
   the deploy's txid), the engine then judges each seed the instance's
   chain state holds under the new topic only, oldest first over its held
   ancestry, and admits it from the state — a token's topic gets its own
   deploy without a resubmission.
5. The step's result record is `{kind: "overlay-result", op: "register",
   topic, active: true, changed, seeded?, missing?}`; the engine also
   answers `{fn, request, replyTo, result: {topic, active, seeded?,
   missing?}}` to a sender a message can reach. A seed `missing` (the
   overlay never held it) is submitted the usual way.
6. From the next step the engine serves the topic, judged by
   `mandala-topic`: `/submit` with it in `X-Topics`, gossip on it, the
   listing, and both lookups (which list no `topics`, so they listen to
   every topic served).

`{fn: "deregister", args: {topic}}` removes it and emits `unsubscribe` for
the same three. Both are idempotent: registering a registered topic, or
deregistering one that is not, writes and emits nothing. A topic registered
with another program is refused (deregister it first). Deregistering does
not remove what the topic admitted or the lookup's index of it.

## The manifest

`etc/app.json`, and what an app that carries the components puts in its own
(README "Carry the components in another app"):

- `programs`: `overlay` (`bin/overlay.wasm`), `mandala-topic`,
  `mandala-lookup`;
- `config.overlay`: no `topics`; `lookups` `ls_mandala` and
  `ls_mandala_deploys`, each `{"program": "mandala-lookup"}` with no
  `topics` list;
- the rows: `{"address": "register", "sender": "$owner", "program":
  "overlay"}` (the owner's `register` / `deregister`, box `<app>/register`),
  `{"address": "submit", "sender": "*", "program": "overlay", "filter":
  "beef"}` (the submission box `<app>/submit`: submissions by message and
  from `POST /submit`, skein-overlay 0.7.6; no `""` row) and the four listing and documentation
  http rows;
- `requires: ["chain/1"]`.

A manifest MAY pre-declare topics in `config.overlay.topics` (an overlay
with fixed topics, e.g. OpNS's one global topic); they are served beside
the registered ones. Mandala's topics are dynamic, so it declares none.

## Not built

- **Governance** (#120 item 4: layers B to D). Ownership by BRC-42 key
  linkage (B); authority chains and `deploySig` from trusted issuers (C);
  controls: freeze, pause, access mode, sanctions screening, registry
  membership (D). For skein they are one profile set per token at
  registration, with that token's trusted issuers and registry; a token
  without one is the protocol alone, as now. The port follows Deggen's
  manager in ts-stack `packages/overlays/topics/src/mandala` (BRC-162 since
  0211fd965): `ownership.ts`, `verifyKeyLinkage.ts`, `authority.ts`,
  `deploySig.ts`, `controls.ts`, `AssetStateReducer.ts`.
- **The registry**: the registry token and its topic and lookup, ts-stack
  `src/mandala-registry`.
- **The other three queries**: `metadataTokenId` (the deploy output; the
  discovery lookup answers the same as `{tokenId}`),
  `assetStateTokenId` (the token's admin state), `adminHistoryTokenId`
  (committed admin actions in fold order); ts-stack
  `src/mandala/MandalaLookupService.ts`. They answer from governance state.
- **An all-tokens topic**: one topic for every output of every Mandala
  token (wanted later for the 1sat hosted service). It gets its own name
  when it comes (Deggen's has `tm_mandala_registry`). The discovery topic
  holds deploys only; it is named `tm_mandala` (0.6.0, was
  `tm_mandala_deploys`), the name Deggen's uses too.
- A registration profile (#120 item 5: the manager's settings in the app
  record), and an equivalence test in skein.
