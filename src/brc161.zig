//! The BRC-161 (BSV-21 JSON, legacy) decoder: a 1Sat `ord` inscription
//! envelope with content type `application/bsv-20` and a JSON object body
//! `{p: "bsv-20", op, id?, amt?, dec?, sym?, icon?}`.
//!
//! The envelope is found exactly as 1sat-stack finds it (Go reference:
//! pkg/template/inscription `Decode`, read by pkg/template/bsv21 `Decode`,
//! which pkg/bsv21/topic_validated.go calls):
//!
//! - The script is walked op by op from the start. The envelope starts at
//!   the first op that is the direct push `0x03 "ord"` whose two preceding
//!   BYTES are `OP_0 OP_IF` (`00 63`): it may sit anywhere, after any lock
//!   (the "prefix") or before it (the "suffix"). A malformed push before it
//!   ends the walk (not an inscription).
//! - Then (tag, value) op pairs. Either op above `OP_16` ends the envelope
//!   without content. A tag is `OP_1`..`OP_16` (its number), `OP_1NEGATE`
//!   (-1), `OP_RESERVED` (0, as Go's `op - 80` gives), a one-byte push (that
//!   byte), an empty push (0), or a longer push (a named field, skipped).
//!   Tag 1 is the content type (kept only when under 256 bytes of valid
//!   UTF-8; the last one wins); tag 0 is the content and ends the fields.
//! - After the content, the next op must be `OP_ENDIF` or the end of the
//!   script; anything else and the walk resumes after that op, looking for
//!   another envelope.
//!
//! The body (pkg/template/bsv21 `Decode`, and BRC-161 "Field validation
//! summary"):
//!
//! - content type exactly `application/bsv-20`; the body a JSON object
//!   (duplicate keys: the last wins, as Go's `json.Unmarshal` into a map);
//!   `"p"` exactly the string `bsv-20`.
//! - `op` a string, compared case-insensitively (Go lowercases it): one of
//!   `deploy+mint`, `deploy+auth`, `mint`, `auth`, `transfer`, `burn`.
//! - `amt`: required on `deploy+mint`, `mint`, `transfer`, `burn`, a JSON
//!   string of decimal digits fitting a uint64 (Go's `strconv.ParseUint(s,
//!   10, 64)`: leading zeros and "0" accepted, no sign, no spaces). On
//!   `deploy+auth` and `auth` it must be absent (present in any form, even
//!   `null`, makes the output not a token).
//! - `id`: required on `mint`, `auth`, `transfer`, `burn`: the canonical
//!   `<txid>_<vout>` (64 lowercase hex in display order, `_`, decimal vout
//!   without leading zeros, fitting a uint32). Go parses looser forms
//!   (uppercase hex, any separator byte, leading zeros) but then compares the
//!   string with the topic's canonical id, so a looser form never matches a
//!   token; here it is simply not an id. Ignored on deploys (the id is the
//!   deploy outpoint).
//! - Display fields (`sym`, `icon`, `dec`) are deploy-only and never affect
//!   validity (BRC-161 "Deploy display fields"): a malformed one is dropped.
//!   Go differs: a present `dec` that is not a string integer 0..18
//!   invalidates the output on any op, and a non-string `sym`, `icon` or `op`
//!   panics. Here the spec wins (README, "Spec ambiguities").
//! - Unknown keys are ignored.
const std = @import("std");
const brc162 = @import("brc162.zig");

pub const content_type = "application/bsv-20";

const OP_IF = 0x63;
const OP_ENDIF = 0x68;
const OP_RESERVED = 0x50;

pub const Op = enum {
    deploy_mint,
    deploy_auth,
    mint,
    auth,
    transfer,
    burn,

    pub fn isDeploy(self: Op) bool {
        return self == .deploy_mint or self == .deploy_auth;
    }
};

pub const Token = struct {
    op: Op,
    /// The token id (`id`), null on deploys.
    id: ?brc162.Id = null,
    /// `amt`; 0 on `deploy+auth` and `auth`.
    amount: u64 = 0,
    /// Deploy display fields, when present and well formed.
    sym: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    dec: ?u8 = null,
    /// The locking script before the envelope's `OP_0 OP_IF`, and after its
    /// `OP_ENDIF`.
    prefix: []const u8,
    suffix: []const u8,
};

/// An `ord` envelope, as far as BSV-21 reads it.
pub const Inscription = struct {
    content_type: ?[]const u8 = null,
    content: []const u8,
    prefix: []const u8,
    suffix: []const u8,
};

/// Go's `script.ReadOp`: the op at `pos.*`, advancing it; null when a push
/// runs past the end (or `pos.*` is at the end).
fn readOp(script: []const u8, pos: *usize) ?struct { op: u8, data: []const u8 } {
    if (pos.* >= script.len) return null;
    const op = script[pos.*];
    if (op >= 0x01 and op <= brc162.OP_PUSHDATA4) {
        const p = brc162.readPush(script, pos.*) orelse return null;
        pos.* = p.next;
        return .{ .op = op, .data = p.data };
    }
    // Every other op, OP_0 included, carries no data.
    pos.* += 1;
    return .{ .op = op, .data = &.{} };
}

/// The first `ord` envelope in `script` that carries content (see the file
/// comment), or null.
pub fn envelope(script: []const u8) ?Inscription {
    var pos: usize = 0;
    while (pos < script.len) {
        const start = pos;
        const first = readOp(script, &pos) orelse return null;
        if (!(start >= 2 and first.op == 0x03 and std.mem.eql(u8, first.data, "ord") and
            script[start - 2] == brc162.OP_0 and script[start - 1] == OP_IF)) continue;

        var ct: ?[]const u8 = null;
        const content = while (true) {
            const tag = readOp(script, &pos) orelse return null;
            if (tag.op > brc162.OP_16) return null;
            const val = readOp(script, &pos) orelse return null;
            if (val.op > brc162.OP_16) return null;
            const field: i32 = if (tag.op > brc162.OP_PUSHDATA4)
                @as(i32, tag.op) - (OP_RESERVED)
            else if (tag.data.len == 1)
                tag.data[0]
            else if (tag.data.len > 1)
                continue
            else
                0;
            switch (field) {
                0 => break val.data,
                1 => if (val.data.len < 256 and std.unicode.utf8ValidateSlice(val.data)) {
                    ct = val.data;
                },
                else => {},
            }
        };
        const end = pos;
        const after = readOp(script, &pos);
        if (after == null or after.?.op == OP_ENDIF) return .{
            .content_type = ct,
            .content = content,
            .prefix = script[0 .. start - 2],
            .suffix = script[if (after == null) end else pos..],
        };
    }
    return null;
}

/// The canonical `<txid>_<vout>` id (64 lowercase hex in display order, `_`,
/// decimal vout without leading zeros), or null.
pub fn parseId(s: []const u8) ?brc162.Id {
    if (s.len < 66 or s[64] != '_') return null;
    var txid: [32]u8 = undefined;
    for (s[0..64]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    _ = std.fmt.hexToBytes(&txid, s[0..64]) catch return null;
    std.mem.reverse(u8, &txid);
    return .{ .txid = txid, .vout = parseVout(s[65..]) orelse return null };
}

/// A canonical decimal uint32 (no sign, no leading zeros), or null.
pub fn parseVout(s: []const u8) ?u32 {
    if (s.len == 0 or (s.len > 1 and s[0] == '0')) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// Go's `strconv.ParseUint(s, 10, 64)`: decimal digits only (leading zeros
/// allowed), fitting a uint64.
fn parseAmount(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

fn opOf(s: []const u8) ?Op {
    var buf: [16]u8 = undefined;
    if (s.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, s);
    const table = .{
        .{ "deploy+mint", Op.deploy_mint }, .{ "deploy+auth", Op.deploy_auth },
        .{ "mint", Op.mint },               .{ "auth", Op.auth },
        .{ "transfer", Op.transfer },       .{ "burn", Op.burn },
    };
    inline for (table) |e| if (std.mem.eql(u8, lower, e[0])) return e[1];
    return null;
}

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// The BSV-21 JSON token a locking script carries, or null when it is not a
/// BRC-161 token output. Does not check for a BRC-162 prefix ("binary wins"
/// is the caller's: bsv21.zig). `a` holds the parsed JSON (an arena).
pub fn decode(a: std.mem.Allocator, script: []const u8) error{OutOfMemory}!?Token {
    const insc = envelope(script) orelse return null;
    if (!std.mem.eql(u8, insc.content_type orelse return null, content_type)) return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, insc.content, .{ .duplicate_field_behavior = .use_last }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (v != .object) return null;
    const obj = v.object;
    if (!std.mem.eql(u8, str(obj, "p") orelse return null, "bsv-20")) return null;
    const op = opOf(str(obj, "op") orelse return null) orelse return null;

    var t: Token = .{ .op = op, .prefix = insc.prefix, .suffix = insc.suffix };
    switch (op) {
        .deploy_auth, .auth => if (obj.contains("amt")) return null,
        else => t.amount = parseAmount(str(obj, "amt") orelse return null) orelse return null,
    }
    if (op.isDeploy()) {
        t.sym = str(obj, "sym");
        t.icon = str(obj, "icon");
        if (str(obj, "dec")) |d| if (parseAmount(d)) |n| if (n <= 18) {
            t.dec = @intCast(n);
        };
    } else {
        t.id = parseId(str(obj, "id") orelse return null) orelse return null;
    }
    return t;
}
