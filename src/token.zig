//! The topic's judgement, independent of the topic contract's transport: the
//! BSV-21 rules (both forms, bsv21.zig) for the topic's token and nothing else (decided
//! 2026-10-01: the topic is the token's topic). It knows no application: any
//! output, a contract's or a wallet's, is admitted exactly when the token
//! rules admit it. What an application indexes of it (AMM's pool checks) is
//! its own lookup's judgement, not this topic's.
const std = @import("std");
const bsv21 = @import("bsv21.zig");
const name = @import("name.zig");

/// The token a topic name carries (`tm_<txid>` native, `tm_<txid>_<vout>`
/// legacy, name.zig), as the rules take it.
pub fn tokenIdOf(topic: []const u8) ?bsv21.TokenId {
    return fromName(name.tokenIdOf(topic) orelse return null);
}

/// The token a token id string `<txid>_<vout>` names (name.zig `tokenIdOfString`), as the rules take it.
pub fn tokenIdOfString(s: []const u8) ?bsv21.TokenId {
    return fromName(name.tokenIdOfString(s) orelse return null);
}

fn fromName(n: name.TokenId) bsv21.TokenId {
    return .{ .txid = n.txid, .vout = n.vout, .kind = switch (n.kind) {
        .native => .native,
        .legacy => .legacy,
    } };
}

pub const Verdict = struct {
    outputs_to_admit: []const u32 = &.{},
    coins_to_retain: []const u32 = &.{},
    /// Why nothing was admitted, when the transaction was rejected.
    rejected: ?Reason = null,

    pub const Reason = enum { inflation };
};

/// Judge `tx` for token `id`: admit its valid token outputs and retain the
/// token coins it spends, or, when it breaks the token rules, admit and
/// retain nothing.
pub fn judge(a: std.mem.Allocator, id: bsv21.TokenId, tx: bsv21.Tx, previous_coins: []const u32) !Verdict {
    const j = try bsv21.judge(a, id, tx, previous_coins);
    if (!j.ok) return .{ .rejected = .inflation };

    const admit = try a.alloc(u32, j.outputs.len);
    for (j.outputs, admit) |o, *x| x.* = o.index;
    const retain = try a.alloc(u32, j.inputs.len);
    for (j.inputs, retain) |i, *x| x.* = i.index;
    return .{ .outputs_to_admit = admit, .coins_to_retain = retain };
}
