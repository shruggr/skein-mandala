import { describe, expect, it } from "vitest";
import { idParts, shortId } from "../src/Id";

const txid = "ab".repeat(30) + "cdef";

describe("ids (David 2026-10-08: expandable, copyable)", () => {
  it("shortens each txid in a value, keeping its prefix and vout", () => {
    expect(shortId(txid)).toBe("abababab…ababcdef");
    expect(shortId(`tm_mandala_${txid}_2`)).toBe("tm_mandala_abababab…ababcdef_2");
    expect(shortId(`${txid}.1`)).toBe("abababab…ababcdef.1");
    expect(shortId(`${txid}_0`)).toBe("abababab…ababcdef_0"); // a token id
    expect(shortId("tm_mandala")).toBe("tm_mandala");
  });
  it("finds the ids in a status line: txids, topics, outpoints, token ids", () => {
    const line = `tm_mandala_${txid}_0: registered (seeded: ${txid}.0, ${txid}_3, ${txid}_0; missing: none).`;
    expect(idParts(line)).toEqual([
      { id: true, text: `tm_mandala_${txid}_0` },
      { id: false, text: ": registered (seeded: " },
      { id: true, text: `${txid}.0` },
      { id: false, text: ", " },
      { id: true, text: `${txid}_3` },
      { id: false, text: ", " },
      { id: true, text: `${txid}_0` },
      { id: false, text: "; missing: none)." },
    ]);
  });
  it("a token's lookup ls_mandala_<assetId> is one id (BRC-207)", () => {
    expect(idParts(`ls_mandala_${txid}_0: registered`)).toEqual([{ id: true, text: `ls_mandala_${txid}_0` }, { id: false, text: ": registered" }]);
  });
  it("leaves other hex alone (a 66-character key) and text with no id", () => {
    expect(idParts(`key 02${txid}`)).toEqual([{ id: false, text: `key 02${txid}` }]);
    expect(idParts("taken by no topic")).toEqual([{ id: false, text: "taken by no topic" }]);
  });
});
