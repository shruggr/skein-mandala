/**
 * The deploy form → @1sat/actions' `deployMandala` input (BRC-162: symbol,
 * decimals, icon, a fixed supply or an authority deploy), and the names the
 * deploy gives the token. Pure; the page hands the input to the SDK action.
 */
import type { DeployMandalaInput } from "@1sat-actions/mandala/deploy.js";

/** BRC-162 amounts are u64. */
export const MAX_AMOUNT = 0xffffffffffffffffn;

export interface DeployForm {
  symbol: string;
  /** Text as typed: an integer 0-18. */
  decimals: string;
  supply: "fixed" | "authority";
  /** Text as typed, in whole units (`decimals` places allowed); fixed supply only. */
  amount: string;
  /** Text as typed: an outpoint `txid.vout` (or `txid_vout`), or empty. */
  icon: string;
}

/** Whole units with up to `decimals` places → base units. */
export function baseUnits(text: string, decimals: number): bigint {
  const t = text.trim().replace(/_/g, "");
  const m = /^(\d+)(?:\.(\d*))?$/.exec(t);
  if (!m) throw new Error("amount: a number, e.g. 1000 or 12.5");
  const frac = m[2] ?? "";
  if (frac.length > decimals) throw new Error(`amount: at most ${decimals} decimal places`);
  return BigInt(m[1]! + frac.padEnd(decimals, "0"));
}

/**
 * An outpoint, typed `txid.vout` or `txid_vout`, as @1sat/templates'
 * `Mandala` deploy payload takes it: `txid_vout`, txid lowercase (its
 * `outpointBytes` parses the underscore form only, 0.0.43). The pages show
 * outpoints as `txid.vout` (David, 2026-10-08).
 */
export function outpointOf(text: string): string {
  const m = /^([0-9a-fA-F]{64})[_.](0|[1-9]\d*)$/.exec(text.trim());
  if (!m || Number(m[2]) > 0xffffffff) throw new Error("icon: an outpoint, <txid>.<vout>");
  return `${m[1]!.toLowerCase()}_${m[2]}`;
}

/** The SDK action's input. Throws with the field's name on a bad value. */
export function deployInput(f: DeployForm): DeployMandalaInput {
  const symbol = f.symbol.trim();
  if (!symbol) throw new Error("symbol: required");
  const dec = f.decimals.trim() === "" ? 0 : Number(f.decimals.trim());
  if (!Number.isInteger(dec) || dec < 0 || dec > 18) throw new Error("decimals: an integer 0-18");
  let amount = 0n;
  if (f.supply === "fixed") {
    amount = baseUnits(f.amount, dec);
    if (amount <= 0n) throw new Error("amount: more than 0 for a fixed supply");
    if (amount > MAX_AMOUNT) throw new Error("amount: at most 2^64-1 base units");
  }
  const input: DeployMandalaInput = { amount: amount.toString(), symbol, decimals: dec };
  if (f.icon.trim()) input.icon = outpointOf(f.icon);
  return input;
}

/**
 * The names a Mandala deploy gives the token: its id `<txid>_0` (every token
 * is `<txid>_<vout>`, `_0` included; the bare txid is the wire form only:
 * BRC-162 "Token identification", David 2026-10-07), and the overlay topic
 * root activates, `tm_<tokenId>`: `tm_<txid>_0` (David 2026-10-08).
 */
export function namesOf(txid: string): { tokenId: string; topic: string } {
  const t = txid.toLowerCase();
  return { tokenId: `${t}_0`, topic: `tm_${t}_0` };
}
