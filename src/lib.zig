//! The Mandala (BRC-162) token library: the output parsers and the token
//! rules, the module `mandala` of the skein-mandala package. Only `std`.
//!
//!   brc162   the BRC-162 binary output parser: `<id | OP_0> <amount | OP_0> OP_2DROP [<payload> OP_DROP] <lock>`
//!   brc161   the BRC-161 (BSV-21 JSON, legacy) inscription parser
//!   bsv21    the BSV-21 rules for one token over one parsed transaction (both forms)
//!   name     topic names: `tm_<tokenId>`, `tm_<txid>_0` at output 0 (BRC-162), `tm_<txid>_<vout>` (BRC-161 at that output)
//!   token    the topic's verdict: the rules, nothing else
//!
//! The topic manager (src/mandala_topic.zig) and the lookup service
//! (src/mandala_lookup.zig) are built on it; an application's own programs
//! (an AMM's lookup and validator) depend on it by URL+hash.
pub const brc162 = @import("brc162.zig");
pub const brc161 = @import("brc161.zig");
pub const bsv21 = @import("bsv21.zig");
pub const name = @import("name.zig");
pub const token = @import("token.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
