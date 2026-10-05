import { describe, expect, it } from "vitest";
import { DISCOVERY, activate, answerOf, deactivate, discovery, tokenIdOf, tokenOfTopic, topicOfToken, topicsOf } from "../src/tokens/list";

const txid = "cd".repeat(32);

describe("the owner's calls", () => {
  it("activate by token id, normalized", () => {
    expect(activate(`${txid.toUpperCase()}.0`)).toEqual({ fn: "mandala.tokens.activate", args: { tokenId: `${txid}_0` } });
    expect(() => activate("nope")).toThrow(/token id/);
    expect(() => tokenIdOf(`${txid}_01`)).toThrow();
  });
  it("deactivate by topic", () => {
    expect(deactivate(`tm_${txid}`)).toEqual({ fn: "mandala.tokens.deactivate", args: { topic: `tm_${txid}` } });
  });
  it("the discovery switch", () => {
    expect(discovery(true)).toEqual({ fn: "mandala.tokens.activate", args: { topic: DISCOVERY } });
    expect(discovery(false)).toEqual({ fn: "mandala.tokens.deactivate", args: { topic: DISCOVERY } });
  });
  it("topics and token ids", () => {
    expect(topicOfToken(`${txid}_0`)).toBe(`tm_${txid}`);
    expect(topicOfToken(`${txid}_2`)).toBe(`tm_${txid}_2`);
    expect(tokenOfTopic(`tm_${txid}`)).toBe(`${txid}_0`);
    expect(tokenOfTopic(`tm_${txid}_2`)).toBe(`${txid}_2`);
    expect(tokenOfTopic(`tm_${txid}_0`)).toBeUndefined();
    expect(tokenOfTopic(DISCOVERY)).toBeUndefined();
  });
});

describe("the list and the answers", () => {
  it("the list record", () => {
    expect(topicsOf(undefined)).toEqual([]);
    expect(topicsOf({ kind: "mandala-tokens", topics: [DISCOVERY, `tm_${txid}`] })).toEqual([DISCOVERY, `tm_${txid}`]);
    expect(() => topicsOf({ kind: "app" })).toThrow(/token list/);
  });
  it("an answer", () => {
    expect(answerOf({ fn: "mandala.tokens.activate", result: { tokenId: `${txid}_0`, topic: `tm_${txid}`, active: true } }))
      .toEqual({ ok: true, tokenId: `${txid}_0`, topic: `tm_${txid}`, active: true });
    expect(answerOf({ fn: "x", error: { code: "bad-request", message: "tokenId: want …" } })).toEqual({ ok: false, message: "bad-request: tokenId: want …" });
    expect(answerOf({}).ok).toBe(false);
  });
});
