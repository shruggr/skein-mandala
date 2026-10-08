import { describe, expect, it } from "vitest";
import { Mandala } from "@1sat/templates";
import { LockingScript, PrivateKey, ProtoWallet, type CreateActionArgs, type WalletInterface } from "@bsv/sdk";
import { createContext } from "@1sat-actions/types.js";
import { deployMandala } from "@1sat-actions/mandala/deploy.js";
import { baseUnits, deployInput, namesOf, outpointOf, type DeployForm } from "../src/deploy/payload";

const txid = "ab".repeat(32);
const form = (o: Partial<DeployForm>): DeployForm => ({ symbol: "TOK", decimals: "2", supply: "fixed", amount: "10.5", icon: "", ...o });

describe("deploy payload", () => {
  it("whole units to base units", () => {
    expect(baseUnits("10.5", 2)).toBe(1050n);
    expect(baseUnits("7", 0)).toBe(7n);
    expect(baseUnits("1_000", 3)).toBe(1_000_000n);
    expect(() => baseUnits("1.234", 2)).toThrow(/2 decimal places/);
    expect(() => baseUnits("-1", 2)).toThrow();
  });
  it("a fixed supply", () => {
    expect(deployInput(form({}))).toEqual({ amount: "1050", symbol: "TOK", decimals: 2 });
  });
  it("an authority deploy: amount 0, the amount field ignored", () => {
    expect(deployInput(form({ supply: "authority", amount: "x" }))).toEqual({ amount: "0", symbol: "TOK", decimals: 2 });
  });
  it("an icon outpoint, either form, as txid_vout", () => {
    expect(deployInput(form({ icon: `${txid.toUpperCase()}.3` })).icon).toBe(`${txid}_3`);
    expect(() => outpointOf("abc_1")).toThrow(/icon/);
  });
  it("refusals name the field", () => {
    expect(() => deployInput(form({ symbol: " " }))).toThrow(/symbol/);
    expect(() => deployInput(form({ decimals: "19" }))).toThrow(/decimals/);
    expect(() => deployInput(form({ amount: "0" }))).toThrow(/amount/);
    expect(() => deployInput(form({ decimals: "0", amount: "18446744073709551616" }))).toThrow(/2\^64/);
  });
  it("the token's names: its id <txid>_0 (BRC-162 Token identification); its topic tm_<txid>_0", () => {
    expect(namesOf(txid.toUpperCase())).toEqual({ tokenId: `${txid}_0`, topic: `tm_${txid}_0` });
  });
  it("the SDK action builds the deploy from it: output 0, the payload as given", async () => {
    const proto = new ProtoWallet(PrivateKey.fromHex("01".repeat(32)));
    const created: CreateActionArgs[] = [];
    const wallet = {
      getPublicKey: (a: Parameters<ProtoWallet["getPublicKey"]>[0]) => proto.getPublicKey(a),
      createAction: async (a: CreateActionArgs) => { created.push(a); return {}; },
    } as unknown as WalletInterface;
    const r = await deployMandala.execute(createContext(wallet), deployInput(form({ icon: `${txid}_1` })));
    expect(r.error).toBe("deploy-no-tx"); // the fake wallet returns no transaction; the args are what count
    expect(created).toHaveLength(1);
    const out = created[0]!.outputs![0]!;
    const t = Mandala.decode(LockingScript.fromHex(out.lockingScript));
    expect(t?.role).toBe("deploy");
    expect(t?.amount).toBe(1050n);
    expect(t?.metadata).toEqual({ sym: "TOK", dec: 2, icon: `${txid}_1` });
    expect(created[0]!.options?.randomizeOutputs).toBe(false);
    expect(created[0]!.options?.noSend).toBeUndefined();
  });
});
