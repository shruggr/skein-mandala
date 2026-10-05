//! mandala-topic: the Mandala (BRC-162) topic manager, one topic per token
//! (shruggr/skein#120), and the app's active token list (`mandala.tokens/1`).
//!
//! **The topic.** `tm_<txid>` for a token deployed at output 0 (BRC-162, or
//! BRC-161 there: the same token), `tm_<txid>_<vout>` for a BRC-161 token
//! deployed at a non-zero output (name.zig). `identify` (the
//! skein-overlay topic contract, `topic.Call`) admits every output of the
//! topic's token that the BSV-21 rules allow and retains the token coins the
//! transaction spends (token.zig, bsv21.zig): the protocol only, nothing
//! about governance. `metadata` and `documentation` answer the overlay's
//! listing and documentation routes (skein-overlay#2).
//!
//! **The token list.** A message in the app's box from the owner, `{fn:
//! "mandala.tokens.activate" | "mandala.tokens.deactivate", args: {topic}}`
//! (skein docs/APPS.md §4; the SDK's `app` helper), writes the list under
//! `<app>/mandala` and emits `subscribe` / `unsubscribe` for the topic's
//! three GossipSub topics (tokens.zig). The same functions are an in-VM call
//! from another program of the same app, in its step (an app whose box is
//! its own program's hands the message on).
const std = @import("std");
const c = @import("chain");
const topic = @import("topic");
const vm = @import("overlay_sk");
const cbor = @import("cbor");
const sk = @import("sk");
const app = @import("app");
const mandala = @import("mandala");
const tokens = @import("tokens.zig");

const token = mandala.token;
const bsv21 = mandala.bsv21;

const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

/// The transaction a topic call judges, with the outputs its inputs spend
/// where the call's store carries them.
pub fn txOf(a: Allocator, call: topic.Call) !bsv21.Tx {
    const ins = try a.alloc(bsv21.Input, call.tx.inputs.len);
    for (call.tx.inputs, ins, 0..) |in, *x, i| {
        x.* = .{ .txid = in.previous_outpoint.txid.bytes, .vout = in.previous_outpoint.index, .unlocking_script = in.unlocking_script.bytes };
        if (call.sourceOutput(i)) |o| x.source = .{ .script = o.locking_script.bytes, .satoshis = @intCast(o.satoshis) };
    }
    const outs = try a.alloc(bsv21.Output, call.tx.outputs.len);
    for (call.tx.outputs, outs) |o, *x| x.* = .{ .script = o.locking_script.bytes, .satoshis = @intCast(o.satoshis) };
    return .{ .txid = call.txid, .inputs = ins, .outputs = outs };
}

pub fn identify(a: Allocator, call: topic.Call) anyerror!topic.Instructions {
    if (eql(u8, call.topic, mandala.name.deploys_topic)) {
        const d = try token.judgeDeploys(a, try txOf(a, call), call.previous_coins);
        return .{ .outputs_to_admit = d.outputs_to_admit, .coins_to_retain = d.coins_to_retain };
    }
    const id = token.tokenIdOf(call.topic) orelse return error.UnknownTopic;
    const v = try token.judge(a, id, try txOf(a, call), call.previous_coins);
    return .{ .outputs_to_admit = v.outputs_to_admit, .coins_to_retain = v.coins_to_retain };
}

pub fn metadata(a: Allocator, t: []const u8) anyerror!topic.Metadata {
    if (eql(u8, t, mandala.name.deploys_topic)) return .{
        .short_description = "Mandala token deploys (BRC-162, BRC-161): every token's deploy output, with the metadata it was deployed with.",
        .version = version,
        .information_url = "https://github.com/shruggr/skein-mandala",
    };
    const id = token.tokenIdOf(t) orelse return .{ .short_description = "Not a Mandala token topic." };
    var r = id.txid;
    std.mem.reverse(u8, &r);
    return .{
        // The topic does not record the token's origin, so a token at output 0 is named by its deploy.
        .short_description = if (id.vout == 0)
            try std.fmt.allocPrint(a, "Mandala token deployed at output 0 of {s} (BRC-162): its outputs as the token rules allow.", .{&std.fmt.bytesToHex(r, .lower)})
        else
            try std.fmt.allocPrint(a, "Mandala token {s}_{d} (BRC-162, deployed under BRC-161): its outputs as the token rules allow.", .{ &std.fmt.bytesToHex(r, .lower), id.vout }),
        .version = version,
        .information_url = "https://github.com/shruggr/skein-mandala",
    };
}

pub const version = "0.3.1";

pub fn documentation(_: Allocator, t: []const u8) anyerror![]const u8 {
    if (eql(u8, t, mandala.name.deploys_topic)) return
    \\# Mandala token deploys (tm_mandala_deploys)
    \\
    \\The discovery topic: every token's deploy output, of every Mandala token. A
    \\registry of what tokens exist and the metadata each was deployed with (the deploy
    \\payload: decimals, symbol, icon, ...).
    \\
    \\It admits an output that is a valid deploy and nothing else:
    \\
    \\- a BRC-162 deploy (id `OP_0`) at output 0: the token `<txid>`;
    \\- a BRC-161 `deploy+mint` or `deploy+auth` inscription at any output: the token
    \\  `<txid>_<vout>` (`<txid>_0` at output 0).
    \\
    \\No other rule and no governance. It is served while activated
    \\(`mandala.tokens.activate {topic: "tm_mandala_deploys"}`).
    \\
    ;
    return
    \\# Mandala token topic (tm_<txid>)
    \\
    \\One topic per Mandala token (BRC-162): `tm_<txid>` for a token deployed at output 0,
    \\under BRC-162 (its id `<txid>`) or BRC-161 (its id `<txid>_0`); `tm_<txid>_<vout>` for
    \\a token deployed under BRC-161 (JSON) at output `<vout>`, its id `<txid>_<vout>`, with
    \\its one-way migration to the binary form. `<txid>` is the deploy txid, 64 lowercase
    \\hex characters in display order.
    \\
    \\It admits every output of the token that the BSV-21 rules allow, and nothing else:
    \\
    \\- the deploy, at the token's deploy outpoint;
    \\- authority outputs (amount 0) and mints, only when the transaction spends an
    \\  authority of the token;
    \\- transfers, when the token's inputs cover them; a shortfall admits none of them
    \\  (an excess is an implicit burn);
    \\- once a transaction spends a binary output of a BRC-161 token, its JSON outputs
    \\  of that token are not admitted.
    \\
    \\It retains the token coins the transaction spends. A transaction that breaks the
    \\rules admits and retains nothing. There is no ownership, authority-chain or
    \\control check: the protocol only.
    \\
    \\The overlay serves a token's topic once it is activated
    \\(`mandala.tokens.activate {topic: "tm_<txid>"}`). The discovery topic `tm_mandala_deploys`
    \\holds every token's deploy output.
    \\
    ;
}

const fns = [_]app.Function{
    .{ .name = "mandala.tokens.activate", .run = activate },
    .{ .name = "mandala.tokens.deactivate", .run = deactivate },
};

pub fn main() u8 {
    return sk.main("mandala-topic", run);
}

fn run(a: Allocator) !void {
    const bytes = try sk.result(a, sk.raw.input, .{});
    const in = try cbor.decode(a, bytes);
    const func = Value.str(in.get("fn")) orelse "";
    if (eql(u8, Value.str(in.get("kind")) orelse "", "call") and (eql(u8, func, "identify") or eql(u8, func, "metadata") or eql(u8, func, "documentation"))) {
        // The topic contract, on the chain library's records (skein-overlay `topic`).
        const arg = try vm.callArg(a, try c.cbor.decode(a, bytes));
        if (eql(u8, func, "identify")) return vm.answer(a, try topic.judge(a, vm.store(), identify, arg));
        return vm.answer(a, try topic.describe(a, @This(), func, arg));
    }
    return app.serve(a, in, try appOf(a, in), &fns, null);
}

/// The app this program was installed in: its program record's `app` (a step: the thread's
/// `program`; an in-VM call from a step, another program of the same app: that step's thread's;
/// a route's call: the matched row's).
fn appOf(a: Allocator, in: Value) ![]const u8 {
    const thread = Value.cidOf(in.get("thread")) orelse if (in.get("step")) |st| Value.cidOf(st.get("thread")) else null;
    const prog = if (thread) |t|
        Value.cidOf((try sk.get(a, t)).get("program"))
    else if (in.get("arg")) |arg| blk: {
        const x = cbor.decode(a, Value.bytesOf(arg) orelse "") catch break :blk null;
        break :blk Value.cidOf((x.get("match") orelse break :blk null).get("program"));
    } else null;
    const p = prog orelse return sk.report("mandala-topic: no program record (a step or a route's call)");
    return Value.str((try sk.get(a, p)).get("app")) orelse sk.report("mandala-topic: its program record names no app (not installed)");
}

/// An event (#119: `{event, …fields}`, recorded with the app's name; the host acts on it after the commit).
fn emitEvent(a: Allocator, ev: Value) !void {
    const b = try cbor.encode(a, ev);
    _ = try sk.result(a, sk.raw.emit, .{ b.ptr, @as(u32, @intCast(b.len)) });
}

const Change = enum { activate, deactivate };

fn change(cl: *app.Call, how: Change) !Value {
    const a = cl.a;
    const t = Value.str(cl.args.get("topic")) orelse return sk.report("want topic (tm_<txid>, tm_<txid>_<vout> or tm_mandala_deploys)");
    if (!tokens.isTopic(t)) return sk.report("topic: want tm_<txid>, tm_<txid>_<vout> or tm_mandala_deploys");
    const head = try tokens.headName(a, cl.app);
    const rec: ?Value = if (try cl.head(head)) |r| try cl.get(r) else null;
    const list = try tokens.topicsOf(a, rec);
    const next = switch (how) {
        .activate => try tokens.with(a, list, t),
        .deactivate => try tokens.without(a, list, t),
    };
    if (next) |l| {
        try cl.advance(head, try cl.put(try tokens.recordOf(a, l)));
        for (try tokens.events(a, if (how == .activate) "subscribe" else "unsubscribe", t)) |ev| try emitEvent(a, ev);
    }
    return tokens.answerOf(a, t, how == .activate);
}

fn activate(cl: *app.Call) !Value {
    return change(cl, .activate);
}

fn deactivate(cl: *app.Call) !Value {
    return change(cl, .deactivate);
}
