import { describe, expect, it } from "vitest";
import { DISCOVERY, answerOf, deployTxidOf, deregister, discovery, register, roleSwitch, rolesAnswerOf, rolesOf, tokenTopicOf, topicsOf } from "../src/tokens/list";

const txid = "cd".repeat(32);

describe("root's calls: the engine's register / deregister", () => {
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

describe("root's switch: market and validator (skein-overlay 0.9.2)", () => {
  it("on with its ms, or off", () => {
    expect(roleSwitch("market", true)).toEqual({ fn: "market", args: { window: 40_000 } });
    expect(roleSwitch("market", true, 60_000)).toEqual({ fn: "market", args: { window: 60_000 } });
    expect(roleSwitch("validator", true)).toEqual({ fn: "validator", args: { every: 30_000 } });
    expect(roleSwitch("market", false)).toEqual({ fn: "market", args: { off: true } });
    expect(roleSwitch("validator", false)).toEqual({ fn: "validator", args: { off: true } });
  });
  it("the roles in effect: the switch kept beside the set, over the manifest's config.overlay", () => {
    const app = { kind: "app", config: { overlay: { market: { window: 40_000 } } } };
    expect(rolesOf(undefined, undefined)).toEqual({});
    expect(rolesOf(undefined, app)).toEqual({ market: { window: 40_000 } });
    expect(rolesOf({ kind: "overlay-topics", topics: [] }, app)).toEqual({ market: { window: 40_000 } });
    expect(rolesOf({ kind: "overlay-topics", topics: [], market: { off: true } }, app)).toEqual({});
    expect(rolesOf({ kind: "overlay-topics", topics: [], market: { window: 60_000 }, validator: { every: 30_000 } }, app)).toEqual({ market: { window: 60_000 }, validator: { every: 30_000 } });
    expect(topicsOf({ kind: "overlay-topics", topics: [{ topic: `tm_${txid}`, program: "mandala-topic" }], market: { off: true } })).toEqual([`tm_${txid}`]);
  });
  it("a switch's answer: the roles in effect, or the refusal", () => {
    expect(rolesAnswerOf({ kind: "overlay-result", op: "market", market: { window: 40_000 }, changed: true, events: 2 })).toEqual({ ok: true, roles: { market: { window: 40_000 } } });
    expect(rolesAnswerOf({ kind: "overlay-result", op: "validator", changed: true, events: 0 })).toEqual({ ok: true, roles: {} });
    expect(rolesAnswerOf({ kind: "overlay-result", op: "market", error: "market: want {window: <ms>} (1000 ms to a day) or {off: true}" })).toEqual({ ok: false, message: "market: want {window: <ms>} (1000 ms to a day) or {off: true}" });
    expect(rolesAnswerOf({ kind: "overlay-result", op: "register", topic: "x", active: true }).ok).toBe(false);
  });
});
