//! Topic names for a token's topic (decided 2026-10-01 in amm-poc,
//! docs/notes.md "Correction: topic names by deploy kind"; shruggr/skein#120).
//! The topic is the token's: any overlay for the same token admits the same
//! set.
//!
//! - A token deployed at output 0 (`native`), under BRC-162 or under
//!   BRC-161: `tm_<txid>`, where <txid> is the deploy txid as 64 lowercase
//!   hex characters in display order. Its id is `<txid>_0`, on the wire the
//!   bare 32-byte txid, so the name carries no index. BRC-162 "Token
//!   identification": a BRC-161 token deployed at output 0 is the same token
//!   in both forms, with the 32-byte id.
//! - A token deployed under BRC-161 at a non-zero output (`legacy`):
//!   `tm_<txid>_<vout>`, decimal without leading zeros. Its binary outputs
//!   carry the 36-byte id (BRC-162: only such a token has one).
//!
//! `tm_<txid>_0` is not a topic name and is never produced (shruggr/skein#120).
//!
//! Only `std` is imported here.
const std = @import("std");

pub const topic_prefix = "tm_";
/// The discovery topic (shruggr/skein#120 item 11): every token's deploy output, one topic.
pub const deploys_topic = "tm_mandala_deploys";
/// Its lookup service.
pub const deploys_service = "ls_mandala_deploys";

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

/// `<txid>` (native) or `<txid>_<vout>` (legacy: vout non-zero, decimal, no leading zeros).
fn idOfSuffix(s: []const u8) ?TokenId {
    if (s.len == 64) return .{ .txid = idOfHex(s) orelse return null };
    if (s.len < 66 or s[64] != '_') return null;
    if (std.mem.eql(u8, s[64..], "_0")) return null; // output 0 is `<txid>`
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

/// Where a token originated, which decides how its id is written (BRC-162 "Token
/// identification"; David, 2026-10-05): `mandala` (a binary deploy, always at output 0) is
/// the bare `<txid>`; `bsv21` (a BRC-161 JSON deploy) is `<txid>_<vout>`, `<txid>_0` included.
pub const Origin = enum { mandala, bsv21 };

/// The token a token id string names: `<txid>` (output 0), `<txid>_<vout>` or the BRC-36
/// `<txid>.<vout>` (64 lowercase hex in display order; the vout decimal without leading
/// zeros). Every form of one token names the same token and the same topic; the string's
/// form says nothing about the token's origin. Vout 0 is a token deployed at output 0
/// (`tm_<txid>`, BRC-162 or BRC-161), any other vout a BRC-161 token deployed there
/// (`tm_<txid>_<vout>`). Null for anything else.
pub fn tokenIdOfString(s: []const u8) ?TokenId {
    if (s.len == 64) return .{ .txid = idOfHex(s) orelse return null };
    if (s.len < 66 or (s[64] != '_' and s[64] != '.')) return null;
    const v = s[65..];
    if (v.len > 1 and v[0] == '0') return null;
    for (v) |c| if (!std.ascii.isDigit(c)) return null;
    const vout = std.fmt.parseInt(u32, v, 10) catch return null;
    return .{ .txid = idOfHex(s[0..64]) orelse return null, .vout = vout, .kind = if (vout == 0) .native else .legacy };
}

/// The token id string of token `id` in its origin's form: `<txid>` for a token that
/// originated as Mandala, `<txid>_<vout>` for one that originated as BSV-21. A token at a
/// non-zero output can only be BSV-21's, and is written `<txid>_<vout>` whatever `origin` says.
pub fn tokenIdText(buf: *[max_suffix_len]u8, id: TokenId, origin: Origin) []const u8 {
    var r = id.txid;
    std.mem.reverse(u8, &r);
    const hex = std.fmt.bytesToHex(r, .lower);
    return (if (origin == .mandala and id.vout == 0)
        std.fmt.bufPrint(buf, "{s}", .{&hex})
    else
        std.fmt.bufPrint(buf, "{s}_{d}", .{ &hex, id.vout })) catch unreachable;
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
    // By the deploy output alone: output 0 never carries an index.
    return (if (id.vout == 0)
        std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, &hex })
    else
        std.fmt.bufPrint(buf, "{s}{s}_{d}", .{ prefix, &hex, id.vout })) catch unreachable;
}

/// The topic name of token `id`: `tm_<txid>` (vout 0, whatever its kind) or `tm_<txid>_<vout>`.
pub fn topicName(buf: *[max_topic_len]u8, id: TokenId) []const u8 {
    return nameOf(buf, topic_prefix, id);
}
