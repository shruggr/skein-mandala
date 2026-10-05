//! Topic names for a token's topic (decided 2026-10-01 in amm-poc,
//! docs/notes.md "Correction: topic names by deploy kind"; shruggr/skein#120).
//! The topic is the token's: any overlay for the same token admits the same
//! set.
//!
//! - A token deployed under BRC-162 (binary, `native`): `tm_<txid>`, where
//!   <txid> is the deploy txid as 64 lowercase hex characters in display
//!   order. Its deploy is at output 0 and its wire id is the bare 32-byte
//!   txid, so the name carries no index.
//! - A token deployed under BRC-161 (legacy JSON, `legacy`):
//!   `tm_<txid>_<vout>`, the index always present (`_0` included), decimal
//!   without leading zeros. Its binary outputs carry the 32-byte id when vout
//!   is 0 and the 36-byte id otherwise.
//!
//! `tm_<txid>` and `tm_<txid>_0` are different topics for the same token id
//! string `<txid>_0`: which one holds the token depends on how output 0 of
//! <txid> was deployed (only one of the two can be its genesis).
//!
//! Only `std` is imported here.
const std = @import("std");

pub const topic_prefix = "tm_";

/// The longest `<txid>[_<vout>]` suffix: 64 hex, `_`, 10 digits.
pub const max_suffix_len = 64 + 1 + 10;
pub const max_topic_len = topic_prefix.len + max_suffix_len;

pub const Kind = enum { native, legacy };

/// A token as its topic names it: its deploy outpoint and deploy kind.
pub const TokenId = struct {
    /// The deploy txid, internal byte order.
    txid: [32]u8,
    /// The deploy output; always 0 for a native token.
    vout: u32 = 0,
    kind: Kind = .native,
};

/// The 32-byte id (internal byte order) of 64 lowercase hex characters in
/// display order; null for anything else.
pub fn idOfHex(hex: []const u8) ?[32]u8 {
    if (hex.len != 64) return null;
    for (hex) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    var id: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, hex) catch return null;
    std.mem.reverse(u8, &id);
    return id;
}

/// `<txid>` (native) or `<txid>_<vout>` (legacy, decimal, no leading zeros).
fn idOfSuffix(s: []const u8) ?TokenId {
    if (s.len == 64) return .{ .txid = idOfHex(s) orelse return null };
    if (s.len < 66 or s[64] != '_') return null;
    const v = s[65..];
    if (v.len > 1 and v[0] == '0') return null;
    for (v) |c| if (!std.ascii.isDigit(c)) return null;
    return .{
        .txid = idOfHex(s[0..64]) orelse return null,
        .vout = std.fmt.parseInt(u32, v, 10) catch return null,
        .kind = .legacy,
    };
}

fn idAfter(prefix: []const u8, name: []const u8) ?TokenId {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    return idOfSuffix(name[prefix.len..]);
}

/// The token a token id string names (BRC-162 "Token identification": `<txid>_<vout>`, the
/// deploy outpoint, 64 lowercase hex in display order, the vout decimal without leading zeros):
/// vout 0 is a BRC-162 token (`tm_<txid>`), any other vout a BRC-161 token deployed there
/// (`tm_<txid>_<vout>`). Null for anything else.
pub fn tokenIdOfString(s: []const u8) ?TokenId {
    var id = idOfSuffix(s) orelse return null;
    if (s.len == 64) return null; // the vout is required
    if (id.vout == 0) id.kind = .native;
    return id;
}

/// The token a topic name carries: `tm_<txid>` (native) or
/// `tm_<txid>_<vout>` (legacy). Null for anything else, including the old
/// `tm_amm_<txid>`.
pub fn tokenIdOf(topic: []const u8) ?TokenId {
    return idAfter(topic_prefix, topic);
}

fn nameOf(buf: []u8, prefix: []const u8, id: TokenId) []const u8 {
    var r = id.txid;
    std.mem.reverse(u8, &r);
    const hex = std.fmt.bytesToHex(r, .lower);
    return switch (id.kind) {
        .native => std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, &hex }),
        .legacy => std.fmt.bufPrint(buf, "{s}{s}_{d}", .{ prefix, &hex, id.vout }),
    } catch unreachable;
}

/// The topic name of token `id`: `tm_<txid>` or `tm_<txid>_<vout>`.
pub fn topicName(buf: *[max_topic_len]u8, id: TokenId) []const u8 {
    return nameOf(buf, topic_prefix, id);
}
