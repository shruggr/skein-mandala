//! The BRC-162 (BSV-21 binary) decoder: a token output is recognised by its
//! shape, `<id | OP_0> <amount | OP_0> OP_2DROP [<payload> OP_DROP] <lock>`.
//!
//! What the decoder accepts, exactly:
//! - id: `OP_0` (a deploy), the direct push `0x20 <32 bytes>` (the deploy
//!   txid, natural order: a token deployed at output 0), or the direct push
//!   `0x24 <36 bytes>` (txid natural order ‖ uint32 LE vout: a legacy
//!   BRC-161 token deployed at a non-zero output). A 36-byte id whose vout is
//!   0 is non-canonical and invalid (BRC-162 "Token identification"), so the
//!   script is not a binary token output (it may still be a BRC-161 one).
//!   Any other push (other lengths, a PUSHDATA form of 32 or 36) is not a token.
//! - amount: `OP_0` (zero), `OP_1`..`OP_16` (1..16), or, for 17 and above, a
//!   direct push of 1..9 bytes holding a minimally encoded, non-negative
//!   script number up to 2^64 - 1. Minimally encoded means minimal for the
//!   whole push (MINIMALDATA): the fewest bytes overall, so 1..16 must use
//!   `OP_1`..`OP_16`, not a direct push. A non-minimal number, a direct push
//!   of 0 or 1..16, a negative amount, OP_1NEGATE and PUSHDATA forms are not
//!   a token.
//! - payload: any single push operation directly followed by OP_DROP. It is
//!   recorded and never validated.
const std = @import("std");

pub const OP_0 = 0x00;
pub const OP_PUSHDATA1 = 0x4c;
pub const OP_PUSHDATA2 = 0x4d;
pub const OP_PUSHDATA4 = 0x4e;
pub const OP_1NEGATE = 0x4f;
pub const OP_1 = 0x51;
pub const OP_16 = 0x60;
pub const OP_DROP = 0x75;
pub const OP_2DROP = 0x6d;

pub const Role = enum {
    /// Id `OP_0`: the token's genesis (valid only at output 0; the amount is
    /// the fixed supply, or zero for the first authority).
    deploy,
    /// Id present, amount > 0.
    value,
    /// Id present, amount 0.
    authority,
};

/// A token id as an outpoint: the deploy's txid (internal byte order) and
/// output index. On the wire it is 32 bytes when `vout` is 0, 36 otherwise.
pub const Id = struct {
    txid: [32]u8,
    vout: u32 = 0,

    pub fn eql(self: Id, other: Id) bool {
        return self.vout == other.vout and std.mem.eql(u8, &self.txid, &other.txid);
    }
};

pub const Token = struct {
    /// The id as written (txid in internal byte order, vout 0 for a 32-byte
    /// id); null for a deploy.
    id: ?Id,
    amount: u64,
    role: Role,
    payload: ?[]const u8 = null,
    /// The locking script after the prefix (and the payload, when present).
    lock: []const u8,

    /// A deploy with a zero amount is the token's first authority.
    pub fn isAuthority(self: Token) bool {
        return self.amount == 0;
    }
};

pub const Push = struct {
    op: u8,
    data: []const u8,
    /// Offset of the next operation.
    next: usize,
};

/// The push operation at `pos`, or null when the operation there is not a
/// push or runs past the end of the script.
pub fn readPush(script: []const u8, pos: usize) ?Push {
    if (pos >= script.len) return null;
    const op = script[pos];
    var at = pos + 1;
    const len: usize = switch (op) {
        OP_0 => 0,
        0x01...0x4b => op,
        OP_PUSHDATA1 => blk: {
            if (at + 1 > script.len) return null;
            at += 1;
            break :blk script[at - 1];
        },
        OP_PUSHDATA2 => blk: {
            if (at + 2 > script.len) return null;
            at += 2;
            break :blk std.mem.readInt(u16, script[at - 2 ..][0..2], .little);
        },
        OP_PUSHDATA4 => blk: {
            if (at + 4 > script.len) return null;
            at += 4;
            break :blk std.mem.readInt(u32, script[at - 4 ..][0..4], .little);
        },
        OP_1NEGATE, OP_1...OP_16 => return .{ .op = op, .data = &.{}, .next = at },
        else => return null,
    };
    if (len > script.len - at) return null;
    return .{ .op = op, .data = script[at .. at + len], .next = at + len };
}

/// A minimally encoded, non-negative script number that fits in a u64.
pub fn scriptNumU64(bytes: []const u8) ?u64 {
    if (bytes.len == 0) return 0;
    if (bytes.len > 9) return null;
    const last = bytes[bytes.len - 1];
    if (last & 0x80 != 0) return null; // negative
    // Minimal: the top byte may be zero only to carry the sign bit of the one below.
    if (last == 0 and (bytes.len == 1 or bytes[bytes.len - 2] & 0x80 == 0)) return null;
    if (bytes.len == 9 and last != 0) return null; // above 2^64 - 1
    var v: u64 = 0;
    for (bytes[0..@min(bytes.len, 8)], 0..) |b, i| v |= @as(u64, b) << @intCast(8 * i);
    return v;
}

fn amountOf(p: Push) ?u64 {
    return switch (p.op) {
        OP_0 => 0,
        OP_1...OP_16 => p.op - (OP_1 - 1),
        0x01...0x09 => blk: {
            const v = scriptNumU64(p.data) orelse return null;
            // Minimally encoded (MINIMALDATA): 0 and 1..16 have shorter forms
            // (OP_0, OP_1..OP_16), so a direct push may not carry them.
            break :blk if (v <= 16) null else v;
        },
        else => null,
    };
}

/// The token a locking script carries, or null when it is not a BRC-162
/// binary token output.
pub fn decode(script: []const u8) ?Token {
    const id_push = readPush(script, 0) orelse return null;
    var id: ?Id = null;
    switch (id_push.op) {
        OP_0 => {},
        0x20 => id = .{ .txid = id_push.data[0..32].* },
        0x24 => {
            const vout = std.mem.readInt(u32, id_push.data[32..36], .little);
            if (vout == 0) return null; // non-canonical: a vout-0 id is 32 bytes
            id = .{ .txid = id_push.data[0..32].*, .vout = vout };
        },
        else => return null,
    }
    const amount_push = readPush(script, id_push.next) orelse return null;
    const amount = amountOf(amount_push) orelse return null;
    var pos = amount_push.next;
    if (pos >= script.len or script[pos] != OP_2DROP) return null;
    pos += 1;

    var payload: ?[]const u8 = null;
    if (readPush(script, pos)) |p| if (p.next < script.len and script[p.next] == OP_DROP) {
        payload = p.data;
        pos = p.next + 1;
    };
    const role: Role = if (id == null) .deploy else if (amount == 0) .authority else .value;
    return .{ .id = id, .amount = amount, .role = role, .payload = payload, .lock = script[pos..] };
}

/// The canonical push of token id `id` (the encoding writers use): 32 bytes
/// when its vout is 0, 36 otherwise.
pub fn pushId(buf: *[37]u8, id: Id) []const u8 {
    @memcpy(buf[1..33], &id.txid);
    if (id.vout == 0) {
        buf[0] = 0x20;
        return buf[0..33];
    }
    buf[0] = 0x24;
    std.mem.writeInt(u32, buf[33..37], id.vout, .little);
    return buf[0..37];
}

/// The minimal push of a token amount (the encoding writers use).
pub fn pushAmount(buf: *[10]u8, amount: u64) []const u8 {
    if (amount == 0) {
        buf[0] = OP_0;
        return buf[0..1];
    }
    if (amount <= 16) {
        buf[0] = @intCast(OP_1 - 1 + amount);
        return buf[0..1];
    }
    var n: usize = 0;
    var v = amount;
    while (v > 0) : (v >>= 8) {
        buf[1 + n] = @truncate(v);
        n += 1;
    }
    if (buf[n] & 0x80 != 0) {
        buf[1 + n] = 0;
        n += 1;
    }
    buf[0] = @intCast(n);
    return buf[0 .. n + 1];
}
