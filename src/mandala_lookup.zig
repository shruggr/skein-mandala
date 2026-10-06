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
//! one. Answers are output-lists (outpoints, no token id strings); the engine
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
    \\  its script. The deploy's form is the token's origin: a binary deploy is a Mandala
    \\  token, written `<txid>`; a BRC-161 JSON deploy a BSV-21 token, written
    \\  `<txid>_<vout>` (`<txid>_0` at output 0). An output-list of one, or empty when the deploy was not admitted.
    \\
    \\A deploy stays listed once it is spent. Any other key is refused.
    \\
    ;
    return
    \\# Mandala token lookup service (ls_mandala)
    \\
    \\Indexes the outputs the Mandala token topics (`tm_<txid>`) admit, by token id and
    \\outpoint. A token id is the deploy outpoint, the txid in display byte order,
    \\lowercase. A token that originated as Mandala (a binary deploy, always output 0) is
    \\written `<txid>`; one that originated as BSV-21 (a BRC-161 JSON deploy) `<txid>_<vout>`,
    \\`<txid>_0` included. A query takes any of `<txid>`, `<txid>_<vout>`, `<txid>.<vout>`.
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

pub fn main() u8 {
    return lookup.main(spec);
}
