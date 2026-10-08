//! mandala-lookup: `ls_mandala`, the Mandala (BRC-162) lookup service
//! (shruggr/skein#120 item 3). It indexes the outputs the Mandala topics
//! admit, through the skein-overlay lookup hooks, under its own head
//! `<app>/ls_mandala`, and answers three queries in the shapes of the ts-stack
//! Mandala lookup (packages/overlays/topics/src/mandala/MandalaLookupDocs.md.ts):
//!
//!   {tokenId, limit?, skip?}             the token's unspent value outputs, in outpoint order
//!   {authoritiesTokenId, limit?, skip?}  the token's unspent authority outputs (and its deploy), in outpoint order
//!   {txid, outputIndex}                  the value or authority output at that outpoint, if unspent
//!
//! The first of `authoritiesTokenId`, `tokenId` present answers; else the
//! outpoint. `limit` is 1 to 100 (default 100), `skip` 0 to 100000 (default
//! 0). Any other key, or a value out of shape, is refused. A token id is
//! taken as `<txid>`, `<txid>_<vout>` or `<txid>.<vout>` (name.zig
//! `tokenIdOfString`): `<txid>` and `<txid>_0` are the token deployed at
//! output 0 (either form), a non-zero vout the deploy outpoint of a BRC-161
//! one. A token id is written `<txid>_<vout>` for every token, `_0` included
//! (BRC-162 "Token identification"; David, 2026-10-07): the bare txid is the
//! wire form only. Answers are output-lists (outpoints, no token id strings); the engine
//! builds each output's BEEF from the chain state.
//!
//! The maps (`tok` = the token's deploy txid in display order ‖ vout, u32 BE;
//! `op` = an outpoint's txid in display order ‖ vout, u32 BE, so key order is
//! outpoint order: txid hex, then index):
//!
//!   values       tok ‖ op → null                 unspent value outputs
//!   authorities  tok ‖ op → null                 unspent authority outputs and deploys
//!   outputs      op → kind (0 value, 1 authority) ‖ tok [‖ spending txid, internal order]
//!
//! `admitted` classifies each admitted output by the BSV-21 rules for the
//! topic's token (bsv21.zig `tokenOf`): a deploy or an authority goes in
//! `authorities`, a value (transfer or mint) in `values`, a BRC-161 burn in
//! neither. `spent` takes the output out of its index and records its
//! spender; `rejected` drops the transaction's outputs and gives back the
//! ones it had spent. A hook for a topic that is not a token's does nothing.
//!
//! The same program is the discovery lookup `ls_mandala_deploys` (by the
//! service name it is called as): over `tm_mandala` only, the map
//!
//!   deploys      tok → null                       every admitted deploy (a token id is its deploy outpoint)
//!
//! `admitted` adds each valid deploy output (token.zig `deployOf`), `spent`
//! does nothing (a registry), `rejected` removes the transaction's deploys;
//! `{tokenId}` answers the deploy output, an output-list of one.
const std = @import("std");
const c = @import("chain");
const lookup = @import("lookup");
const mandala = @import("mandala");

const bsv21 = mandala.bsv21;
const token = mandala.token;

const Value = c.cbor.Value;
const Allocator = std.mem.Allocator;
const Service = lookup.Service;
const eql = std.mem.eql;

pub const service_name = "ls_mandala";
/// The discovery topic's lookup (shruggr/skein#120 item 11): `{tokenId}` → the token's deploy output.
pub const deploys_service = mandala.name.deploys_service;
const deploys_topic = mandala.name.deploys_topic;

fn isDeploys(svc: *const Service) bool {
    return eql(u8, svc.name, deploys_service);
}

pub const spec: lookup.Spec = .{
    .maps = &.{ "values", "authorities", "outputs", "deploys" },
    .answer = answer,
    .admitted = admitted,
    .spent = spent,
    .rejected = rejected,
};

pub const max_limit = 100;
pub const max_skip = 100_000;

const Kind = enum(u8) { value = 0, authority = 1 };

fn display(txid: [32]u8) [32]u8 {
    var r = txid;
    std.mem.reverse(u8, &r);
    return r;
}

/// A token's key: its deploy txid in display order ‖ vout (BE).
fn tokKey(id: bsv21.TokenId) [36]u8 {
    return display(id.txid) ++ c.store.be32(id.vout);
}

/// An outpoint's key: its txid in display order ‖ vout (BE).
fn opKey(txid: [32]u8, vout: u32) [36]u8 {
    return display(txid) ++ c.store.be32(vout);
}

fn opOf(key: []const u8) lookup.Output {
    return .{ .txid = display(key[0..32].*), .vout = std.mem.readInt(u32, key[32..36], .big) };
}

fn indexName(k: Kind) []const u8 {
    return switch (k) {
        .value => "values",
        .authority => "authorities",
    };
}

fn cat(a: Allocator, parts: []const []const u8) ![]u8 {
    return std.mem.concat(a, u8, parts);
}

/// The kind of output `vout` of `tx` is for token `id`, or null (not its, or a BRC-161 burn).
fn kindOf(a: Allocator, id: bsv21.TokenId, tx: lookup.Tx, vout: u32) !?Kind {
    if (vout >= tx.tx.outputs.len) return error.BadArgs;
    const t = (try bsv21.tokenOf(a, id, tx.txid, vout, tx.tx.outputs[vout].locking_script.bytes)) orelse return null;
    return switch (t.role) {
        .deploy, .authority => .authority,
        .value => .value,
        .burn => null,
    };
}

fn admitted(a: Allocator, svc: *Service, topic: []const u8, tx: lookup.Tx, outputs_to_admit: []const u32, _: []const u32) anyerror!void {
    if (isDeploys(svc)) {
        if (!eql(u8, topic, deploys_topic)) return;
        for (outputs_to_admit) |vout| {
            if (vout >= tx.tx.outputs.len) return error.BadArgs;
            const id = (try token.deployOf(a, tx.txid, vout, tx.tx.outputs[vout].locking_script.bytes)) orelse continue;
            try svc.map("deploys").add(&tokKey(id));
        }
        return;
    }
    const id = token.tokenIdOf(topic) orelse return;
    const tk = tokKey(id);
    for (outputs_to_admit) |vout| {
        const k = (try kindOf(a, id, tx, vout)) orelse continue;
        const op = opKey(tx.txid, vout);
        try svc.map("outputs").put(&op, .{ .bytes = try cat(a, &.{ &.{@intFromEnum(k)}, &tk }) });
        try svc.map(indexName(k)).add(try cat(a, &.{ &tk, &op }));
    }
}

/// An `outputs` entry: its kind, its token key, its spender if spent.
const Entry = struct { kind: Kind, tok: []const u8, spender: ?[]const u8 };

fn entryOf(v: c.store.MValue) !Entry {
    if (v != .bytes or (v.bytes.len != 37 and v.bytes.len != 69) or v.bytes[0] > 1) return error.BadIndex;
    return .{ .kind = @enumFromInt(v.bytes[0]), .tok = v.bytes[1..37], .spender = if (v.bytes.len == 69) v.bytes[37..69] else null };
}

fn spent(a: Allocator, svc: *Service, topic: []const u8, outpoint: lookup.Outpoint, spending: lookup.Tx) anyerror!void {
    if (isDeploys(svc)) return; // a registry: a deploy stays listed once spent
    _ = token.tokenIdOf(topic) orelse return;
    const op = opKey(outpoint.txid, outpoint.vout);
    const v = (try svc.map("outputs").get(&op)) orelse return; // not one it indexed
    const e = try entryOf(v);
    if (e.spender != null) return;
    _ = try svc.map(indexName(e.kind)).remove(try cat(a, &.{ e.tok, &op }));
    try svc.map("outputs").put(&op, .{ .bytes = try cat(a, &.{ v.bytes, &spending.txid }) });
}

fn rejected(a: Allocator, svc: *Service, topic: []const u8, tx: lookup.Tx) anyerror!void {
    if (isDeploys(svc)) {
        if (!eql(u8, topic, deploys_topic)) return;
        for (tx.tx.outputs, 0..) |o, vout| {
            const id = (try token.deployOf(a, tx.txid, @intCast(vout), o.locking_script.bytes)) orelse continue;
            _ = try svc.map("deploys").remove(&tokKey(id));
        }
        return;
    }
    _ = token.tokenIdOf(topic) orelse return;
    // Its outputs vanish.
    for (0..tx.tx.outputs.len) |vout| {
        const op = opKey(tx.txid, @intCast(vout));
        const v = (try svc.map("outputs").get(&op)) orelse continue;
        const e = try entryOf(v);
        _ = try svc.map(indexName(e.kind)).remove(try cat(a, &.{ e.tok, &op }));
        _ = try svc.map("outputs").remove(&op);
    }
    // What it spent is unspent again.
    for (tx.tx.inputs) |in| {
        const op = opKey(in.previous_outpoint.txid.bytes, in.previous_outpoint.index);
        const v = (try svc.map("outputs").get(&op)) orelse continue;
        const e = try entryOf(v);
        const by = e.spender orelse continue;
        if (!eql(u8, by, &tx.txid)) continue;
        try svc.map("outputs").put(&op, .{ .bytes = try a.dupe(u8, v.bytes[0..37]) });
        try svc.map(indexName(e.kind)).add(try cat(a, &.{ e.tok, &op }));
    }
}

const allowed = [_][]const u8{ "tokenId", "authoritiesTokenId", "txid", "outputIndex", "limit", "skip" };

/// An integer field in [lo, hi], `default` when absent.
fn intField(q: Value, key: []const u8, default: u64, lo: u64, hi: u64) !u64 {
    const v = q.get(key) orelse return default;
    if (v != .uint or v.uint < lo or v.uint > hi) return error.BadQuery;
    return v.uint;
}

fn tokenField(q: Value, key: []const u8) !?bsv21.TokenId {
    const v = q.get(key) orelse return null;
    if (v != .text) return error.BadQuery;
    return token.tokenIdOfString(v.text) orelse error.BadQuery;
}

/// The query, checked: every key one of the six, every value its shape.
pub const Query = union(enum) {
    values: struct { id: bsv21.TokenId, limit: u64, skip: u64 },
    authorities: struct { id: bsv21.TokenId, limit: u64, skip: u64 },
    outpoint: lookup.Output,
};

pub fn parseQuery(q: Value) !Query {
    if (q != .map) return error.BadQuery;
    for (q.map) |e| {
        for (allowed) |k| {
            if (eql(u8, e.key, k)) break;
        } else return error.BadQuery;
    }
    const auth = try tokenField(q, "authoritiesTokenId");
    const tok = try tokenField(q, "tokenId");
    const limit = try intField(q, "limit", max_limit, 1, max_limit);
    const skip = try intField(q, "skip", 0, 0, max_skip);
    var txid: ?[32]u8 = null;
    if (q.get("txid")) |t| {
        if (t != .text or t.text.len != 64) return error.BadQuery;
        txid = c.header.fromHex(t.text) catch return error.BadQuery;
    }
    const vout: ?u64 = if (q.get("outputIndex")) |_| try intField(q, "outputIndex", 0, 0, std.math.maxInt(u32)) else null;
    if (auth) |id| return .{ .authorities = .{ .id = id, .limit = limit, .skip = skip } };
    if (tok) |id| return .{ .values = .{ .id = id, .limit = limit, .skip = skip } };
    if (txid != null and vout != null) return .{ .outpoint = .{ .txid = txid.?, .vout = @intCast(vout.?) } };
    return error.UnsupportedQuery;
}

fn page(a: Allocator, svc: *Service, index: []const u8, id: bsv21.TokenId, limit: u64, skip: u64) ![]const lookup.Output {
    const tk = tokKey(id);
    const all = try svc.map(index).prefixed(&tk);
    const from: usize = @intCast(skip);
    if (from >= all.len) return &.{};
    const to = @min(all.len, from + @as(usize, @intCast(limit)));
    const out = try a.alloc(lookup.Output, to - from);
    for (all[from..to], out) |kv, *o| {
        if (kv.key.len != 72) return error.BadIndex;
        o.* = opOf(kv.key[36..]);
    }
    return out;
}

/// The discovery lookup's query: `{tokenId}` and nothing else.
pub fn parseDeploysQuery(q: Value) !bsv21.TokenId {
    if (q != .map) return error.BadQuery;
    for (q.map) |e| if (!eql(u8, e.key, "tokenId")) return error.BadQuery;
    return (try tokenField(q, "tokenId")) orelse error.UnsupportedQuery;
}

pub fn answer(a: Allocator, svc: *Service, _: *lookup.Chain, query: Value) anyerror!lookup.Answer {
    if (isDeploys(svc)) {
        const id = try parseDeploysQuery(query);
        if (!(try svc.map("deploys").has(&tokKey(id)))) return .{ .output_list = &.{} };
        return .{ .output_list = try a.dupe(lookup.Output, &.{.{ .txid = id.txid, .vout = id.vout }}) };
    }
    if (!eql(u8, svc.name, service_name)) return error.UnknownService;
    switch (try parseQuery(query)) {
        .values => |p| return .{ .output_list = try page(a, svc, "values", p.id, p.limit, p.skip) },
        .authorities => |p| return .{ .output_list = try page(a, svc, "authorities", p.id, p.limit, p.skip) },
        .outpoint => |o| {
            const v = (try svc.map("outputs").get(&opKey(o.txid, o.vout))) orelse return .{ .output_list = &.{} };
            if ((try entryOf(v)).spender != null) return .{ .output_list = &.{} };
            return .{ .output_list = try a.dupe(lookup.Output, &.{o}) };
        },
    }
}

pub fn metadata(_: Allocator, service: []const u8) anyerror!lookup.Metadata {
    if (eql(u8, service, deploys_service)) return .{
        .short_description = "Mandala token deploys: a token id's deploy output, with the metadata it was deployed with.",
        .version = version,
        .information_url = "https://github.com/shruggr/skein-mandala",
    };
    return .{
        .short_description = "Mandala (BRC-162) token outputs: a token's unspent value outputs, its authority outputs, one output by outpoint.",
        .version = version,
        .information_url = "https://github.com/shruggr/skein-mandala",
    };
}

pub const version = "0.4.0";

pub fn documentation(_: Allocator, service: []const u8) anyerror![]const u8 {
    if (eql(u8, service, deploys_service)) return
    \\# Mandala token deploys lookup service (ls_mandala_deploys)
    \\
    \\Indexes the deploy outputs `tm_mandala` admits, by token id.
    \\
    \\- `{ tokenId }`: the token's deploy output, with the metadata it was deployed with in
    \\  its script. The token id is `<txid>_<vout>` (`<txid>_0` at output 0), a binary
    \\  deploy's or a BRC-161 JSON deploy's alike; `<txid>` and `<txid>.<vout>` are taken too.
    \\  An output-list of one, or empty when the deploy was not admitted.
    \\
    \\A deploy stays listed once it is spent. Any other key is refused.
    \\
    ;
    return
    \\# Mandala token lookup service (ls_mandala)
    \\
    \\Indexes the outputs the Mandala token topics (`tm_<txid>_<vout>`) admit, by token id and
    \\outpoint. A token id is the deploy outpoint, the txid in display byte order,
    \\lowercase, written `<txid>_<vout>` for every token, `<txid>_0` included (BRC-162 "Token
    \\identification": the bare 32-byte txid is the wire form only). A query takes any of
    \\`<txid>`, `<txid>_<vout>`, `<txid>.<vout>`.
    \\
    \\## Queries
    \\
    \\The first key present, in this order, answers:
    \\
    \\- `{ authoritiesTokenId, limit?, skip? }`: the token's unspent authority outputs
    \\  (its deploy among them), in outpoint order.
    \\- `{ tokenId, limit?, skip? }`: the token's unspent value outputs, in outpoint order.
    \\- `{ txid, outputIndex }`: the value or authority output at that outpoint, if unspent.
    \\
    \\`limit` is 1 to 100 (default 100) and `skip` is 0 to 100000 (default 0). Anything
    \\else is refused. Outpoint order is the txid in display order, then the output index.
    \\Answers are output-lists, each output with its transaction's BEEF.
    \\
    ;
}

// ---------------------------------------------------------------- the token list (fn "tokens", a read)

/// The token list's query: `{limit?, skip?}`, from the query string or a JSON body (both: the body's win).
pub const TokensQuery = struct { limit: u64 = max_limit, skip: u64 = 0 };

fn tokensField(q: *TokensQuery, key: []const u8, v: u64) !void {
    if (eql(u8, key, "limit")) {
        if (v < 1 or v > max_limit) return error.BadQuery;
        q.limit = v;
    } else if (eql(u8, key, "skip")) {
        if (v > max_skip) return error.BadQuery;
        q.skip = v;
    } else return error.BadQuery;
}

/// The token list's query from a request: the query string's `limit` / `skip` (decimal), then a JSON
/// object body's (integers). Any other key, or a value out of range, is refused (error.BadQuery).
pub fn parseTokensQuery(a: Allocator, query: []const u8, body: []const u8) !TokensQuery {
    var q: TokensQuery = .{};
    var it = std.mem.splitScalar(u8, if (std.mem.startsWith(u8, query, "?")) query[1..] else query, '&');
    while (it.next()) |kv| {
        if (kv.len == 0) continue;
        const i = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadQuery;
        const v = std.fmt.parseInt(u64, kv[i + 1 ..], 10) catch return error.BadQuery;
        try tokensField(&q, kv[0..i], v);
    }
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return q;
    const j = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return error.BadQuery;
    if (j != .object) return error.BadQuery;
    var jt = j.object.iterator();
    while (jt.next()) |e| {
        const v = e.value_ptr.*;
        if (v != .integer or v.integer < 0) return error.BadQuery;
        try tokensField(&q, e.key_ptr.*, @intCast(v.integer));
    }
    return q;
}

/// One token on the list: its id `<txid>_<vout>` (`_0` included), its topic, the deploy's display fields
/// (`sym` "" and `dec` 0 when the deploy carries none), its icon as an outpoint `<txid>_<vout>` (a
/// BRC-162 icon by output index is that output of the deploy transaction), the deploy outpoint.
pub const Listed = struct {
    tokenId: []const u8,
    topic: []const u8,
    sym: []const u8,
    dec: u8,
    icon: ?[]const u8 = null,
    txid: []const u8,
    vout: u32,
};

/// Where a deploy stands for "newest first": its block height and position in the block from the
/// chain state's proof (null: not mined, the newest), then its deploy outpoint.
pub const Age = struct { key: []const u8, height: ?u32, offset: u64 };

pub fn newerFirst(_: void, x: Age, y: Age) bool {
    if (x.height == null and y.height != null) return true;
    if (y.height == null and x.height != null) return false;
    if (x.height) |hx| if (hx != y.height.?) return hx > y.height.?;
    if (x.height != null and x.offset != y.offset) return x.offset > y.offset;
    return std.mem.order(u8, x.key, y.key) == .gt;
}

fn ageOf(ch: *lookup.Chain, key: []const u8) !Age {
    const txid = display(key[0..32].*);
    const r = (try ch.proofRecord(txid)) orelse return .{ .key = key, .height = null, .offset = 0 };
    const block = c.store.bitcoinHash(r.block) orelse return error.BadIndex;
    const h = (try ch.chain().heightOf(block)) orelse return .{ .key = key, .height = null, .offset = 0 };
    return .{ .key = key, .height = h, .offset = r.pos.offset };
}

fn hexOf(a: Allocator, internal: [32]u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(display(internal), .lower));
}

/// A deploy the discovery index holds (its key: txid display ‖ vout BE), read from its transaction:
/// null when the store does not hold it or the output is no deploy.
fn listedOf(a: Allocator, s: c.store.Store, key: []const u8) !?Listed {
    const op = opOf(key);
    const raw = s.tryGet(a, &c.store.hashCid(.tx, op.txid)) orelse return null;
    const tx = c.bsvz.transaction.Transaction.parse(a, raw) catch return null;
    if (op.vout >= tx.outputs.len) return null;
    const id: bsv21.TokenId = .{ .txid = op.txid, .vout = op.vout, .kind = if (op.vout == 0) .native else .legacy };
    const t = (try bsv21.tokenOf(a, id, op.txid, op.vout, tx.outputs[op.vout].locking_script.bytes)) orelse return null;
    if (t.role != .deploy) return null;
    const nid: mandala.name.TokenId = .{ .txid = id.txid, .vout = id.vout, .kind = if (op.vout == 0) .native else .legacy };
    var tb: [mandala.name.max_suffix_len]u8 = undefined;
    var nb: [mandala.name.max_topic_len]u8 = undefined;
    var out: Listed = .{
        .tokenId = try a.dupe(u8, mandala.name.tokenIdText(&tb, nid)),
        .topic = try a.dupe(u8, mandala.name.topicName(&nb, nid)),
        .sym = "",
        .dec = 0,
        .txid = try hexOf(a, op.txid),
        .vout = op.vout,
    };
    switch (t.form) {
        .binary => {
            const m = mandala.brc162.metadataOf(t.binary.?.payload orelse "");
            out.sym = m.sym orelse "";
            out.dec = m.dec orelse 0;
            if (m.icon) |ic| out.icon = switch (ic) {
                .outpoint => |o| try std.fmt.allocPrint(a, "{s}_{d}", .{ try hexOf(a, o.txid), o.vout }),
                .output => |n| try std.fmt.allocPrint(a, "{s}_{d}", .{ out.txid, n }),
            };
        },
        .json => {
            const j = t.json.?;
            out.sym = j.sym orelse "";
            out.dec = j.dec orelse 0;
            out.icon = j.icon;
        },
    }
    return out;
}

/// The token list (shruggr/skein#120, decided 2026-10-06: a read function of the Mandala
/// components, not a BRC-24 query): every deploy the discovery topic `tm_mandala` admitted (the
/// map `deploys` of `ls_mandala_deploys`, its state record `deploys_state`), newest first by the
/// chain state (`chain_state`; unmined first, then by block height and position, highest first),
/// `skip` then `limit` of them. Reads only.
pub fn tokens(a: Allocator, s: c.store.Store, deploys_state: ?[]const u8, chain_state: ?[]const u8, q: TokensQuery) ![]const Listed {
    var svc = try Service.load(a, s, deploys_service, spec.maps, deploys_state);
    var net: c.chain.Network = .main;
    if (chain_state) |r| net = c.chain.Network.parse((try s.getValue(a, r)).getText("network") orelse "") orelse return error.BadChainState;
    var ch = try lookup.Chain.load(a, s, chain_state, net);
    const all = try svc.map("deploys").prefixed(&.{});
    const ages = try a.alloc(Age, all.len);
    for (all, ages) |kv, *x| {
        if (kv.key.len != 36) return error.BadIndex;
        x.* = try ageOf(&ch, kv.key);
    }
    std.mem.sort(Age, ages, {}, newerFirst);
    var out: std.ArrayList(Listed) = .empty;
    var skipped: u64 = 0;
    for (ages) |x| {
        if (out.items.len >= q.limit) break;
        const l = (try listedOf(a, s, x.key)) orelse continue;
        if (skipped < q.skip) {
            skipped += 1;
            continue;
        }
        try out.append(a, l);
    }
    return out.items;
}

fn respond(a: Allocator, status: u64, body: []const u8) !Value {
    return .{ .map = try a.dupe(c.cbor.Entry, &.{
        .{ .key = "status", .value = .{ .uint = status } },
        .{ .key = "type", .value = .{ .text = "application/json" } },
        .{ .key = "body", .value = .{ .bytes = body } },
    }) };
}

/// The read `/<app>/mandala/tokens` (the route handler contract, any method): `{limit?, skip?}` →
/// 200 `[{tokenId, topic, sym, dec, icon?, txid, vout}]`, or 400 `{status: "error", message}`.
/// `deploys_state` is the head `<app>/ls_mandala_deploys`'s record, `chain_state` the head `chain/state`'s.
pub fn tokensRoute(a: Allocator, s: c.store.Store, deploys_state: ?[]const u8, chain_state: ?[]const u8, req: Value) !Value {
    const q = parseTokensQuery(a, req.getText("query") orelse "", req.getBytes("body") orelse "") catch
        return respond(a, 400, "{\"status\":\"error\",\"message\":\"the query is {limit?: 1..100, skip?: 0..100000}, in the query string or a JSON body\"}");
    const list = try tokens(a, s, deploys_state, chain_state, q);
    var w: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(list, .{ .emit_null_optional_fields = false }, &w.writer);
    return respond(a, 200, w.written());
}

/// The app a read's call names: the read route's `app` (the install's; a read route names no program,
/// shruggr/skein#143), else its program record's, else "mandala".
fn appOfRead(a: Allocator, s: c.store.Store, req: Value) ![]const u8 {
    const m = req.get("match") orelse return "mandala";
    if (m.getText("app")) |x| return x;
    const p = m.getCid("program") orelse return "mandala";
    return (try s.getValue(a, p)).getText("app") orelse "mandala";
}

const sk = @import("overlay_sk");
var delegate = false;

fn run(a: Allocator) anyerror!void {
    const in = try sk.input(a);
    if (!eql(u8, in.getText("fn") orelse "", "tokens")) {
        delegate = true;
        return;
    }
    const req = try sk.callArg(a, in);
    const s = sk.store();
    const app = try appOfRead(a, s, req);
    const deploys = try sk.head(a, try lookup.headName(a, app, deploys_service));
    const out = try tokensRoute(a, s, deploys, try sk.head(a, lookup.chain_head), req);
    // A read route's filter (shruggr/skein#143): the http answer as the filter's `{answer: …}`.
    try sk.answer(a, if (isFilter(in)) try asFilterAnswer(a, out) else out);
}

/// Whether this call is a filter's: the input's `filter: true` (skein docs/APPS.md §2 "Filters").
pub fn isFilter(in: Value) bool {
    const f = in.get("filter") orelse return false;
    return f == .boolean and f.boolean;
}

/// An http answer `{status, type, body}` as a filter's `{answer: {status, type, body}}`.
pub fn asFilterAnswer(a: Allocator, http: Value) !Value {
    return .{ .map = try a.dupe(c.cbor.Entry, &.{.{ .key = "answer", .value = http }}) };
}

/// A call: fn "tokens" (the token list, a read), else the lookup contract's (fn "lookup", the hooks,
/// "metadata", "documentation").
pub fn main() u8 {
    const rc = sk.main("mandala-lookup", run);
    if (delegate) return lookup.main(spec);
    return rc;
}
