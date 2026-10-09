//! Topic and lookup names for a token (BRC-207 "Overlay spendability
//! contract"; David Case, 2026-10-08). The topic is the token's: any overlay
//! for the same token admits the same set.
//!
//! A token's topic is `tm_mandala_<assetId>` and its lookup service
//! `ls_mandala_<assetId>`, the asset id being its token id string
//! `<txid>_<vout>` for every token, `_0` included, where <txid> is the deploy
//! txid as 64 lowercase hex characters in display order and <vout> the deploy
//! output, decimal without leading zeros:
//!
//! - A token deployed at output 0 (`native`), under BRC-162 or under
//!   BRC-161: `tm_mandala_<txid>_0`. On the wire its id is the bare 32-byte
//!   txid. BRC-162 "Token identification": a BRC-161 token deployed at
//!   output 0 is the same token in both forms, with the 32-byte id.
//! - A token deployed under BRC-161 at a non-zero output (`legacy`):
//!   `tm_mandala_<txid>_<vout>`. Its binary outputs carry the 36-byte id
//!   (BRC-162: only such a token has one).
//!
//! These replace `tm_<txid>_<vout>` (0.8.2) with no alias: `tm_<txid>_<vout>`
//! is no topic of ours. The discovery topic `tm_mandala` and its lookup
//! `ls_mandala_deploys` keep their names (neither carries an asset id: a
//! token topic is `tm_mandala_` followed by one).
//!
//! A token id string is `<txid>_<vout>` for every token, Mandala and legacy
//! BSV-21 alike, `_0` included (David, 2026-10-07, shruggr/skein#120; BRC-162
//! "Token identification": "For display and APIs, the string form is
//! `<txid>_<vout>`"); the bare 32-byte txid is the wire form only.
//!
//! The bare `tm_<txid>` (until 0.8.1) and `tm_<txid>_<vout>` (0.8.2) are not
//! topic names: neither produced nor taken.
//!
//! Only `std` is imported here.
const std = @import("std");

/// A token's topic: `tm_mandala_<assetId>` (BRC-207).
pub const topic_prefix = "tm_mandala_";
/// A token's lookup service: `ls_mandala_<assetId>` (BRC-207).
pub const lookup_prefix = "ls_mandala_";
/// The discovery topic (shruggr/skein#120 item 11): every token's deploy output, one topic.
pub const deploys_topic = "tm_mandala";
/// Its lookup service.
pub const deploys_service = "ls_mandala_deploys";

/// The longest `<txid>_<vout>` suffix: 64 hex, `_`, 10 digits.
pub const max_suffix_len = 64 + 1 + 10;
pub const max_topic_len = topic_prefix.len + max_suffix_len;
pub const max_lookup_len = lookup_prefix.len + max_suffix_len;

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

/// `<txid>_<vout>`, vout decimal without leading zeros: `_0` native, any other legacy.
fn idOfSuffix(s: []const u8) ?TokenId {
    if (s.len < 66 or s[64] != '_') return null;
    const v = s[65..];
    if (v.len > 1 and v[0] == '0') return null;
    for (v) |c| if (!std.ascii.isDigit(c)) return null;
    const vout = std.fmt.parseInt(u32, v, 10) catch return null;
    return .{ .txid = idOfHex(s[0..64]) orelse return null, .vout = vout, .kind = if (vout == 0) .native else .legacy };
}

fn idAfter(prefix: []const u8, name: []const u8) ?TokenId {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    return idOfSuffix(name[prefix.len..]);
}

/// The token a token id string names: `<txid>` (output 0), `<txid>_<vout>` or the BRC-36
/// `<txid>.<vout>` (64 lowercase hex in display order; the vout decimal without leading
/// zeros). Every form of one token names the same token and the same topic. Vout 0 is a token deployed at output 0
/// (`tm_mandala_<txid>_0`, BRC-162 or BRC-161), any other vout a BRC-161 token deployed there
/// (`tm_mandala_<txid>_<vout>`). Null for anything else.
pub fn tokenIdOfString(s: []const u8) ?TokenId {
    if (s.len == 64) return .{ .txid = idOfHex(s) orelse return null };
    if (s.len < 66 or (s[64] != '_' and s[64] != '.')) return null;
    const v = s[65..];
    if (v.len > 1 and v[0] == '0') return null;
    for (v) |c| if (!std.ascii.isDigit(c)) return null;
    const vout = std.fmt.parseInt(u32, v, 10) catch return null;
    return .{ .txid = idOfHex(s[0..64]) orelse return null, .vout = vout, .kind = if (vout == 0) .native else .legacy };
}

/// The token id string of token `id`: `<txid>_<vout>`, `<txid>_0` at output 0, for every
/// token whatever its deploy's form (BRC-162 "Token identification"; David, 2026-10-07).
pub fn tokenIdText(buf: *[max_suffix_len]u8, id: TokenId) []const u8 {
    var r = id.txid;
    std.mem.reverse(u8, &r);
    const hex = std.fmt.bytesToHex(r, .lower);
    return std.fmt.bufPrint(buf, "{s}_{d}", .{ &hex, id.vout }) catch unreachable;
}

/// The token a topic name carries: `tm_mandala_<txid>_<vout>` (`_0` native, any
/// other vout legacy). Null for anything else, including the discovery topic
/// `tm_mandala`, the old `tm_<txid>_<vout>` (0.8.2) and bare `tm_<txid>`, and
/// `tm_amm_<txid>`.
pub fn tokenIdOf(topic: []const u8) ?TokenId {
    return idAfter(topic_prefix, topic);
}

/// The token a lookup service name carries: `ls_mandala_<txid>_<vout>`. Null for anything
/// else, including `ls_mandala` and the discovery lookup `ls_mandala_deploys`.
pub fn tokenIdOfLookup(service: []const u8) ?TokenId {
    return idAfter(lookup_prefix, service);
}

fn nameOf(buf: []u8, prefix: []const u8, id: TokenId) []const u8 {
    var r = id.txid;
    std.mem.reverse(u8, &r);
    const hex = std.fmt.bytesToHex(r, .lower);
    // `<prefix><tokenId>`: the deploy output always carried, `_0` included.
    return std.fmt.bufPrint(buf, "{s}{s}_{d}", .{ prefix, &hex, id.vout }) catch unreachable;
}

/// The topic name of token `id`: `tm_mandala_<txid>_<vout>`, `tm_mandala_<txid>_0` at output 0
/// whatever its kind.
pub fn topicName(buf: *[max_topic_len]u8, id: TokenId) []const u8 {
    return nameOf(buf, topic_prefix, id);
}

/// The lookup service name of token `id`: `ls_mandala_<txid>_<vout>`.
pub fn lookupName(buf: *[max_lookup_len]u8, id: TokenId) []const u8 {
    return nameOf(buf, lookup_prefix, id);
}
