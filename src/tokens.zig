//! The active token list (shruggr/skein#120 item 2, on #119): which tokens
//! the app's overlay serves now. One topic per token; the list is the app's
//! own, kept as the root record of the head `<app>/mandala`:
//!
//!   {kind: "mandala-tokens", topics: [<topic>, …]}     sorted, each once
//!
//! The overlay engine reads the same record (config.overlay.prefixes
//! `{"tm_": {"program": "mandala-topic", "active": "mandala"}}`, skein-overlay
//! 0.5.0) and serves each listed topic with this program.
//!
//! A token's topic (name.zig) is `tm_<txid>` for a token deployed at output
//! 0 (BRC-162, or BRC-161 there), `tm_<txid>_<vout>` for a BRC-161 token
//! deployed at a non-zero output. Activate and deactivate take the topic only (`{topic}`: `tm_<txid>`,
//! `tm_<txid>_<vout>` or `tm_mandala_deploys`; David, 2026-10-05): the topic
//! is what it is from how the token was deployed, and the deploy page shows
//! it. The answer is `{topic, active}`.
//!
//! The discovery topic `tm_mandala_deploys` is switched the same way, by its
//! topic name (`{topic: "tm_mandala_deploys"}`): it is served under the same
//! prefix while it is on the list.
//!
//! Activating a token writes the list and emits `subscribe` for `<topic>`,
//! `<topic>-admit` and `<topic>-proof`; deactivating removes it and emits
//! `unsubscribe` for the same three (skein docs/OVERLAY.md "How an overlay
//! app activates a token topic live"). Activating an active token, or
//! deactivating an inactive one, changes nothing and emits nothing.
//!
//! This file is the list's logic, natively testable; mandala_topic.zig runs
//! it in a step.
const std = @import("std");
const cbor = @import("cbor");
const name = @import("mandala").name;

const Value = cbor.Value;
const Allocator = std.mem.Allocator;

/// The head the list lives under, after the app's name: `<app>/mandala`.
pub const head_suffix = "mandala";
pub const record_kind = "mandala-tokens";
/// The three GossipSub topics of one overlay topic (skein-overlay docs/OVERLAY.md "Gossip").
pub const suffixes = [_][]const u8{ "", "-admit", "-proof" };

/// The head of the list for app `app`.
pub fn headName(a: Allocator, app: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ app, head_suffix });
}

/// Whether `t` is a topic this list may hold: the discovery topic, or a token's topic.
pub fn isTopic(t: []const u8) bool {
    return std.mem.eql(u8, t, name.deploys_topic) or name.tokenIdOf(t) != null;
}

/// The topics a list record names (null: no list yet, none).
pub fn topicsOf(a: Allocator, rec: ?Value) ![]const []const u8 {
    const r = rec orelse return &.{};
    if (!std.mem.eql(u8, Value.str(r.get("kind")) orelse "", record_kind)) return error.BadTokenList;
    const ts = r.get("topics") orelse return error.BadTokenList;
    if (ts != .array) return error.BadTokenList;
    const out = try a.alloc([]const u8, ts.array.len);
    for (ts.array, out) |t, *o| o.* = Value.str(t) orelse return error.BadTokenList;
    return out;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn contains(list: []const []const u8, t: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, t)) return true;
    return false;
}

/// The list with `t` added, sorted; null when it is there already.
pub fn with(a: Allocator, list: []const []const u8, t: []const u8) !?[]const []const u8 {
    if (contains(list, t)) return null;
    const out = try a.alloc([]const u8, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = t;
    std.mem.sort([]const u8, out, {}, lessThan);
    return out;
}

/// The list without `t`; null when it is not there.
pub fn without(a: Allocator, list: []const []const u8, t: []const u8) !?[]const []const u8 {
    if (!contains(list, t)) return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |x| if (!std.mem.eql(u8, x, t)) try out.append(a, x);
    return out.items;
}

/// The list's record.
pub fn recordOf(a: Allocator, list: []const []const u8) !Value {
    const ts = try a.alloc(Value, list.len);
    for (list, ts) |t, *v| v.* = cbor.string(t);
    var m = cbor.MapBuilder.init(a);
    try m.put("kind", cbor.string(record_kind));
    try m.put("topics", .{ .array = ts });
    return m.value();
}

/// The three events one activation (`subscribe`) or deactivation (`unsubscribe`) emits:
/// `{event, topic}` for `<topic>`, `<topic>-admit`, `<topic>-proof`.
pub fn events(a: Allocator, event: []const u8, topic: []const u8) ![suffixes.len]Value {
    var out: [suffixes.len]Value = undefined;
    for (suffixes, &out) |sfx, *o| {
        var m = cbor.MapBuilder.init(a);
        try m.put("event", cbor.string(event));
        try m.put("topic", cbor.string(try std.mem.concat(a, u8, &.{ topic, sfx })));
        o.* = m.value();
    }
    return out;
}

/// The answer of activate and deactivate: `{topic, active}`.
pub fn answerOf(a: Allocator, topic: []const u8, active: bool) !Value {
    var m = cbor.MapBuilder.init(a);
    try m.put("topic", cbor.string(topic));
    try m.put("active", .{ .bool = active });
    return m.value();
}
