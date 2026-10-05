# Mandala on a skein

Mandala tokens (BRC-162) served by a skein overlay: one topic per token, a
lookup service over the topics, and a token list the owner changes live.
Decided in shruggr/skein#120 (walkthrough 2026-10-05): components, not one
app; one topic per token; the protocol first; governance later, per token.

## The components

| component | file | role | what |
|---|---|---|---|
| topic manager | `bin/mandala-topic.wasm`, `src/mandala_topic.zig` | `mandala-topic` | judges `tm_<txid>` by the token rules; keeps the token list (`mandala.tokens/1`) |
| lookup service | `bin/mandala-lookup.wasm`, `src/mandala_lookup.zig` | `mandala-lookup` | `ls_mandala`: three queries over its own index; `ls_mandala_deploys`: a token's deploy output |
| discovery topic | the same program as the topic manager | `mandala-topic` | `tm_mandala_deploys`: every token's deploy output |
| the library | `src/lib.zig` (module `mandala`) | | the parsers, the rules, topic names, the verdict |
| the engine | `bin/overlay.wasm` | `overlay` | shruggr/skein-overlay 0.5.0 |

The topic manager and the lookup service are programs on skein-overlay's
contracts (`topic`, `lookup`). An app carries them in its tree with the
engine and names them in `config.overlay` (README "Carry the components in
another app"). This repo's `etc/app.json` is a manifest of the three alone.

## The topic

**Names** (`src/name.zig`). `<txid>` is the deploy txid, 64 lowercase hex
characters in display order.

- `tm_<txid>`: a token deployed at output 0. Its genesis is a binary
  deploy (id `OP_0`) or a BRC-161 `deploy+mint` / `deploy+auth`
  inscription there; its id is `<txid>_0`, on the wire the 32-byte txid.
  BRC-162 "Token identification": a BRC-161 token deployed at output 0 is
  the same token in both forms.
- `tm_<txid>_<vout>`: a token deployed under BRC-161 at a non-zero output.
  Its binary outputs carry the 36-byte id, the only tokens that have one.
- `tm_<txid>_0` is not a topic name and is never produced.

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
one-line description naming the token, version 0.2.0; the documentation is
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

- A token id is `<txid>_<vout>`: `<txid>_0` for a token deployed at output
  0 (either form), the deploy outpoint of a BRC-161 token at a non-zero
  output. Lowercase hex in display order; the
  vout decimal without leading zeros.
- `limit` 1 to 100 (default 100), `skip` 0 to 100000 (default 0). Any other
  key, or a value out of shape, is refused.
- Outpoint order is the txid in display order, then the output index (the
  ts-stack sort).
- The answer is an output-list of outpoints. The engine builds each output's
  BEEF from the chain state; the service never handles one.

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

`tm_mandala_deploys` (#120 item 11): one fixed topic, not per token, that
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
- It is switched like a token: `mandala.tokens.activate {topic:
  "tm_mandala_deploys"}` puts it on the same list, and the topic is served
  under the `tm_` prefix with the same events. It is not in
  `config.overlay.topics`: an entry there is served and subscribed from the
  install on, which no message can turn off.

## Activation

The overlay serves only the tokens the owner activated (#120 item 2, on
skein #119).

1. The owner sends `{fn: "mandala.tokens.activate", args: {tokenId}}` (or `{topic}`) to the
   app's box. The row `{address: <app>, sender: "$owner", program:
   "mandala-topic"}` takes it; the SDK's dispatch helper checks the args
   against `provides`.
2. `mandala-topic` reads the list at the head `<app>/mandala`, `{kind:
   "mandala-tokens", topics: [<topic>, …]}` (sorted, each once), adds the
   token's topic, and advances the head.
3. In the same step it emits three events, `{event: "subscribe", topic}`
   for `<topic>`, `<topic>-admit`, `<topic>-proof`. The kernel records them
   with the app's name.
4. It answers the owner `{tokenId, topic, active: true}`.
5. After the commit the host's libp2p node subscribes the three topics for
   the app, because its prefix row `tm_` takes them (skein docs/OVERLAY.md
   "How an overlay app activates a token topic live"). After a restart the
   node reads them back from the log.
6. From the next step, the engine serves the topic: `/submit` with it in
   `X-Topics`, gossip on it, the listing.

`deactivate` removes the topic from the list and emits `unsubscribe` for the
same three. Activating an active token, or deactivating an inactive one,
writes and emits nothing; the answer is the same. Deactivating does not
remove what the topic admitted or the lookup's index of it.

## The engine

The engine reads the list through `config.overlay.prefixes` (skein-overlay
0.5.0):

```json
"prefixes": {"tm_": {"program": "mandala-topic", "active": "mandala"}}
```

At every step and call it reads the root record of `<app>/<active>` and
serves each listed topic that starts with the prefix as if
`config.overlay.topics` named it, judged by `program`. A lookup service in
the object form with `"prefixes": ["tm_"]` listens to those topics. A
message on `<topic>-admit` or `<topic>-proof` that reaches `submit` through
the one prefix row goes to `peerAdmit` or `peerProof`. Nothing else in the
engine changed.

## Not built

- **Governance** (#120 item 4: layers B to D). Ownership by BRC-42 key
  linkage (B); authority chains and `deploySig` from trusted issuers (C);
  controls: freeze, pause, access mode, sanctions screening, registry
  membership (D). For skein they are one profile set per token at
  activation, with that token's trusted issuers and registry; a token
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
  when it comes; Deggen's are `tm_mandala` and `tm_mandala_registry`. The
  discovery topic holds deploys only.
- An activation profile (#120 item 5: the manager's settings in the app
  record), a list function, and an equivalence test in skein.
