import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import * as list from "../src/tokens/list";
import { DISCOVERY, answerOf, assetIdOf, deployTxidOf, deregister, deregisterToken, discovery, lookupAnswerOf, lookupOf, lookupsOf, register, registerLookup, registerToken, tokenTopicOf, topicsOf } from "../src/tokens/list";

const txid = "cd".repeat(32);

describe("root's calls: the engine's register / deregister, registerLookup / deregisterLookup (BRC-207)", () => {
  it("register a token's topic, judged by mandala-topic, seeded with its deploy (skein-overlay 0.7.8)", () => {
    expect(register(` tm_mandala_${txid}_0 `)).toEqual({ fn: "register", args: { topic: `tm_mandala_${txid}_0`, program: "mandala-topic", seed: [txid] } });
    expect(register(`tm_mandala_${txid}_2`)).toEqual({ fn: "register", args: { topic: `tm_mandala_${txid}_2`, program: "mandala-topic", seed: [txid] } });
    expect(deployTxidOf(`tm_mandala_${txid}_2`)).toBe(txid);
    expect(assetIdOf(`tm_mandala_${txid}_2`)).toBe(`${txid}_2`);
  });
  it("a token is two registrations: its topic, then its lookup ls_mandala_<assetId> (mandala-lookup, hearing its topic); deregistered in reverse", () => {
    const t = `tm_mandala_${txid}_0`;
    expect(lookupOf(t)).toBe(`ls_mandala_${txid}_0`);
    expect(registerLookup(t)).toEqual({ fn: "registerLookup", args: { service: `ls_mandala_${txid}_0`, program: "mandala-lookup", topics: [t] } });
    expect(registerToken(t)).toEqual([register(t), registerLookup(t)]);
    expect(deregisterToken(t)).toEqual([{ fn: "deregisterLookup", args: { service: `ls_mandala_${txid}_0` } }, { fn: "deregister", args: { topic: t } }]);
    expect(() => registerToken(`tm_${txid}_0`)).toThrow(/topic/);
  });
  it("a token id is not a topic; the old tm_<txid>_<vout> is no topic (no alias); tm_mandala_<txid>_0 is", () => {
    for (const bad of [txid, `${txid}_0`, `${txid}.0`, `tm_${txid}`, `tm_${txid}_0`, `tm_mandala_${txid}`, `tm_mandala_${txid}_01`, `tm_mandala_${txid.toUpperCase()}_0`, `tm_mandala_${txid}_4294967296`, `ls_mandala_${txid}_0`, DISCOVERY]) {
      expect(() => tokenTopicOf(bad)).toThrow(/topic/);
    }
    expect(tokenTopicOf(`tm_mandala_${txid}_4294967295`)).toBe(`tm_mandala_${txid}_4294967295`);
  });
  it("deregister by topic", () => {
    expect(deregister(`tm_mandala_${txid}_0`)).toEqual({ fn: "deregister", args: { topic: `tm_mandala_${txid}_0` } });
  });
  it("the discovery switch", () => {
    expect(discovery(true)).toEqual({ fn: "register", args: { topic: DISCOVERY, program: "mandala-topic" } });
    expect(discovery(false)).toEqual({ fn: "deregister", args: { topic: DISCOVERY } });
  });
});

describe("the registered set and the answers", () => {
  it("the set's record: mandala-topic's topics", () => {
    expect(topicsOf(undefined)).toEqual([]);
    const rec = { kind: "overlay-topics", topics: [{ topic: "tm_other", program: "other-topic" }, { topic: DISCOVERY, program: "mandala-topic" }, { topic: `tm_mandala_${txid}_0`, program: "mandala-topic" }] };
    expect(topicsOf(rec)).toEqual([DISCOVERY, `tm_mandala_${txid}_0`]);
    expect(() => topicsOf({ kind: "mandala-tokens", topics: [`tm_mandala_${txid}_0`] })).toThrow(/registered topics/);
    expect(() => topicsOf({ kind: "overlay-topics", topics: [`tm_mandala_${txid}_0`] })).toThrow(/registered topics/);
  });
  it("the lookup set's record (<app>/lookups): mandala-lookup's services", () => {
    expect(lookupsOf(undefined)).toEqual([]);
    const rec = { kind: "overlay-lookups", lookups: [{ service: "ls_other", program: "other-lookup" }, { service: `ls_mandala_${txid}_0`, program: "mandala-lookup", topics: [`tm_mandala_${txid}_0`] }] };
    expect(lookupsOf(rec)).toEqual([`ls_mandala_${txid}_0`]);
    expect(() => lookupsOf({ kind: "overlay-topics", topics: [] })).toThrow(/registered lookups/);
    expect(() => lookupsOf({ kind: "overlay-lookups", lookups: [`ls_mandala_${txid}_0`] })).toThrow(/registered lookups/);
  });
  it("a lookup registration's answer: {service, active}, or the refusal", () => {
    expect(lookupAnswerOf({ kind: "overlay-result", op: "registerLookup", service: `ls_mandala_${txid}_0`, active: true, changed: true })).toEqual({ ok: true, service: `ls_mandala_${txid}_0`, active: true });
    expect(lookupAnswerOf({ kind: "overlay-result", op: "registerLookup", error: "registerLookup: program x is not a role in programs" })).toEqual({ ok: false, message: "registerLookup: program x is not a role in programs" });
    expect(lookupAnswerOf({ kind: "overlay-result", op: "register", topic: "x", active: true }).ok).toBe(false);
  });
  it("an answer: the step's result record", () => {
    expect(answerOf({ kind: "overlay-result", op: "register", topic: `tm_mandala_${txid}_0`, active: true, changed: true })).toEqual({ ok: true, topic: `tm_mandala_${txid}_0`, active: true });
    expect(answerOf({ kind: "overlay-result", op: "register", error: "registered with another program; deregister it first" })).toEqual({ ok: false, message: "registered with another program; deregister it first" });
    expect(answerOf({}).ok).toBe(false);
  });
  it("a register's seeding: seeded / missing (untaken when present)", () => {
    expect(answerOf({ kind: "overlay-result", op: "register", topic: `tm_mandala_${txid}_0`, active: true, changed: true, seeded: [txid], missing: [] }))
      .toEqual({ ok: true, topic: `tm_mandala_${txid}_0`, active: true, seeding: { seeded: [txid], missing: [], untaken: [] } });
    expect(answerOf({ kind: "overlay-result", op: "register", topic: `tm_mandala_${txid}_0`, active: true, changed: false, seeded: [], missing: [txid] }))
      .toEqual({ ok: true, topic: `tm_mandala_${txid}_0`, active: true, seeding: { seeded: [], missing: [txid], untaken: [] } });
    expect(answerOf({ kind: "overlay-result", op: "register", topic: `tm_mandala_${txid}_0`, active: true, seeded: [], missing: [], untaken: [txid] }).ok && "seeding")
      .toBe("seeding");
  });
});

describe("market and validator are not switches (skein-overlay 0.12.0, David 2026-10-09: always both)", () => {
  it("the page offers no market / validator switch and sends no such message", () => {
    expect("roleSwitch" in list).toBe(false);
    expect("rolesOf" in list).toBe(false);
    const page = readFileSync(new URL("../src/tokens/main.tsx", import.meta.url), "utf8");
    expect(page).not.toMatch(/fn: "(market|validator)"|switchRole|roleSwitch/);
  });
  it("the set's record is read for its topics alone", () => {
    expect(topicsOf({ kind: "overlay-topics", topics: [{ topic: `tm_mandala_${txid}_0`, program: "mandala-topic" }] })).toEqual([`tm_mandala_${txid}_0`]);
  });
});
