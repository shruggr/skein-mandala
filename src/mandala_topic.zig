//! mandala-topic: the Mandala (BRC-162) topic manager, one topic per token
//! (shruggr/skein#120).
//!
//! **The topic.** `tm_<txid>` for a token deployed at output 0 (BRC-162, or
//! BRC-161 there: the same token), `tm_<txid>_<vout>` for a BRC-161 token
//! deployed at a non-zero output (name.zig), and the discovery topic
//! `tm_mandala`. `identify` (the skein-overlay topic contract,
//! `topic.Call`) admits every output of the topic's token that the BSV-21
//! rules allow and retains the token coins the transaction spends (token.zig,
//! bsv21.zig): the protocol only, nothing about governance. `metadata` and
//! `documentation` answer the overlay's listing and documentation routes
//! (skein-overlay#2).
//!
//! The topics served are the engine's: the owner registers each with the
//! overlay engine, `register {topic, program: "mandala-topic"}`, and drops it
//! with `deregister {topic}` (skein-overlay 0.6.0 "Register a topic").
const std = @import("std");
const c = @import("chain");
const topic = @import("topic");
const mandala = @import("mandala");

const token = mandala.token;
const bsv21 = mandala.bsv21;

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
        // The token by its id string, `<txid>_<vout>` (`_0` included; BRC-162 "Token identification").
        .short_description = if (id.vout == 0)
            try std.fmt.allocPrint(a, "Mandala token {s}_0 (BRC-162): its outputs as the token rules allow.", .{&std.fmt.bytesToHex(r, .lower)})
        else
            try std.fmt.allocPrint(a, "Mandala token {s}_{d} (BRC-162, deployed under BRC-161): its outputs as the token rules allow.", .{ &std.fmt.bytesToHex(r, .lower), id.vout }),
        .version = version,
        .information_url = "https://github.com/shruggr/skein-mandala",
    };
}

pub const version = "0.4.0";

pub fn documentation(_: Allocator, t: []const u8) anyerror![]const u8 {
    if (eql(u8, t, mandala.name.deploys_topic)) return
    \\# Mandala token deploys (tm_mandala)
    \\
    \\The discovery topic: every token's deploy output, of every Mandala token. A
    \\registry of what tokens exist and the metadata each was deployed with (the deploy
    \\payload: decimals, symbol, icon, ...).
    \\
    \\It admits an output that is a valid deploy and nothing else:
    \\
    \\- a BRC-162 deploy (id `OP_0`) at output 0: the token `<txid>_0`;
    \\- a BRC-161 `deploy+mint` or `deploy+auth` inscription at any output: the token
    \\  `<txid>_<vout>`.
    \\
    \\No other rule and no governance. It is served while registered with the overlay
    \\engine (`register {topic: "tm_mandala", program: "mandala-topic"}`).
    \\
    ;
    return
    \\# Mandala token topic (tm_<txid>)
    \\
    \\One topic per Mandala token (BRC-162): `tm_<txid>` for a token deployed at output 0,
    \\under BRC-162 or BRC-161 (its id `<txid>_0`); `tm_<txid>_<vout>` for a token deployed
    \\under BRC-161 (JSON) at output `<vout>`, its id `<txid>_<vout>`, with its one-way
    \\migration to the binary form. `<txid>` is the deploy txid, 64 lowercase hex characters
    \\in display order. A token id is `<txid>_<vout>` for every token, `_0` included (BRC-162
    \\"Token identification"); the bare 32-byte txid is its wire form only.
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
    \\The overlay serves a token's topic once it is registered with the overlay engine
    \\(`register {topic: "tm_<txid>", program: "mandala-topic"}`). The discovery topic `tm_mandala`
    \\holds every token's deploy output.
    \\
    ;
}

pub fn main() u8 {
    return topic.main(identify);
}
