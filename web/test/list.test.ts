import { describe, expect, it } from "vitest";
import { DISCOVERY, answerOf, deregister, discovery, register, tokenTopicOf, topicsOf } from "../src/tokens/list";

const txid = "cd".repeat(32);

describe("the owner's calls: the engine's register / deregister", () => {
  it("register a token's topic, judged by mandala-topic", () => {
    expect(register(` tm_${txid} `)).toEqual({ fn: "register", args: { topic: `tm_${txid}`, program: "mandala-topic" } });
    expect(register(`tm_${txid}_2`)).toEqual({ fn: "register", args: { topic: `tm_${txid}_2`, program: "mandala-topic" } });
  });
  it("a token id is not a topic; tm_<txid>_0 is no topic", () => {
    for (const bad of [txid, `${txid}_0`, `${txid}.0`, `tm_${txid}_0`, `tm_${txid}_01`, `tm_${txid.toUpperCase()}`, `tm_${txid}_4294967296`, "tm_mandala", DISCOVERY]) {
      expect(() => tokenTopicOf(bad)).toThrow(/topic/);
    }
    expect(tokenTopicOf(`tm_${txid}_4294967295`)).toBe(`tm_${txid}_4294967295`);
  });
  it("deregister by topic", () => {
    expect(deregister(`tm_${txid}`)).toEqual({ fn: "deregister", args: { topic: `tm_${txid}` } });
  });
  it("the discovery switch", () => {
    expect(discovery(true)).toEqual({ fn: "register", args: { topic: DISCOVERY, program: "mandala-topic" } });
    expect(discovery(false)).toEqual({ fn: "deregister", args: { topic: DISCOVERY } });
  });
});

describe("the registered set and the answers", () => {
  it("the set's record: mandala-topic's topics", () => {
    expect(topicsOf(undefined)).toEqual([]);
    const rec = { kind: "overlay-topics", topics: [{ topic: "tm_other", program: "other-topic" }, { topic: DISCOVERY, program: "mandala-topic" }, { topic: `tm_${txid}`, program: "mandala-topic" }] };
    expect(topicsOf(rec)).toEqual([DISCOVERY, `tm_${txid}`]);
    expect(() => topicsOf({ kind: "mandala-tokens", topics: [`tm_${txid}`] })).toThrow(/registered topics/);
    expect(() => topicsOf({ kind: "overlay-topics", topics: [`tm_${txid}`] })).toThrow(/registered topics/);
  });
  it("an answer: the step's result record", () => {
    expect(answerOf({ kind: "overlay-result", op: "register", topic: `tm_${txid}`, active: true, changed: true })).toEqual({ ok: true, topic: `tm_${txid}`, active: true });
    expect(answerOf({ kind: "overlay-result", op: "register", error: "registered with another program; deregister it first" })).toEqual({ ok: false, message: "registered with another program; deregister it first" });
    expect(answerOf({}).ok).toBe(false);
  });
});
