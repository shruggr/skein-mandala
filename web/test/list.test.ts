import { describe, expect, it } from "vitest";
import { DISCOVERY, activate, answerOf, deactivate, discovery, tokenTopicOf, topicsOf } from "../src/tokens/list";

const txid = "cd".repeat(32);

describe("the owner's calls: {topic} only", () => {
  it("activate a token's topic", () => {
    expect(activate(` tm_${txid} `)).toEqual({ fn: "mandala.tokens.activate", args: { topic: `tm_${txid}` } });
    expect(activate(`tm_${txid}_2`)).toEqual({ fn: "mandala.tokens.activate", args: { topic: `tm_${txid}_2` } });
  });
  it("a token id is not a topic; tm_<txid>_0 is no topic", () => {
    for (const bad of [txid, `${txid}_0`, `${txid}.0`, `tm_${txid}_0`, `tm_${txid}_01`, `tm_${txid.toUpperCase()}`, `tm_${txid}_4294967296`, "tm_mandala", DISCOVERY]) {
      expect(() => tokenTopicOf(bad)).toThrow(/topic/);
    }
    expect(tokenTopicOf(`tm_${txid}_4294967295`)).toBe(`tm_${txid}_4294967295`);
  });
  it("deactivate by topic", () => {
    expect(deactivate(`tm_${txid}`)).toEqual({ fn: "mandala.tokens.deactivate", args: { topic: `tm_${txid}` } });
  });
  it("the discovery switch", () => {
    expect(discovery(true)).toEqual({ fn: "mandala.tokens.activate", args: { topic: DISCOVERY } });
    expect(discovery(false)).toEqual({ fn: "mandala.tokens.deactivate", args: { topic: DISCOVERY } });
  });
});

describe("the list and the answers", () => {
  it("the list record", () => {
    expect(topicsOf(undefined)).toEqual([]);
    expect(topicsOf({ kind: "mandala-tokens", topics: [DISCOVERY, `tm_${txid}`] })).toEqual([DISCOVERY, `tm_${txid}`]);
    expect(() => topicsOf({ kind: "app" })).toThrow(/token list/);
  });
  it("an answer: {topic, active}", () => {
    expect(answerOf({ fn: "mandala.tokens.activate", result: { topic: `tm_${txid}`, active: true } })).toEqual({ ok: true, topic: `tm_${txid}`, active: true });
    expect(answerOf({ fn: "x", error: { code: "bad-request", message: "topic: want …" } })).toEqual({ ok: false, message: "bad-request: topic: want …" });
    expect(answerOf({}).ok).toBe(false);
  });
});
