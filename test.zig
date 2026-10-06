//! skein-mandala, natively. Moved from amm-poc programs/amm-topic (its
//! test.zig, less the pool library's tests, which stay with AMM): decoder
//! vectors, the BSV-21 rules on hand-built transactions, the topic's verdict
//! on the transactions amm-poc's gen/main.go builds from its Pool contract
//! (src/fixtures/vectors.zig: a contract output is a token output like any
//! other), and the program end to end through the topic contract's `judge`,
//! reading the subject and its previous coins' sources as records from a
//! store. Then the lookup service's three queries over its hooks.
const std = @import("std");
const w = @import("chain");
const topic = @import("topic");
const mandala = @import("mandala");
const brc162 = mandala.brc162;
const brc161 = mandala.brc161;
const bsv21 = mandala.bsv21;
const token = mandala.token;
const names = mandala.name;
const program = @import("src/mandala_topic.zig");
const vec = @import("src/fixtures/vectors.zig");

const bsvz = w.bsvz;
const testing = std.testing;
const Value = w.cbor.Value;

fn unhex(a: std.mem.Allocator, h: []const u8) []u8 {
    const out = a.alloc(u8, h.len / 2) catch @panic("OOM");
    _ = std.fmt.hexToBytes(out, h) catch @panic("bad hex");
    return out;
}

fn cat(a: std.mem.Allocator, parts: []const []const u8) []u8 {
    return std.mem.concat(a, u8, parts) catch @panic("OOM");
}

const id_a: [32]u8 = .{0xa5} ** 32;
/// Token id_a as a native (BRC-162) token.
const tid_a: bsv21.TokenId = .{ .txid = id_a };
const p2pkh_lock = [_]u8{ 0x76, 0xa9, 0x14 } ++ [_]u8{0x33} ** 20 ++ [_]u8{ 0x88, 0xac };

/// A BRC-162 token script: id (null = OP_0), amount, optional payload push, P2PKH.
fn tokenScript(a: std.mem.Allocator, id: ?[32]u8, amount: u64, payload: ?[]const u8) []u8 {
    var buf: [10]u8 = undefined;
    const idp: []const u8 = if (id) |x| cat(a, &.{ &.{0x20}, &x }) else &.{0x00};
    const pl: []const u8 = if (payload) |p| cat(a, &.{ p, &.{0x75} }) else &.{};
    return cat(a, &.{ idp, brc162.pushAmount(&buf, amount), &.{0x6d}, pl, &p2pkh_lock });
}

// --- the decoder ---

test "decoder: value, deploy, authority" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = brc162.decode(tokenScript(a, id_a, 5000, null)).?;
    try testing.expectEqual(brc162.Role.value, v.role);
    try testing.expectEqual(@as(u64, 5000), v.amount);
    try testing.expectEqualSlices(u8, &id_a, &v.id.?.txid);
    try testing.expectEqual(@as(u32, 0), v.id.?.vout);
    try testing.expectEqualSlices(u8, &p2pkh_lock, v.lock);
    try testing.expect(v.payload == null);

    const small = brc162.decode(tokenScript(a, id_a, 7, null)).?; // OP_7
    try testing.expectEqual(@as(u64, 7), small.amount);

    // 16 (OP_16, the top of the OP_1..OP_16 range) and 17 (the smallest
    // amount that must use a direct push, minimally: `01 11`).
    const sixteen = brc162.decode(tokenScript(a, id_a, 16, null)).?;
    try testing.expectEqual(@as(u64, 16), sixteen.amount);
    const seventeen = cat(a, &.{ &.{0x20}, &id_a, &.{ 0x01, 0x11, 0x6d }, &p2pkh_lock });
    try testing.expectEqual(@as(u64, 17), brc162.decode(seventeen).?.amount);

    const d = brc162.decode(tokenScript(a, null, 21_000_000, null)).?;
    try testing.expectEqual(brc162.Role.deploy, d.role);
    try testing.expect(d.id == null);
    try testing.expectEqual(@as(u64, 21_000_000), d.amount);

    const d0 = brc162.decode(tokenScript(a, null, 0, null)).?;
    try testing.expectEqual(brc162.Role.deploy, d0.role);
    try testing.expect(d0.isAuthority());

    const auth = brc162.decode(tokenScript(a, id_a, 0, null)).?;
    try testing.expectEqual(brc162.Role.authority, auth.role);
    try testing.expectEqual(@as(u64, 0), auth.amount);

    // A 36-byte id (a legacy token deployed at a non-zero output): txid ‖ LE vout.
    const id36 = [_]u8{0xa5} ** 32 ++ [_]u8{ 7, 1, 0, 0 };
    const l = brc162.decode(cat(a, &.{ &.{0x24}, &id36, &.{ 0x55, 0x6d }, &p2pkh_lock })).?;
    try testing.expectEqualSlices(u8, &id_a, &l.id.?.txid);
    try testing.expectEqual(@as(u32, 263), l.id.?.vout);
    try testing.expectEqual(@as(u64, 5), l.amount);
    var ib: [37]u8 = undefined;
    try testing.expectEqualSlices(u8, &([_]u8{0x24} ++ id36), brc162.pushId(&ib, l.id.?));
    try testing.expectEqualSlices(u8, &([_]u8{0x20} ++ id_a), brc162.pushId(&ib, .{ .txid = id_a }));

    // The largest amount, 2^64 - 1, in nine bytes.
    const max = cat(a, &.{ &.{0x20}, &id_a, &.{ 0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x6d }, &p2pkh_lock });
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), brc162.decode(max).?.amount);
}

test "decoder: payloads are recorded, never validated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cbor_map = [_]u8{ 0x04, 0xa1, 0x61, 0x78, 0x01 }; // push {"x": 1}
    const t = brc162.decode(tokenScript(a, null, 1000, &cbor_map)).?;
    try testing.expectEqualSlices(u8, cbor_map[1..], t.payload.?);
    try testing.expectEqualSlices(u8, &p2pkh_lock, t.lock);

    // OP_0 OP_DROP: an empty payload; PUSHDATA1 works too.
    try testing.expectEqual(@as(usize, 0), brc162.decode(tokenScript(a, id_a, 5, &.{0x00})).?.payload.?.len);
    const big = cat(a, &.{ &.{ 0x4c, 0x50 }, &([_]u8{0xee} ** 0x50) });
    const tb = brc162.decode(tokenScript(a, id_a, 5, big)).?;
    try testing.expectEqual(@as(usize, 0x50), tb.payload.?.len);
    try testing.expectEqualSlices(u8, &p2pkh_lock, tb.lock);

    // A push not followed by OP_DROP is lock, not payload.
    const no = cat(a, &.{ &.{0x20}, &id_a, &.{ 0x55, 0x6d, 0x01, 0x07, 0x76 } });
    const tn = brc162.decode(no).?;
    try testing.expect(tn.payload == null);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x07, 0x76 }, tn.lock);
}

test "decoder: rejected shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A 36-byte id with vout 0 is non-canonical (that id is 32 bytes).
    const id36_0 = [_]u8{0xa5} ** 32 ++ [_]u8{ 0, 0, 0, 0 };
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x24}, &id36_0, &.{ 0x55, 0x6d }, &p2pkh_lock })) == null);
    // A 36-byte id through PUSHDATA1; ids of other lengths.
    const id36 = [_]u8{0xa5} ** 32 ++ [_]u8{ 1, 0, 0, 0 };
    try testing.expect(brc162.decode(cat(a, &.{ &.{ 0x4c, 0x24 }, &id36, &.{ 0x55, 0x6d }, &p2pkh_lock })) == null);
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x21}, &id_a, &.{ 0, 0x55, 0x6d }, &p2pkh_lock })) == null);
    // A 32-byte id through a non-minimal PUSHDATA1.
    try testing.expect(brc162.decode(cat(a, &.{ &.{ 0x4c, 0x20 }, &id_a, &.{ 0x55, 0x6d }, &p2pkh_lock })) == null);
    // Non-minimal amounts: 5 with a trailing zero byte; zero as a one-byte push.
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x02, 0x05, 0x00, 0x6d }, &p2pkh_lock })) == null);
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x01, 0x00, 0x6d }, &p2pkh_lock })) == null);
    // A direct push of 1..16 is not minimal for the whole push (MINIMALDATA):
    // 5 and 16 must be OP_5 and OP_16.
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x01, 0x05, 0x6d }, &p2pkh_lock })) == null);
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x01, 0x10, 0x6d }, &p2pkh_lock })) == null);
    // Negative amounts.
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x01, 0x85, 0x6d }, &p2pkh_lock })) == null);
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x4f, 0x6d }, &p2pkh_lock })) == null);
    // Above 2^64 - 1.
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x6d }, &p2pkh_lock })) == null);
    // No OP_2DROP; a plain P2PKH; truncated.
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, &id_a, &.{ 0x55, 0x75 }, &p2pkh_lock })) == null);
    try testing.expect(brc162.decode(&p2pkh_lock) == null);
    try testing.expect(brc162.decode(cat(a, &.{ &.{0x20}, id_a[0..10] })) == null);
}

// --- the BSV-21 rules ---

const Coin = struct { txid: [32]u8, vout: u32 = 0, script: []const u8 };

fn txOf(a: std.mem.Allocator, txid: [32]u8, ins: []const Coin, outs: []const []const u8) bsv21.Tx {
    const inputs = a.alloc(bsv21.Input, ins.len) catch @panic("OOM");
    for (ins, inputs) |c, *x| x.* = .{ .txid = c.txid, .vout = c.vout, .source = .{ .script = c.script, .satoshis = 1 } };
    const outputs = a.alloc(bsv21.Output, outs.len) catch @panic("OOM");
    for (outs, outputs) |s, *x| x.* = .{ .script = s, .satoshis = 1 };
    return .{ .txid = txid, .inputs = inputs, .outputs = outputs };
}

fn all(n: u32) []const u32 {
    const S = struct {
        const xs = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    };
    return S.xs[0..n];
}

test "bsv21: transfers conserve value; a shortfall is an implicit burn; an excess admits nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = struct {
        fn v(al: std.mem.Allocator, n: u64) []u8 {
            return tokenScript(al, id_a, n, null);
        }
    };
    const tx1 = [_]u8{1} ** 32;

    // In 1000 + 500, out 800 + 600 + 100, plus a plain output.
    const ok = txOf(a, tx1, &.{ .{ .txid = .{2} ** 32, .script = t.v(a, 1000) }, .{ .txid = .{3} ** 32, .script = t.v(a, 500) } }, &.{ t.v(a, 800), t.v(a, 600), &p2pkh_lock, t.v(a, 100) });
    const v1 = try token.judge(a, tid_a, ok, all(2));
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3 }, v1.outputs_to_admit);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, v1.coins_to_retain);

    // In 500, out 300 + 400: nothing admitted, nothing retained.
    const over = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = t.v(a, 500) }}, &.{ t.v(a, 300), t.v(a, 400) });
    const v2 = try token.judge(a, tid_a, over, all(1));
    try testing.expectEqual(@as(usize, 0), v2.outputs_to_admit.len);
    try testing.expectEqual(@as(usize, 0), v2.coins_to_retain.len);
    try testing.expectEqual(token.Verdict.Reason.inflation, v2.rejected.?);

    // In 1000, out 250: 750 burned.
    const burn = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = t.v(a, 1000) }}, &.{t.v(a, 250)});
    const j = try bsv21.judge(a, tid_a, burn, all(1));
    try testing.expect(j.ok);
    try testing.expectEqual(@as(u128, 750), j.burned);
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, tid_a, burn, all(1))).outputs_to_admit);

    // An input that is not a previous coin does not count.
    const not_coin = txOf(a, tx1, &.{ .{ .txid = .{2} ** 32, .script = t.v(a, 500) }, .{ .txid = .{3} ** 32, .script = t.v(a, 500) } }, &.{t.v(a, 1000)});
    try testing.expect((try token.judge(a, tid_a, not_coin, &.{0})).rejected != null);
    try testing.expect((try token.judge(a, tid_a, not_coin, &.{ 1, 0 })).rejected == null);

    // Another token's outputs are not this topic's.
    const other = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = t.v(a, 500) }}, &.{ t.v(a, 500), tokenScript(a, .{0x5a} ** 32, 900, null) });
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, tid_a, other, all(1))).outputs_to_admit);

    // A previous coin without its source cannot be judged.
    var missing = ok;
    const ins = try a.dupe(bsv21.Input, ok.inputs);
    ins[0].source = null;
    missing.inputs = ins;
    try testing.expectError(error.MissingSource, token.judge(a, tid_a, missing, all(2)));
}

test "bsv21: mint through an authority input; authority outputs need one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tx1 = [_]u8{1} ** 32;
    const auth = tokenScript(a, id_a, 0, null);

    // In: authority. Out: value 1,000,000 + authority.
    const mint = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = auth }}, &.{ tokenScript(a, id_a, 1_000_000, null), auth });
    const j = try bsv21.judge(a, tid_a, mint, all(1));
    try testing.expect(j.ok and j.minted);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try token.judge(a, tid_a, mint, all(1))).outputs_to_admit);

    // The genesis authority (a zero-amount deploy, spent from the deploy txid:0) mints too.
    const genesis = txOf(a, tx1, &.{.{ .txid = id_a, .script = tokenScript(a, null, 0, null) }}, &.{tokenScript(a, id_a, 42, null)});
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, tid_a, genesis, all(1))).outputs_to_admit);

    // Without the authority input the same outputs inflate: nothing admitted.
    const plain = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = tokenScript(a, id_a, 10, null) }}, &.{ tokenScript(a, id_a, 1_000_000, null), auth });
    try testing.expectEqual(@as(usize, 0), (try token.judge(a, tid_a, plain, all(1))).outputs_to_admit.len);

    // A covered transfer with a stray authority output: the authority is left out.
    const stray = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = tokenScript(a, id_a, 10, null) }}, &.{ tokenScript(a, id_a, 10, null), auth });
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, tid_a, stray, all(1))).outputs_to_admit);
}

test "bsv21: a deploy is admitted at output 0 of the token's own transaction only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = tokenScript(a, null, 10_000, null);

    const deploy = txOf(a, id_a, &.{.{ .txid = .{9} ** 32, .script = &p2pkh_lock }}, &.{ d, &p2pkh_lock });
    const v = try token.judge(a, tid_a, deploy, &.{});
    try testing.expectEqualSlices(u32, &.{0}, v.outputs_to_admit);

    // At output 1 it is not a deploy.
    const late = txOf(a, id_a, &.{}, &.{ &p2pkh_lock, d });
    try testing.expectEqual(@as(usize, 0), (try token.judge(a, tid_a, late, &.{})).outputs_to_admit.len);
    // Another transaction's deploy is another token.
    const other = txOf(a, .{7} ** 32, &.{}, &.{d});
    try testing.expectEqual(@as(usize, 0), (try token.judge(a, tid_a, other, &.{})).outputs_to_admit.len);
}

// --- BRC-161 (JSON, legacy) ---

/// A 1Sat ord envelope (content type `ct`, body `body`) before `lock`.
fn inscription(a: std.mem.Allocator, ct: []const u8, body: []const u8, lock: []const u8) []u8 {
    return cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x51 }, pushOf(a, ct), &.{0x00}, pushOf(a, body), &.{0x68}, lock });
}

fn pushOf(a: std.mem.Allocator, data: []const u8) []u8 {
    if (data.len < 0x4c) return cat(a, &.{ &.{@intCast(data.len)}, data });
    if (data.len <= 0xff) return cat(a, &.{ &.{ 0x4c, @intCast(data.len) }, data });
    return cat(a, &.{ &.{ 0x4d, @intCast(data.len & 0xff), @intCast(data.len >> 8) }, data });
}

/// A bsv-20 output before a P2PKH lock.
fn bsv20(a: std.mem.Allocator, body: []const u8) []u8 {
    return inscription(a, brc161.content_type, body, &p2pkh_lock);
}

fn idString(a: std.mem.Allocator, txid: [32]u8, vout: u32) []const u8 {
    return std.fmt.allocPrint(a, "{s}_{d}", .{ &w.header.toHex(txid), vout }) catch @panic("OOM");
}

fn jsonOp(a: std.mem.Allocator, op: []const u8, txid: [32]u8, vout: u32, amt: ?u64) []u8 {
    const id = idString(a, txid, vout);
    return bsv20(a, if (amt) |n|
        std.fmt.allocPrint(a, "{{\"p\":\"bsv-20\",\"op\":\"{s}\",\"id\":\"{s}\",\"amt\":\"{d}\"}}", .{ op, id, n }) catch @panic("OOM")
    else
        std.fmt.allocPrint(a, "{{\"p\":\"bsv-20\",\"op\":\"{s}\",\"id\":\"{s}\"}}", .{ op, id }) catch @panic("OOM"));
}

fn decodeBody(a: std.mem.Allocator, body: []const u8) !?brc161.Token {
    return brc161.decode(a, bsv20(a, body));
}

test "brc161: the envelope, where 1sat-stack finds it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":\"" ++ "ab" ** 32 ++ "_3\",\"amt\":\"42\"}";

    // Before the lock (as 1sat-stack writes it) and after it.
    const before = (try brc161.decode(a, bsv20(a, body))).?;
    try testing.expectEqual(brc161.Op.transfer, before.op);
    try testing.expectEqual(@as(u64, 42), before.amount);
    try testing.expectEqual(@as(u32, 3), before.id.?.vout);
    try testing.expectEqual(@as(u8, 0xab), before.id.?.txid[0]);
    try testing.expectEqual(@as(usize, 0), before.prefix.len);
    try testing.expectEqualSlices(u8, &p2pkh_lock, before.suffix);
    const suffixed = cat(a, &.{ &p2pkh_lock, inscription(a, brc161.content_type, body, &.{}) });
    const t2 = (try brc161.decode(a, suffixed)).?;
    try testing.expectEqualSlices(u8, &p2pkh_lock, t2.prefix);
    try testing.expectEqual(@as(usize, 0), t2.suffix.len);

    // Named fields (a multi-byte tag) are skipped; content type 1 may repeat
    // (the last wins); a one-byte push tag works like OP_1.
    const named = cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x02, 'x', 'y', 0x01, 0x07, 0x51, 0x04, 't', 'e', 'x', 't', 0x01, 0x01 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body), &.{0x68}, &p2pkh_lock });
    try testing.expect((try brc161.decode(a, named)) != null);
    // The content followed by the end of the script (no OP_ENDIF) is still an envelope.
    const open_end = cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x51 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body) });
    try testing.expect((try brc161.decode(a, open_end)) != null);

    // Not an envelope: anything but OP_ENDIF after the content; "ord" not
    // preceded by OP_0 OP_IF; "ord" through PUSHDATA1; a non-push tag.
    const no_endif = cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x51 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body), &.{0x76}, &p2pkh_lock });
    try testing.expect((try brc161.decode(a, no_endif)) == null);
    const no_if = cat(a, &.{ &.{ 0x00, 0x00, 0x03, 'o', 'r', 'd', 0x51 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body), &.{0x68} });
    try testing.expect((try brc161.decode(a, no_if)) == null);
    const pd1 = cat(a, &.{ &.{ 0x00, 0x63, 0x4c, 0x03, 'o', 'r', 'd', 0x51 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body), &.{0x68} });
    try testing.expect((try brc161.decode(a, pd1)) == null);
    const bad_tag = cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x76 }, pushOf(a, brc161.content_type), &.{0x00}, pushOf(a, body), &.{0x68} });
    try testing.expect((try brc161.decode(a, bad_tag)) == null);
    // Another content type; no content type.
    try testing.expect((try brc161.decode(a, inscription(a, "application/json", body, &p2pkh_lock))) == null);
    const no_ct = cat(a, &.{ &.{ 0x00, 0x63, 0x03, 'o', 'r', 'd', 0x00 }, pushOf(a, body), &.{0x68} });
    try testing.expect((try brc161.decode(a, no_ct)) == null);
}

test "brc161: the body's field rules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = "\"" ++ "ab" ** 32 ++ "_0\"";

    const dm = (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"21000000\",\"sym\":\"GOLD\",\"dec\":\"8\",\"icon\":\"_0\",\"id\":\"junk\"}")).?;
    try testing.expectEqual(brc161.Op.deploy_mint, dm.op);
    try testing.expectEqual(@as(u64, 21_000_000), dm.amount);
    try testing.expect(dm.id == null); // ignored on a deploy
    try testing.expectEqualStrings("GOLD", dm.sym.?);
    try testing.expectEqual(@as(u8, 8), dm.dec.?);
    try testing.expectEqualStrings("_0", dm.icon.?);
    const da = (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+auth\"}")).?;
    try testing.expectEqual(brc161.Op.deploy_auth, da.op);
    try testing.expectEqual(@as(u64, 0), da.amount);
    try testing.expectEqual(brc161.Op.auth, (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"auth\",\"id\":" ++ id ++ "}")).?.op);
    try testing.expectEqual(brc161.Op.mint, (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"mint\",\"id\":" ++ id ++ ",\"amt\":\"5\"}")).?.op);
    try testing.expectEqual(brc161.Op.burn, (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"burn\",\"id\":" ++ id ++ ",\"amt\":\"5\"}")).?.op);

    // Tolerated as 1sat-stack tolerates it: op in any case, leading zeros
    // and "0" in amt, the largest uint64, the last of duplicate keys,
    // unknown keys, whitespace.
    try testing.expectEqual(brc161.Op.transfer, (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"TRANSFER\",\"id\":" ++ id ++ ",\"amt\":\"5\"}")).?.op);
    try testing.expectEqual(@as(u64, 7), (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"007\"}")).?.amount);
    try testing.expectEqual(@as(u64, 0), (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"0\"}")).?.amount);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"18446744073709551615\"}")).?.amount);
    try testing.expectEqual(@as(u64, 2), (try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"1\",\"amt\":\"2\"}")).?.amount);
    try testing.expect((try decodeBody(a, " { \"x\": [1, {}], \"p\": \"bsv-20\", \"op\": \"transfer\", \"id\": " ++ id ++ ", \"amt\": \"1\" } ")) != null);
    // Display fields are deploy-only and never invalidate (BRC-161; 1sat-stack
    // rejects a malformed dec): a numeric or out-of-range dec is dropped.
    try testing.expect((try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"1\",\"dec\":8}")).?.dec == null);
    try testing.expect((try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"1\",\"dec\":\"19\",\"sym\":5}")).?.sym == null);
    try testing.expect((try decodeBody(a, "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"1\",\"dec\":\"99\"}")) != null);

    // Not a token.
    for ([_][]const u8{
        "{\"p\":\"bsv-21\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"1\"}", // p
        "{\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"1\"}", // no p
        "{\"p\":\"bsv-20\",\"op\":\"send\",\"id\":" ++ id ++ ",\"amt\":\"1\"}", // op
        "{\"p\":\"bsv-20\",\"op\":7,\"id\":" ++ id ++ ",\"amt\":\"1\"}", // op not a string
        "{\"p\":\"bsv-20\",\"id\":" ++ id ++ ",\"amt\":\"1\"}", // no op
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":1}", // numeric amt
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"-1\"}",
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"+1\"}",
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"1.0\"}",
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"\"}",
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ ",\"amt\":\"18446744073709551616\"}", // 2^64
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":" ++ id ++ "}", // no amt
        "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\"}", // no amt
        "{\"p\":\"bsv-20\",\"op\":\"deploy+auth\",\"amt\":\"1\"}", // amt prohibited
        "{\"p\":\"bsv-20\",\"op\":\"auth\",\"id\":" ++ id ++ ",\"amt\":null}", // amt prohibited, in any form
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"amt\":\"1\"}", // no id
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":\"" ++ "AB" ** 32 ++ "_0\",\"amt\":\"1\"}", // uppercase id
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":\"" ++ "ab" ** 32 ++ ".0\",\"amt\":\"1\"}", // dot form
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":\"" ++ "ab" ** 32 ++ "_01\",\"amt\":\"1\"}", // leading zero
        "{\"p\":\"bsv-20\",\"op\":\"transfer\",\"id\":\"" ++ "ab" ** 32 ++ "\",\"amt\":\"1\"}", // no vout
        "[\"p\",\"bsv-20\"]", // not an object
        "{\"p\":\"bsv-20\",", // not JSON
    }) |body| {
        if ((try decodeBody(a, body)) != null) {
            std.debug.print("accepted: {s}\n", .{body});
            return error.TestUnexpectedResult;
        }
    }
}

test "bsv21: binary wins; a token at output 0 is one token in both forms; a legacy token at output 5 takes both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const leg0: bsv21.TokenId = .{ .txid = id_a, .vout = 0, .kind = .legacy };
    const leg5: bsv21.TokenId = .{ .txid = id_a, .vout = 5, .kind = .legacy };
    const tx1 = [_]u8{1} ** 32;

    // A binary prefix followed by a JSON inscription for the same token: binary.
    const both = cat(a, &.{ &.{0x20}, &id_a, &.{ 0x55, 0x6d }, jsonOp(a, "transfer", id_a, 0, 99) });
    const tb = (try bsv21.tokenOf(a, leg0, tx1, 0, both)).?;
    try testing.expectEqual(bsv21.Form.binary, tb.form);
    try testing.expectEqual(@as(u64, 5), tb.amount);
    // ... and when the binary prefix is another token's, it is not this one's at all.
    const other = cat(a, &.{ &.{0x20}, &([_]u8{0x5a} ** 32), &.{ 0x55, 0x6d }, jsonOp(a, "transfer", id_a, 0, 99) });
    try testing.expect((try bsv21.tokenOf(a, leg0, tx1, 0, other)) == null);
    // A 36-byte id with vout 0 is no binary prefix, so the inscription after it counts.
    const bad36 = cat(a, &.{ &.{0x24}, &id_a, &.{ 0, 0, 0, 0, 0x55, 0x6d }, jsonOp(a, "transfer", id_a, 0, 99) });
    try testing.expectEqual(bsv21.Form.json, (try bsv21.tokenOf(a, leg0, tx1, 0, bad36)).?.form);

    // A token deployed at output 0 (BRC-162 "Token identification": one token in both forms):
    // JSON naming <txid>_0 and binary with the 32-byte id are both its.
    try testing.expectEqual(bsv21.Form.json, (try bsv21.tokenOf(a, tid_a, tx1, 0, jsonOp(a, "transfer", id_a, 0, 1))).?.form);
    try testing.expect((try bsv21.tokenOf(a, tid_a, tx1, 0, tokenScript(a, id_a, 1, null))) != null);

    // A legacy token at output 5: JSON with id <txid>_5, binary with the 36-byte id only.
    try testing.expect((try bsv21.tokenOf(a, leg5, tx1, 0, jsonOp(a, "transfer", id_a, 5, 1))) != null);
    try testing.expect((try bsv21.tokenOf(a, leg5, tx1, 0, jsonOp(a, "transfer", id_a, 0, 1))) == null);
    try testing.expect((try bsv21.tokenOf(a, leg5, tx1, 0, tokenScript(a, id_a, 1, null))) == null);
    const b36 = cat(a, &.{ &.{0x24}, &id_a, &.{ 5, 0, 0, 0, 0x51, 0x6d }, &p2pkh_lock });
    try testing.expectEqual(bsv21.Form.binary, (try bsv21.tokenOf(a, leg5, tx1, 0, b36)).?.form);
    try testing.expect((try bsv21.tokenOf(a, leg0, tx1, 0, b36)) == null);

    // Genesis by the deploy output: at output 0 a binary or a JSON deploy (one token, either
    // form); at a non-zero output a JSON deploy only, at the deploy outpoint.
    const bdeploy = tokenScript(a, null, 100, null);
    const jdeploy = bsv20(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"100\"}");
    try testing.expectEqual(bsv21.Role.deploy, (try bsv21.tokenOf(a, tid_a, id_a, 0, bdeploy)).?.role);
    try testing.expectEqual(bsv21.Role.deploy, (try bsv21.tokenOf(a, leg0, id_a, 0, bdeploy)).?.role);
    try testing.expectEqual(bsv21.Role.deploy, (try bsv21.tokenOf(a, tid_a, id_a, 0, jdeploy)).?.role);
    try testing.expect((try bsv21.tokenOf(a, leg5, id_a, 5, bdeploy)) == null);
    try testing.expectEqual(bsv21.Role.deploy, (try bsv21.tokenOf(a, leg0, id_a, 0, jdeploy)).?.role);
    try testing.expectEqual(bsv21.Role.deploy, (try bsv21.tokenOf(a, leg5, id_a, 5, jdeploy)).?.role);
    try testing.expect((try bsv21.tokenOf(a, leg5, id_a, 4, jdeploy)) == null);
    try testing.expect((try bsv21.tokenOf(a, leg5, tx1, 5, jdeploy)) == null);
    // A JSON deploy+auth is an authority; a deploy+mint of "0" is not.
    const jauth = bsv20(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+auth\"}");
    try testing.expect((try bsv21.tokenOf(a, leg0, id_a, 0, jauth)).?.authority);
    const jzero = bsv20(a, "{\"p\":\"bsv-20\",\"op\":\"deploy+mint\",\"amt\":\"0\"}");
    try testing.expect(!(try bsv21.tokenOf(a, leg0, id_a, 0, jzero)).?.authority);
}

test "bsv21: JSON rules per BRC-161 (mint, auth, burn; authority does not fund transfers)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const L: bsv21.TokenId = .{ .txid = id_a, .vout = 2, .kind = .legacy };
    const tx1 = [_]u8{1} ** 32;
    const auth = jsonOp(a, "auth", id_a, 2, null);
    const t = struct {
        fn op(al: std.mem.Allocator, o: []const u8, n: u64) []u8 {
            return jsonOp(al, o, id_a, 2, n);
        }
    };

    // Authority in; out: mint 1000, auth, and an unfunded transfer 5. The
    // authority does not fund the transfer (BRC-161), so it alone is left
    // out; the mint and the auth stand.
    const m = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = auth }}, &.{ t.op(a, "mint", 1000), auth, t.op(a, "transfer", 5) });
    const jm = try bsv21.judge(a, L, m, all(1));
    try testing.expect(jm.ok and jm.minted);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try token.judge(a, L, m, all(1))).outputs_to_admit);
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, L, m, all(1))).coins_to_retain);
    // Binary value outputs alongside the same authority are mints (BRC-162).
    var b36: [37]u8 = undefined;
    const bin = cat(a, &.{ brc162.pushId(&b36, L.wire()), &.{ 0x55, 0x6d }, &p2pkh_lock });
    const mb = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = auth }}, &.{ bin, t.op(a, "transfer", 5) });
    try testing.expectEqualSlices(u32, &.{0}, (try token.judge(a, L, mb, all(1))).outputs_to_admit);

    // A mint without an authority input is left out; the covered transfer stands.
    const v = t.op(a, "transfer", 100);
    const nm = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = v }}, &.{ t.op(a, "mint", 1000), t.op(a, "transfer", 60) });
    try testing.expectEqualSlices(u32, &.{1}, (try token.judge(a, L, nm, all(1))).outputs_to_admit);
    // An auth output without one too: here nothing is left, but nothing broke the balance.
    const na = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = v }}, &.{auth});
    const vna = try token.judge(a, L, na, all(1));
    try testing.expect(vna.rejected == null and vna.outputs_to_admit.len == 0);

    // Burns: balance-checked with transfers (I >= O_t + O_b), admitted.
    const burn = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = v }}, &.{ t.op(a, "transfer", 60), t.op(a, "burn", 40) });
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try token.judge(a, L, burn, all(1))).outputs_to_admit);
    const over = txOf(a, tx1, &.{.{ .txid = .{2} ** 32, .script = v }}, &.{ t.op(a, "transfer", 60), t.op(a, "burn", 41) });
    try testing.expectEqual(token.Verdict.Reason.inflation, (try token.judge(a, L, over, all(1))).rejected.?);
    // A burn input carries nothing and is not one of the token's inputs.
    const spend_burn = txOf(a, tx1, &.{ .{ .txid = .{2} ** 32, .script = t.op(a, "burn", 40) }, .{ .txid = .{3} ** 32, .script = v } }, &.{t.op(a, "transfer", 140)});
    try testing.expect((try token.judge(a, L, spend_burn, all(2))).rejected != null);
    const ok_burn = txOf(a, tx1, &.{ .{ .txid = .{2} ** 32, .script = t.op(a, "burn", 40) }, .{ .txid = .{3} ** 32, .script = v } }, &.{t.op(a, "transfer", 100)});
    const vb = try token.judge(a, L, ok_burn, all(2));
    try testing.expectEqualSlices(u32, &.{0}, vb.outputs_to_admit);
    try testing.expectEqualSlices(u32, &.{1}, vb.coins_to_retain);
}

// --- the pool, on gen/main.go's transactions ---

const Fixtures = struct {
    txs: std.AutoHashMap([32]u8, bsvz.transaction.Transaction),
    raws: std.StringHashMap([]const u8),
    id: [32]u8,

    fn init(a: std.mem.Allocator) !Fixtures {
        var f: Fixtures = .{ .txs = .init(a), .raws = .init(a), .id = undefined };
        inline for (.{
            "fund",         "token_deploy",       "pool_deploy",        "swap_bsv_in",     "swap_tokens_in",  "remove_liquidity",
            "legacy_fund",  "legacy_deploy0",     "legacy_deploy1",     "legacy_transfer", "legacy_migrate0", "legacy_migrate1",
            "legacy_mixed", "legacy_binary_json", "legacy_auth_deploy", "legacy_mint",     "legacy_unfunded",
        }) |name| {
            const raw = unhex(a, @field(vec, name));
            try f.raws.put(name, raw);
            try f.txs.put(w.beef.txidOf(raw), try bsvz.transaction.Transaction.parse(a, raw));
        }
        f.id = w.beef.txidOf(f.raws.get("token_deploy").?);
        return f;
    }

    /// A fixture transaction as the rules see it, sources filled from the others.
    fn tx(self: Fixtures, a: std.mem.Allocator, name: []const u8) !bsv21.Tx {
        const raw = self.raws.get(name).?;
        const t = self.txs.get(w.beef.txidOf(raw)).?;
        const ins = try a.alloc(bsv21.Input, t.inputs.len);
        for (t.inputs, ins) |in, *x| {
            x.* = .{ .txid = in.previous_outpoint.txid.bytes, .vout = in.previous_outpoint.index, .unlocking_script = in.unlocking_script.bytes };
            if (self.txs.get(x.txid)) |src| {
                const o = src.outputs[x.vout];
                x.source = .{ .script = o.locking_script.bytes, .satoshis = @intCast(o.satoshis) };
            }
        }
        const outs = try a.alloc(bsv21.Output, t.outputs.len);
        for (t.outputs, outs) |o, *x| x.* = .{ .script = o.locking_script.bytes, .satoshis = @intCast(o.satoshis) };
        return .{ .txid = w.beef.txidOf(raw), .inputs = ins, .outputs = outs };
    }
};

fn key20(h: []const u8) [20]u8 {
    var k: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&k, h) catch unreachable;
    return k;
}

/// `tx` with output i's script replaced.
fn withOutput(a: std.mem.Allocator, tx: bsv21.Tx, i: usize, script: []const u8) !bsv21.Tx {
    const outs = try a.dupe(bsv21.Output, tx.outputs);
    outs[i].script = script;
    var t = tx;
    t.outputs = outs;
    return t;
}

test "fixtures: a contract's deploy (amm-poc's pool) admitted as token outputs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);
    const tx = try f.tx(a, "pool_deploy");

    const v = try token.judge(a, .{ .txid = f.id }, tx, &.{0});
    try testing.expect(v.rejected == null);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, v.outputs_to_admit); // pool, the taker's 50,000, the LP's change
    try testing.expectEqualSlices(u32, &.{0}, v.coins_to_retain);
}

test "fixtures: a contract's spends (amm-poc's swaps and a liquidity removal) admitted as token outputs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);

    // Sats in: pool continuation (0) and the token payout (1) are admitted;
    // the LP and validator fees and the commission (2, 3, 4) and the change
    // (5) are P2PKH; the commission pays the fixture relay.
    const s1 = try f.tx(a, "swap_bsv_in");
    const v1 = try token.judge(a, .{ .txid = f.id }, s1, &.{0});
    try testing.expect(v1.rejected == null);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, v1.outputs_to_admit);
    try testing.expectEqualSlices(u32, &.{0}, v1.coins_to_retain);
    for (s1.outputs[2..]) |o| try testing.expect(brc162.decode(o.script) == null);
    try testing.expectEqual(@as(usize, 6), s1.outputs.len);
    try testing.expectEqual(@as(u64, (20_000 * vec.commission_bps + 9999) / 10000), s1.outputs[4].satoshis);
    try testing.expectEqualSlices(u8, &key20(vec.commission_pkh), s1.outputs[4].script[3..23]);
    try testing.expectEqual(@as(u64, vec.swap_bsv_in_tokens_out), brc162.decode(s1.outputs[1].script).?.amount);
    try testing.expectEqual(@as(u64, vec.pool1.tokens), brc162.decode(s1.outputs[0].script).?.amount);

    // Tokens in: the pool (0) and the taker's tokens (1) are spent; the pool,
    // and the LP and validator token fees and the commission (2, 3, 4) are
    // admitted; the sats payout (1) and change (5) are P2PKH.
    const s2 = try f.tx(a, "swap_tokens_in");
    const v2 = try token.judge(a, .{ .txid = f.id }, s2, &.{ 0, 1 });
    try testing.expect(v2.rejected == null);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3, 4 }, v2.outputs_to_admit);
    const c2 = brc162.decode(s2.outputs[4].script).?;
    try testing.expectEqual(@as(u64, (50_000 * vec.commission_bps + 9999) / 10000), c2.amount);
    try testing.expectEqualSlices(u8, &key20(vec.commission_pkh), c2.lock[3..23]);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, v2.coins_to_retain);

    // Without the taker's token input as a previous coin, the tokens in are
    // unaccounted for: rejected.
    try testing.expect((try token.judge(a, .{ .txid = f.id }, s2, &.{0})).rejected != null);

    // RemoveLiquidity keeps the validator key: continuation (0) and the LP's
    // token withdrawal (2).
    const r = try f.tx(a, "remove_liquidity");
    const v3 = try token.judge(a, .{ .txid = f.id }, r, &.{0});
    try testing.expect(v3.rejected == null);
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, v3.outputs_to_admit);
}

// --- the program: topic names and the topic contract ---

test "topic names: tm_<txid> native, tm_<txid>_<vout> legacy; AMM-prefixed names are not ours; token id strings" {
    var buf: [names.max_topic_len]u8 = undefined;
    const nm = names.topicName(&buf, .{ .txid = id_a });
    try testing.expectEqualStrings("tm_" ++ w.header.toHex(id_a), nm);
    const n = token.tokenIdOf(nm).?;
    try testing.expectEqualSlices(u8, &id_a, &n.txid);
    try testing.expectEqual(bsv21.Kind.native, n.kind);
    try testing.expectEqual(@as(u32, 0), n.vout);
    const rev = "tm_0102030405060708091011121314151617181920212223242526272829303132";
    const got = token.tokenIdOf(rev).?.txid;
    try testing.expectEqual(@as(u8, 0x32), got[0]);
    try testing.expectEqual(@as(u8, 0x01), got[31]);
    try testing.expect(token.tokenIdOf("tm_" ++ "AB" ** 32) == null); // uppercase
    try testing.expect(token.tokenIdOf("tm_abcd") == null);
    try testing.expect(token.tokenIdOf("tm_demo") == null);

    // Legacy BRC-161 `tm_<txid>_<vout>` at a non-zero output only. A BRC-161 token deployed at
    // output 0 is `tm_<txid>` (BRC-162: its id is the 32-byte txid); `tm_<txid>_0` is no topic.
    try testing.expect(token.tokenIdOf(rev ++ "_0") == null);
    const l7 = token.tokenIdOf(rev ++ "_4294967295").?;
    try testing.expectEqual(bsv21.Kind.legacy, l7.kind);
    try testing.expectEqual(@as(u32, 4294967295), l7.vout);
    try testing.expectEqualStrings(rev ++ "_12", names.topicName(&buf, .{ .txid = got, .vout = 12, .kind = .legacy }));
    try testing.expectEqualStrings(rev, names.topicName(&buf, .{ .txid = got, .vout = 0, .kind = .legacy }));
    // Not canonical: leading zeros, sign, empty, too large, other separators.
    for ([_][]const u8{ "_00", "_01", "_+1", "_", "_4294967296", ".0", "_1_2", "_-1", "_ 1" }) |bad| {
        var nb: [100]u8 = undefined;
        try testing.expect(token.tokenIdOf(try std.fmt.bufPrint(&nb, "{s}{s}", .{ rev, bad })) == null);
    }
    // The old AMM topic name.
    try testing.expect(token.tokenIdOf("tm_amm_" ++ rev[3..]) == null);

    // Token id strings, taken in every form: `<txid>`, `<txid>_<vout>`, `<txid>.<vout>`. `<txid>`,
    // `<txid>_0` and `<txid>.0` are the token at output 0; any other vout a BRC-161 one.
    for ([_][]const u8{ rev[3..], rev[3..] ++ "_0", rev[3..] ++ ".0" }) |form| {
        const sid = names.tokenIdOfString(form).?;
        try testing.expectEqual(names.Kind.native, sid.kind);
        try testing.expectEqual(@as(u32, 0), sid.vout);
        try testing.expectEqualSlices(u8, &got, &sid.txid);
        try testing.expectEqualStrings(rev, names.topicName(&buf, sid));
    }
    for ([_][]const u8{ rev[3..] ++ "_3", rev[3..] ++ ".3" }) |form| {
        const sid3 = names.tokenIdOfString(form).?;
        try testing.expectEqual(names.Kind.legacy, sid3.kind);
        try testing.expectEqual(@as(u32, 3), sid3.vout);
        try testing.expectEqualStrings(rev ++ "_3", names.topicName(&buf, sid3));
    }
    for ([_][]const u8{ rev[3..] ++ "_03", rev[3..] ++ "_", rev[3..] ++ "-0", rev[3..] ++ "_4294967296", "AB" ** 32 ++ "_0", "AB" ** 32, rev[3..66] }) |bad| {
        try testing.expect(names.tokenIdOfString(bad) == null);
    }

    // Written out in the origin's form: Mandala `<txid>`, BSV-21 `<txid>_<vout>` (`_0` included).
    var tb: [names.max_suffix_len]u8 = undefined;
    const at0: names.TokenId = .{ .txid = got };
    try testing.expectEqualStrings(rev[3..], names.tokenIdText(&tb, at0, .mandala));
    try testing.expectEqualStrings(rev[3..] ++ "_0", names.tokenIdText(&tb, at0, .bsv21));
    const at3: names.TokenId = .{ .txid = got, .vout = 3, .kind = .legacy };
    try testing.expectEqualStrings(rev[3..] ++ "_3", names.tokenIdText(&tb, at3, .bsv21));
    try testing.expectEqualStrings(rev[3..] ++ "_3", names.tokenIdText(&tb, at3, .mandala)); // only BSV-21 has one
}

fn callArgs(a: std.mem.Allocator, t: []const u8, tx_cid: []const u8, previous: []const u32) !Value {
    const pc = try a.alloc(Value, previous.len);
    for (previous, pc) |p, *v| v.* = .{ .uint = p };
    return .{ .map = try a.dupe(w.cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "topic-call" } },
        .{ .key = "topic", .value = .{ .text = t } },
        .{ .key = "tx", .value = .{ .cid = tx_cid } },
        .{ .key = "previousCoins", .value = .{ .array = pc } },
    }) };
}

fn uintsOf(a: std.mem.Allocator, v: Value) ![]u32 {
    const out = try a.alloc(u32, v.array.len);
    for (v.array, out) |x, *o| o.* = @intCast(x.uint);
    return out;
}

test "program: identify through the topic contract, reading records from a store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const f = try Fixtures.init(a);
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = names.topicName(&buf, .{ .txid = f.id });

    // The subject and its previous coins' sources, each as a bitcoin-tx block.
    var subject: []const u8 = undefined;
    inline for (.{ "fund", "token_deploy", "pool_deploy", "swap_bsv_in" }) |nm| {
        const cid = try s.putBitcoin(a, .tx, f.raws.get(nm).?);
        if (comptime std.mem.eql(u8, nm, "swap_bsv_in")) subject = cid;
    }
    const rec = try topic.judge(a, s, program.identify, try callArgs(a, tname, subject, &.{0}));
    try testing.expectEqualStrings("admittance", rec.getText("kind").?);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, try uintsOf(a, rec.get("outputsToAdmit").?));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rec.get("coinsToRetain").?));

    // The token deploy itself, with no previous coins.
    const deploy_cid = try s.putBitcoin(a, .tx, f.raws.get("token_deploy").?);
    const rd = try topic.judge(a, s, program.identify, try callArgs(a, tname, deploy_cid, &.{}));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rd.get("outputsToAdmit").?));

    // Not a token topic: tm_demo.
    try testing.expectError(error.UnknownTopic, topic.judge(a, s, program.identify, try callArgs(a, "tm_demo", subject, &.{0})));
    // `tm_<txid>_0` is no topic (a token at output 0 is `tm_<txid>` in either form).
    const legacy = try std.mem.concat(a, u8, &.{ tname, "_0" });
    try testing.expectError(error.UnknownTopic, topic.judge(a, s, program.identify, try callArgs(a, legacy, deploy_cid, &.{})));
}

// --- legacy BRC-161 tokens and their migration, on gen/main.go's transactions ---

fn legacyId(f: Fixtures, deploy: []const u8, vout: u32) bsv21.TokenId {
    return .{ .txid = w.beef.txidOf(f.raws.get(deploy).?), .vout = vout, .kind = .legacy };
}

fn expectVerdict(a: std.mem.Allocator, f: Fixtures, id: bsv21.TokenId, name: []const u8, coins: []const u32, admit: []const u32) !void {
    const v = try token.judge(a, id, try f.tx(a, name), coins);
    try testing.expect(v.rejected == null);
    try testing.expectEqualSlices(u32, admit, v.outputs_to_admit);
    try testing.expectEqualSlices(u32, coins, v.coins_to_retain);
}

fn formsOf(a: std.mem.Allocator, f: Fixtures, id: bsv21.TokenId, name: []const u8, coins: []const u32) ![]bsv21.Form {
    const j = try bsv21.judge(a, id, try f.tx(a, name), coins);
    const out = try a.alloc(bsv21.Form, j.outputs.len);
    for (j.outputs, out) |o, *x| x.* = o.token.form;
    return out;
}

test "legacy: JSON deploys at output 0 and at a non-zero output; a JSON transfer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);
    const L0 = legacyId(f, "legacy_deploy0", 0);
    const L1 = legacyId(f, "legacy_deploy1", 1);

    try expectVerdict(a, f, L0, "legacy_deploy0", &.{}, &.{0});
    try expectVerdict(a, f, L1, "legacy_deploy1", &.{}, &.{1});
    // deploy0 at output 0 is the token of `tm_<txid>` whatever the kind says (the deploy output
    // decides); deploy1's output 0 is not deploy1's token.
    try expectVerdict(a, f, .{ .txid = L0.txid }, "legacy_deploy0", &.{}, &.{0});
    try expectVerdict(a, f, .{ .txid = L1.txid, .vout = 0, .kind = .legacy }, "legacy_deploy1", &.{}, &.{});

    // deploy0:0 (1,000,000) -> 600,000 (envelope before the lock) + 400,000 (after it).
    try expectVerdict(a, f, L0, "legacy_transfer", &.{0}, &.{ 0, 1 });
    const j = try bsv21.judge(a, L0, try f.tx(a, "legacy_transfer"), &.{0});
    try testing.expectEqual(@as(u64, 600_000), j.outputs[0].token.amount);
    try testing.expectEqual(@as(usize, 0), j.outputs[0].token.json.?.prefix.len);
    try testing.expectEqual(@as(usize, 25), j.outputs[1].token.json.?.prefix.len); // the P2PKH lock first
    try testing.expectEqual(@as(u128, 0), j.burned);
    try testing.expectEqual(bsv21.Role.deploy, j.inputs[0].token.role);
}

test "legacy: migration to binary (32- and 36-byte ids), mixed outputs, and the one-way rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);
    const L0 = legacyId(f, "legacy_deploy0", 0);
    const L1 = legacyId(f, "legacy_deploy1", 1);

    // JSON 600,000 in -> binary 350,000 + 250,000 with the 32-byte id.
    try expectVerdict(a, f, L0, "legacy_migrate0", &.{0}, &.{ 0, 1 });
    try testing.expectEqualSlices(bsv21.Form, &.{ .binary, .binary }, try formsOf(a, f, L0, "legacy_migrate0", &.{0}));
    const m0 = try f.tx(a, "legacy_migrate0");
    try testing.expectEqual(@as(u8, 0x20), m0.outputs[0].script[0]);
    try testing.expectEqualSlices(u8, &L0.txid, m0.outputs[0].script[1..33]);
    // In the native topic of the same txid those binary outputs spend no
    // coin it holds (its genesis would be a binary deploy): unfunded.
    try testing.expect((try token.judge(a, .{ .txid = L0.txid }, m0, &.{})).rejected != null);

    // JSON deploy1:1 -> binary 500,000 with the 36-byte id (txid ‖ LE 1).
    try expectVerdict(a, f, L1, "legacy_migrate1", &.{0}, &.{0});
    const m1 = try f.tx(a, "legacy_migrate1");
    try testing.expectEqual(@as(u8, 0x24), m1.outputs[0].script[0]);
    try testing.expectEqualSlices(u8, &L1.txid, m1.outputs[0].script[1..33]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, m1.outputs[0].script[33..37]);
    try testing.expectEqual(@as(u64, 500_000), (try bsv21.judge(a, L1, m1, &.{0})).outputs[0].token.amount);

    // JSON 400,000 in -> JSON 100,000 + binary 300,000: mixed, value conserved across forms.
    try expectVerdict(a, f, L0, "legacy_mixed", &.{0}, &.{ 0, 1 });
    try testing.expectEqualSlices(bsv21.Form, &.{ .json, .binary }, try formsOf(a, f, L0, "legacy_mixed", &.{0}));
    // Mixed outputs still conserve value: one more unit of JSON and the whole transfer fails.
    const mixed = try f.tx(a, "legacy_mixed");
    const more = try withOutput(a, mixed, 0, jsonOp(a, "transfer", L0.txid, 0, 100_001));
    try testing.expect((try token.judge(a, L0, more, &.{0})).rejected != null);

    // Binary 350,000 in -> binary 200,000 + JSON 150,000: the JSON output is
    // refused (one-way migration) and its 150,000 is implicitly burned.
    const bj = try bsv21.judge(a, L0, try f.tx(a, "legacy_binary_json"), &.{0});
    try testing.expect(bj.ok);
    try testing.expectEqual(@as(usize, 1), bj.outputs.len);
    try testing.expectEqual(@as(u32, 0), bj.outputs[0].index);
    try testing.expectEqualSlices(u32, &.{1}, bj.refused);
    try testing.expectEqual(@as(u128, 150_000), bj.burned);
    try expectVerdict(a, f, L0, "legacy_binary_json", &.{0}, &.{0});
    // Refused even when the JSON output alone would be covered.
    const bj_tx = try f.tx(a, "legacy_binary_json");
    const only_json = try withOutput(a, bj_tx, 0, &p2pkh_lock);
    const oj = try bsv21.judge(a, L0, only_json, &.{0});
    try testing.expect(oj.ok and oj.outputs.len == 0);
    try testing.expectEqual(@as(u128, 350_000), oj.burned);
}

test "legacy: a JSON mint from an authority; an unfunded JSON transfer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);
    const LA = legacyId(f, "legacy_auth_deploy", 0);
    const L0 = legacyId(f, "legacy_deploy0", 0);

    try expectVerdict(a, f, LA, "legacy_auth_deploy", &.{}, &.{0});
    try expectVerdict(a, f, LA, "legacy_mint", &.{0}, &.{ 0, 1 });
    const jm = try bsv21.judge(a, LA, try f.tx(a, "legacy_mint"), &.{0});
    try testing.expect(jm.minted);
    try testing.expect(jm.outputs[0].token.mint);
    try testing.expectEqual(bsv21.Role.authority, jm.outputs[1].token.role);
    // Without the authority as a previous coin, neither output stands.
    try expectVerdict(a, f, LA, "legacy_mint", &.{}, &.{});

    // JSON 100,000 in -> 60,000 + 50,000: invalid, nothing admitted or retained.
    const u = try token.judge(a, L0, try f.tx(a, "legacy_unfunded"), &.{0});
    try testing.expectEqual(token.Verdict.Reason.inflation, u.rejected.?);
    try testing.expectEqual(@as(usize, 0), u.outputs_to_admit.len);
    try testing.expectEqual(@as(usize, 0), u.coins_to_retain.len);
}

test "program: a legacy topic tm_<txid>_<vout> through the topic contract" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const f = try Fixtures.init(a);
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = names.topicName(&buf, .{ .txid = w.beef.txidOf(f.raws.get("legacy_deploy1").?), .vout = 1, .kind = .legacy });
    try testing.expect(std.mem.endsWith(u8, tname, "_1"));

    const deploy_cid = try s.putBitcoin(a, .tx, f.raws.get("legacy_deploy1").?);
    _ = try s.putBitcoin(a, .tx, f.raws.get("legacy_fund").?);
    const migrate_cid = try s.putBitcoin(a, .tx, f.raws.get("legacy_migrate1").?);
    const rd = try topic.judge(a, s, program.identify, try callArgs(a, tname, deploy_cid, &.{}));
    try testing.expectEqualSlices(u32, &.{1}, try uintsOf(a, rd.get("outputsToAdmit").?));
    const rm = try topic.judge(a, s, program.identify, try callArgs(a, tname, migrate_cid, &.{0}));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rm.get("outputsToAdmit").?));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rm.get("coinsToRetain").?));
}

// --- the lookup service (ls_mandala): its hooks and its three queries ---

const ls = @import("src/mandala_lookup.zig");
const lookup = @import("lookup");

/// The lookup service over a store: hooks through the contract's `handle`, queries straight to `answer`.
const Ls = struct {
    a: std.mem.Allocator,
    s: w.store.Store,
    state: ?[]const u8 = null,
    service: []const u8 = ls.service_name,

    fn uints(a: std.mem.Allocator, xs: []const u32) ![]Value {
        const out = try a.alloc(Value, xs.len);
        for (xs, out) |x, *o| o.* = .{ .uint = x };
        return out;
    }

    fn hook(self: *Ls, func: []const u8, t: []const u8, rest: []const w.cbor.Entry) !void {
        const head = [_]w.cbor.Entry{
            .{ .key = "kind", .value = .{ .text = "lookup-hook" } },
            .{ .key = "app", .value = .{ .text = "mandala" } },
            .{ .key = "service", .value = .{ .text = self.service } },
            .{ .key = "topic", .value = .{ .text = t } },
        };
        const arg: Value = .{ .map = try std.mem.concat(self.a, w.cbor.Entry, &.{ &head, rest }) };
        const h = try lookup.handle(self.a, ls.spec, self.s, .regtest, self.state, null, func, arg);
        if (h.state) |sc| self.state = sc;
    }

    fn admitted(self: *Ls, t: []const u8, raw: []const u8, outs: []const u32) !void {
        const cid = try self.s.putBitcoin(self.a, .tx, raw);
        try self.hook("admitted", t, &.{
            .{ .key = "tx", .value = .{ .cid = cid } },
            .{ .key = "outputsToAdmit", .value = .{ .array = try uints(self.a, outs) } },
            .{ .key = "coinsRetained", .value = .{ .array = &.{} } },
        });
    }

    fn spent(self: *Ls, t: []const u8, src: []const u8, vout: u32, by: []const u8) !void {
        const sc = try self.s.putBitcoin(self.a, .tx, src);
        const bc = try self.s.putBitcoin(self.a, .tx, by);
        try self.hook("spent", t, &.{
            .{ .key = "outpoint", .value = .{ .map = try self.a.dupe(w.cbor.Entry, &.{
                .{ .key = "tx", .value = .{ .cid = sc } },
                .{ .key = "vout", .value = .{ .uint = vout } },
            }) } },
            .{ .key = "spendingTx", .value = .{ .cid = bc } },
        });
    }

    fn rejected(self: *Ls, t: []const u8, raw: []const u8) !void {
        const cid = try self.s.putBitcoin(self.a, .tx, raw);
        try self.hook("rejected", t, &.{.{ .key = "tx", .value = .{ .cid = cid } }});
    }

    /// The query's outputs as `<txid hex>:<vout>`.
    fn ask(self: *Ls, q: []const w.cbor.Entry) ![]const []const u8 {
        var svc = try lookup.Service.load(self.a, self.s, self.service, ls.spec.maps, self.state);
        var ch = try lookup.Chain.load(self.a, self.s, null, .regtest);
        const ans = try ls.answer(self.a, &svc, &ch, .{ .map = try self.a.dupe(w.cbor.Entry, q) });
        const outs = ans.output_list;
        const out = try self.a.alloc([]const u8, outs.len);
        for (outs, out) |o, *x| x.* = try std.fmt.allocPrint(self.a, "{s}:{d}", .{ &w.header.toHex(o.txid), o.vout });
        return out;
    }
};

fn opName(a: std.mem.Allocator, raw: []const u8, vout: u32) []const u8 {
    return std.fmt.allocPrint(a, "{s}:{d}", .{ &w.header.toHex(w.beef.txidOf(raw)), vout }) catch @panic("OOM");
}

fn expectOps(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try testing.expectEqualStrings(x, y);
}

fn text(t: []const u8) Value {
    return .{ .text = t };
}

test "lookup: {tokenId}, {authoritiesTokenId}, {txid, outputIndex} over the hooks; limit and skip; spent and rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const f = try Fixtures.init(a);
    var l: Ls = .{ .a = a, .s = ms.store() };
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = try a.dupe(u8, names.topicName(&buf, .{ .txid = f.id }));
    const deploy = f.raws.get("token_deploy").?;
    const pd = f.raws.get("pool_deploy").?;
    const id = try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(f.id)});

    // The deploy (10,000,000 at output 0): listed with the authorities, as ts-stack lists a deploy.
    try l.admitted(tname, deploy, &.{0});
    try expectOps(&.{opName(a, deploy, 0)}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));
    try expectOps(&.{}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));

    // A contract's deploy spends it: three value outputs, in outpoint order.
    try l.admitted(tname, pd, &.{ 0, 1, 2 });
    try l.spent(tname, deploy, 0, pd);
    try expectOps(&.{}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));
    const values = [_][]const u8{ opName(a, pd, 0), opName(a, pd, 1), opName(a, pd, 2) };
    try expectOps(&values, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    try expectOps(values[1..], try l.ask(&.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "skip", .value = .{ .uint = 1 } } }));
    try expectOps(values[1..2], try l.ask(&.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "limit", .value = .{ .uint = 1 } }, .{ .key = "skip", .value = .{ .uint = 1 } } }));
    try expectOps(&.{}, try l.ask(&.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "skip", .value = .{ .uint = 3 } } }));

    // One output by outpoint (txid in display order); the spent deploy is not answered.
    const pd_hex = try a.dupe(u8, &w.header.toHex(w.beef.txidOf(pd)));
    const dp_hex = try a.dupe(u8, &w.header.toHex(f.id));
    try expectOps(values[2..3], try l.ask(&.{ .{ .key = "txid", .value = text(pd_hex) }, .{ .key = "outputIndex", .value = .{ .uint = 2 } } }));
    try expectOps(&.{}, try l.ask(&.{ .{ .key = "txid", .value = text(dp_hex) }, .{ .key = "outputIndex", .value = .{ .uint = 0 } } }));
    try expectOps(&.{}, try l.ask(&.{ .{ .key = "txid", .value = text(pd_hex) }, .{ .key = "outputIndex", .value = .{ .uint = 9 } } }));

    // The first of authoritiesTokenId, tokenId answers.
    try expectOps(&.{}, try l.ask(&.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "authoritiesTokenId", .value = text(id) } }));

    // The contract's deploy rejected: its outputs gone, the deploy unspent again.
    try l.rejected(tname, pd);
    try expectOps(&.{}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    try expectOps(&.{opName(a, deploy, 0)}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));

    // A hook for another topic does nothing.
    try l.admitted("tm_demo", pd, &.{ 0, 1, 2 });
    try expectOps(&.{}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
}

test "lookup: a BRC-161 token's authority and mint, by its <txid>_<vout> id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const f = try Fixtures.init(a);
    var l: Ls = .{ .a = a, .s = ms.store() };
    const ad = f.raws.get("legacy_auth_deploy").?;
    const mint = f.raws.get("legacy_mint").?;
    const LA = legacyId(f, "legacy_auth_deploy", 0);
    var buf: [names.max_topic_len]u8 = undefined;
    const tname = try a.dupe(u8, names.topicName(&buf, .{ .txid = LA.txid, .vout = 0, .kind = .legacy }));
    const id = try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(LA.txid)});

    try l.admitted(tname, ad, &.{0});
    try expectOps(&.{opName(a, ad, 0)}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));
    // The mint (0) is a value output; the new authority (1) an authority output.
    try l.admitted(tname, mint, &.{ 0, 1 });
    try l.spent(tname, ad, 0, mint);
    try expectOps(&.{opName(a, mint, 1)}, try l.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));
    try expectOps(&.{opName(a, mint, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
}

test "lookup: queries out of shape are refused" {
    const id = "a5" ** 32 ++ "_0";
    const ok = [_]w.cbor.Entry{.{ .key = "tokenId", .value = text(id) }};
    try testing.expect((try ls.parseQuery(.{ .map = &ok })) == .values);
    const p = (try ls.parseQuery(.{ .map = &ok })).values;
    try testing.expectEqual(@as(u64, 100), p.limit);
    try testing.expectEqual(@as(u64, 0), p.skip);
    const legacy = [_]w.cbor.Entry{.{ .key = "authoritiesTokenId", .value = text("a5" ** 32 ++ "_7") }};
    try testing.expectEqual(@as(u32, 7), (try ls.parseQuery(.{ .map = &legacy })).authorities.id.vout);
    const bad = [_][]const w.cbor.Entry{
        &.{.{ .key = "tokenId", .value = text("A5" ** 32 ++ "_0") }}, // uppercase
        &.{.{ .key = "tokenId", .value = text("a5" ** 32 ++ "_") }}, // no vout after the separator
        &.{.{ .key = "tokenId", .value = text("a5" ** 32 ++ "-0") }}, // not a separator
        &.{.{ .key = "tokenId", .value = text("a5" ** 32 ++ "_00") }},
        &.{.{ .key = "tokenId", .value = .{ .uint = 1 } }},
        &.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "limit", .value = .{ .uint = 0 } } },
        &.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "limit", .value = .{ .uint = 101 } } },
        &.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "skip", .value = .{ .uint = 100_001 } } },
        &.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "skip", .value = .{ .nint = 0 } } },
        &.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "metadataTokenId", .value = text(id) } }, // not built
        &.{ .{ .key = "txid", .value = text("a5" ** 31) }, .{ .key = "outputIndex", .value = .{ .uint = 0 } } },
        &.{ .{ .key = "txid", .value = text("a5" ** 32) }, .{ .key = "outputIndex", .value = .{ .uint = 1 << 32 } } },
    };
    for (bad) |q| try testing.expectError(error.BadQuery, ls.parseQuery(.{ .map = q }));
    try testing.expectError(error.UnsupportedQuery, ls.parseQuery(.{ .map = &.{.{ .key = "txid", .value = text("a5" ** 32) }} }));
    try testing.expectError(error.UnsupportedQuery, ls.parseQuery(.{ .map = &.{} }));
    try testing.expectError(error.BadQuery, ls.parseQuery(.{ .text = "x" }));
}

test "program: metadata and documentation through the topic contract's describe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = "tm_" ++ "a5" ** 32;
    const arg: Value = .{ .map = &.{ .{ .key = "kind", .value = text("topic-describe") }, .{ .key = "topic", .value = text(t) } } };
    const m = try topic.describe(a, program, "metadata", arg);
    try testing.expectEqualStrings(t, m.getText("name").?);
    try testing.expect(std.mem.indexOf(u8, m.getText("shortDescription").?, "a5a5") != null);
    try testing.expectEqualStrings("0.4.0", m.getText("version").?);
    const d = try topic.describe(a, program, "documentation", arg);
    try testing.expect(std.mem.startsWith(u8, d.getText("documentation").?, "# Mandala token topic"));
    const ld = try lookup.describe(a, ls, "documentation", .{ .map = &.{ .{ .key = "kind", .value = text("lookup-describe") }, .{ .key = "service", .value = text("ls_mandala") } } });
    try testing.expect(std.mem.startsWith(u8, ld.getText("documentation").?, "# Mandala token lookup service"));
}

test "program: a BRC-161 token deployed at output 0 is tm_<txid>, its id <txid>_0 (its origin BSV-21); tm_<txid>_0 is never produced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const f = try Fixtures.init(a);
    const txid = w.beef.txidOf(f.raws.get("legacy_deploy0").?);
    const hex = w.header.toHex(txid);

    // Its id and its topic, from every direction.
    const t = "tm_" ++ hex;
    var buf: [names.max_topic_len]u8 = undefined;
    try testing.expectEqualStrings(t, names.topicName(&buf, .{ .txid = txid, .vout = 0, .kind = .legacy }));
    try testing.expectEqualStrings(t, names.topicName(&buf, names.tokenIdOfString(&hex ++ "_0").?));
    try testing.expect(names.tokenIdOf("tm_" ++ hex ++ "_0") == null);

    // The JSON deploy and a JSON transfer of it, judged under tm_<txid>.
    _ = try s.putBitcoin(a, .tx, f.raws.get("legacy_fund").?);
    const deploy_cid = try s.putBitcoin(a, .tx, f.raws.get("legacy_deploy0").?);
    const transfer_cid = try s.putBitcoin(a, .tx, f.raws.get("legacy_transfer").?);
    const rd = try topic.judge(a, s, program.identify, try callArgs(a, t, deploy_cid, &.{}));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rd.get("outputsToAdmit").?));
    const rt = try topic.judge(a, s, program.identify, try callArgs(a, t, transfer_cid, &.{0}));
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, try uintsOf(a, rt.get("outputsToAdmit").?));
    try testing.expectEqualSlices(u32, &.{0}, try uintsOf(a, rt.get("coinsToRetain").?));
}

// --- the discovery topic (tm_mandala) and its lookup (ls_mandala_deploys) ---

test "deploys: every valid deploy output of any token, nothing else, through the topic contract" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const s = ms.store();
    const f = try Fixtures.init(a);
    const t = names.deploys_topic;
    try testing.expectEqualStrings("tm_mandala", t);
    try testing.expect(token.tokenIdOf(t) == null); // no token's topic

    inline for (.{ "fund", "legacy_fund" }) |nm| _ = try s.putBitcoin(a, .tx, f.raws.get(nm).?);
    const Case = struct { name: []const u8, admit: []const u32 };
    for ([_]Case{
        .{ .name = "token_deploy", .admit = &.{0} }, // BRC-162 deploy at output 0
        .{ .name = "legacy_deploy0", .admit = &.{0} }, // BRC-161 deploy+mint at output 0
        .{ .name = "legacy_deploy1", .admit = &.{1} }, // BRC-161 deploy+mint at output 1
        .{ .name = "legacy_auth_deploy", .admit = &.{0} }, // BRC-161 deploy+auth
        .{ .name = "pool_deploy", .admit = &.{} }, // token value outputs, no deploy
        .{ .name = "swap_bsv_in", .admit = &.{} },
        .{ .name = "legacy_transfer", .admit = &.{} },
        .{ .name = "legacy_mint", .admit = &.{} },
        .{ .name = "fund", .admit = &.{} },
    }) |c| {
        const cid = try s.putBitcoin(a, .tx, f.raws.get(c.name).?);
        const r = try topic.judge(a, s, program.identify, try callArgs(a, t, cid, &.{}));
        try testing.expectEqualSlices(u32, c.admit, try uintsOf(a, r.get("outputsToAdmit").?));
    }

    // A binary deploy anywhere but output 0 is no deploy; a binary output with an id is not one either.
    const tx: bsv21.Tx = .{ .txid = id_a, .inputs = &.{}, .outputs = &.{
        .{ .script = &p2pkh_lock, .satoshis = 1 },
        .{ .script = tokenScript(a, null, 100, null), .satoshis = 1 },
        .{ .script = tokenScript(a, id_a, 5, null), .satoshis = 1 },
    } };
    try testing.expectEqual(@as(usize, 0), (try token.judgeDeploys(a, tx, &.{})).outputs_to_admit.len);
    try testing.expect((try token.deployOf(a, id_a, 1, tokenScript(a, null, 100, null))) == null);
    const d0 = (try token.deployOf(a, id_a, 0, tokenScript(a, null, 100, null))).?;
    try testing.expectEqual(@as(u32, 0), d0.vout);
    // A deploy carrying a payload (the metadata it was deployed with) is a deploy like any other.
    const cbor_map = [_]u8{ 0x04, 0xa1, 0x61, 0x78, 0x01 };
    try testing.expect((try token.deployOf(a, id_a, 0, tokenScript(a, null, 0, &cbor_map))) != null);

    // Its metadata and documentation are its own.
    const arg: Value = .{ .map = &.{ .{ .key = "kind", .value = text("topic-describe") }, .{ .key = "topic", .value = text(t) } } };
    try testing.expect(std.mem.startsWith(u8, (try topic.describe(a, program, "documentation", arg)).getText("documentation").?, "# Mandala token deploys"));
}

test "token id text by origin: a binary deploy is Mandala's (`<txid>`), a BRC-161 JSON deploy BSV-21's (`<txid>_<vout>`)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixtures.init(a);
    const Case = struct { name: []const u8, vout: u32, origin: names.Origin, suffix: []const u8 };
    for ([_]Case{
        .{ .name = "token_deploy", .vout = 0, .origin = .mandala, .suffix = "" },
        .{ .name = "legacy_deploy0", .vout = 0, .origin = .bsv21, .suffix = "_0" },
        .{ .name = "legacy_deploy1", .vout = 1, .origin = .bsv21, .suffix = "_1" },
        .{ .name = "legacy_auth_deploy", .vout = 0, .origin = .bsv21, .suffix = "_0" },
    }) |c| {
        const tx = try f.tx(a, c.name);
        const origin = (try token.originOf(a, tx.txid, c.vout, tx.outputs[c.vout].script)).?;
        try testing.expectEqual(c.origin, origin);
        var tb: [names.max_suffix_len]u8 = undefined;
        const want = try std.fmt.allocPrint(a, "{s}{s}", .{ &w.header.toHex(tx.txid), c.suffix });
        const id: names.TokenId = .{ .txid = tx.txid, .vout = c.vout, .kind = if (c.vout == 0) .native else .legacy };
        try testing.expectEqualStrings(want, names.tokenIdText(&tb, id, origin));
        // And the text names the same token back.
        const back = names.tokenIdOfString(want).?;
        try testing.expectEqualSlices(u8, &tx.txid, &back.txid);
        try testing.expectEqual(c.vout, back.vout);
    }
    // Not a deploy: no origin.
    const pool = try f.tx(a, "pool_deploy");
    try testing.expect((try token.originOf(a, pool.txid, 0, pool.outputs[0].script)) == null);
}

test "deploys lookup: {tokenId} → the deploy output; other topics ignored; kept once spent, dropped on rejection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = w.store.MemStore.init(testing.allocator);
    defer ms.deinit();
    const f = try Fixtures.init(a);
    var l: Ls = .{ .a = a, .s = ms.store(), .service = names.deploys_service };
    const t = names.deploys_topic;
    const deploy = f.raws.get("token_deploy").?;
    const d1 = f.raws.get("legacy_deploy1").?;
    const id = try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(f.id)});
    const id1 = try std.fmt.allocPrint(a, "{s}_1", .{&w.header.toHex(w.beef.txidOf(d1))});

    try expectOps(&.{}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    try l.admitted(t, deploy, &.{0});
    try l.admitted(t, d1, &.{1});
    try expectOps(&.{opName(a, deploy, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    try expectOps(&.{opName(a, d1, 1)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id1) }}));
    // Every form of the id: the Mandala token's bare `<txid>`, BRC-36 `<txid>.<vout>`.
    try expectOps(&.{opName(a, deploy, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id[0..64]) }}));
    try expectOps(&.{opName(a, deploy, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(try std.fmt.allocPrint(a, "{s}.0", .{id[0..64]})) }}));
    try expectOps(&.{opName(a, d1, 1)}, try l.ask(&.{.{ .key = "tokenId", .value = text(try std.fmt.allocPrint(a, "{s}.1", .{id1[0..64]})) }}));

    // A token topic's admission is not this service's; ls_mandala ignores the discovery topic.
    var buf: [names.max_topic_len]u8 = undefined;
    const ld0 = f.raws.get("legacy_deploy0").?;
    try l.admitted(names.topicName(&buf, .{ .txid = w.beef.txidOf(ld0) }), ld0, &.{0});
    try expectOps(&.{}, try l.ask(&.{.{ .key = "tokenId", .value = text(try std.fmt.allocPrint(a, "{s}_0", .{&w.header.toHex(w.beef.txidOf(ld0))})) }}));
    var lv: Ls = .{ .a = a, .s = ms.store() };
    try lv.admitted(t, deploy, &.{0});
    try expectOps(&.{}, try lv.ask(&.{.{ .key = "authoritiesTokenId", .value = text(id) }}));

    // Spent: still listed (a registry). Rejected: gone.
    try l.spent(t, deploy, 0, f.raws.get("pool_deploy").?);
    try expectOps(&.{opName(a, deploy, 0)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    try l.rejected(t, deploy);
    try expectOps(&.{}, try l.ask(&.{.{ .key = "tokenId", .value = text(id) }}));
    try expectOps(&.{opName(a, d1, 1)}, try l.ask(&.{.{ .key = "tokenId", .value = text(id1) }}));

    // Only {tokenId}.
    try testing.expectError(error.BadQuery, ls.parseDeploysQuery(.{ .map = &.{ .{ .key = "tokenId", .value = text(id) }, .{ .key = "limit", .value = .{ .uint = 1 } } } }));
    try testing.expectError(error.BadQuery, ls.parseDeploysQuery(.{ .map = &.{.{ .key = "tokenId", .value = text("x") }} }));
    try testing.expectError(error.UnsupportedQuery, ls.parseDeploysQuery(.{ .map = &.{} }));
    const ld = try lookup.describe(a, ls, "documentation", .{ .map = &.{ .{ .key = "kind", .value = text("lookup-describe") }, .{ .key = "service", .value = text(names.deploys_service) } } });
    try testing.expect(std.mem.startsWith(u8, ld.getText("documentation").?, "# Mandala token deploys lookup"));
}
