import { describe, expect, it } from "vitest";
import { DISCOVERY, answerOf, deployTxidOf, deregister, discovery, register, tokenTopicOf, topicsOf } from "../src/tokens/list";

const txid = "cd".repeat(32);

describe("the owner's calls: the engine's register / deregister", () => {
  it("register a token's topic, judged by mandala-topic, seeded with its deploy (skein-overlay 0.7.8)", () => {
    expect(register(` tm_${txid} `)).toEqual({ fn: "register", args: { topic: `tm_${txid}`, program: "mandala-topic", seed: [txid] } });
    expect(register(`tm_${txid}_2`)).toEqual({ fn: "register", args: { topic: `tm_${txid}_2`, program: "mandala-topic", seed: [txid] } });
    expect(deployTxidOf(`tm_${txid}_2`)).toBe(txid);
  });
  it("a token id is not a topic; tm_<txid>_0 is no topic", () => {
    for (const bad of [txid, `${txid}_0`, `${txid}.0`, `tm_${txid}_0`, `tm_${txid}_01`, `tm_${txid.toUpperCase()}`, `tm_${txid}_4294967296`, DISCOVERY]) {
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
  it("a register's seeding: seeded / missing (untaken when present)", () => {
    expect(answerOf({ kind: "overlay-result", op: "register", topic: `tm_${txid}`, active: true, changed: true, seeded: [txid], missing: [] }))
      .toEqual({ ok: true, topic: `tm_${txid}`, active: true, seeding: { seeded: [txid], missing: [], untaken: [] } });
    expect(answerOf({ kind: "overlay-result", op: "register", topic: `tm_${txid}`, active: true, changed: false, seeded: [], missing: [txid] }))
      .toEqual({ ok: true, topic: `tm_${txid}`, active: true, seeding: { seeded: [], missing: [txid], untaken: [] } });
    expect(answerOf({ kind: "overlay-result", op: "register", topic: `tm_${txid}`, active: true, seeded: [], missing: [], untaken: [txid] }).ok && "seeding")
      .toBe("seeding");
  });
});
