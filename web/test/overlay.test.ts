// The pages' requests to the overlay they are served from: the deploy's
// submit under the discovery topic, and a token topic's own deploy submitted
// after its register (from the discovery lookup, or the wallet's copy).
import { describe, expect, it } from "vitest";
import type { WalletInterface } from "@bsv/sdk";
import { appBaseOf, submitBeef, submitDeployToTopic, tokenOfTopic, type Fetch } from "../src/overlay";
import { whereOf } from "../src/where";

const txid = "ec".repeat(32);
const base = appBaseOf(whereOf("https://mandala.skein.nexus/amm/mandala/deploy/")!);
const beef = [1, 1, 1, 1, 0xbe, 0xef];

type Sent = { url: string; method?: string; headers: Record<string, string>; body: unknown };

function stub(lookupOutputs: unknown[]): { f: Fetch; sent: Sent[] } {
  const sent: Sent[] = [];
  const f: Fetch = async (url, init) => {
    sent.push({ url, method: init?.method, headers: init?.headers as Record<string, string>, body: init?.body });
    if (url.endsWith("/lookup")) return new Response(JSON.stringify({ type: "output-list", outputs: lookupOutputs }), { status: 200 });
    if (url.endsWith("/submit")) return new Response(JSON.stringify({ id: "a1b2" }), { status: 200 });
    return new Response("no", { status: 404 });
  };
  return { f, sent };
}

describe("the deploy page's submit", () => {
  it("POST <base>/<app>/submit, the BEEF as the body, X-Topics the discovery topic only", async () => {
    const { f, sent } = stub([]);
    expect(base).toBe("https://mandala.skein.nexus/amm");
    expect(await submitBeef(base, beef, ["tm_mandala"], f)).toBe("a1b2");
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toBe("https://mandala.skein.nexus/amm/submit");
    expect(sent[0]!.method).toBe("POST");
    expect(sent[0]!.headers["x-topics"]).toBe("tm_mandala");
    expect(sent[0]!.headers["content-type"]).toBe("application/octet-stream");
    expect(Array.from(sent[0]!.body as Uint8Array)).toEqual(beef);
  });
  it("a refusal or an answer without an id is an error", async () => {
    const bad: Fetch = async () => new Response('{"status":"error","message":"no X-Topics"}', { status: 400 });
    await expect(submitBeef(base, beef, ["tm_mandala"], bad)).rejects.toThrow(/HTTP 400/);
    const noId: Fetch = async () => new Response("{}", { status: 200 });
    await expect(submitBeef(base, beef, ["tm_mandala"], noId)).rejects.toThrow(/without an id/);
  });
});

describe("a token topic's own deploy", () => {
  it("the token id from the topic", () => {
    expect(tokenOfTopic(`tm_${txid}`)).toEqual({ tokenId: txid, txid, vout: 0 });
    expect(tokenOfTopic(`tm_${txid}_3`)).toEqual({ tokenId: `${txid}_3`, txid, vout: 3 });
    expect(() => tokenOfTopic("tm_mandala")).toThrow(/token's topic/);
  });
  it("register → the discovery lookup → submit under tm_<txid> only", async () => {
    const { f, sent } = stub([{ beef, outputIndex: 0 }]);
    const r = await submitDeployToTopic(base, `tm_${txid}`, undefined, f);
    expect(r).toEqual({ id: "a1b2", via: "lookup", topics: [`tm_${txid}`] });
    expect(sent.map((s) => s.url)).toEqual([`${base}/lookup`, `${base}/submit`]);
    expect(JSON.parse(sent[0]!.body as string)).toEqual({ service: "ls_mandala_deploys", query: { tokenId: txid } });
    expect(sent[1]!.headers["x-topics"]).toBe(`tm_${txid}`);
    expect(Array.from(sent[1]!.body as Uint8Array)).toEqual(beef);
  });
  it("the legacy form looks up <txid>_<vout>", async () => {
    const { f, sent } = stub([{ beef, outputIndex: 2 }]);
    await submitDeployToTopic(base, `tm_${txid}_2`, undefined, f);
    expect(JSON.parse(sent[0]!.body as string).query).toEqual({ tokenId: `${txid}_2` });
  });
  it("the lookup has none: the wallet's copy (basket mandala <txid> 0), under tm_mandala and tm_<txid>", async () => {
    const { f, sent } = stub([]);
    const asked: unknown[] = [];
    const wallet = {
      listOutputs: async (a: unknown) => { asked.push(a); return { totalOutputs: 1, outputs: [{ outpoint: `${txid}.0`, satoshis: 1, spendable: true }], BEEF: beef }; },
    } as unknown as WalletInterface;
    const r = await submitDeployToTopic(base, `tm_${txid}`, wallet, f);
    expect(r).toEqual({ id: "a1b2", via: "wallet", topics: ["tm_mandala", `tm_${txid}`] });
    expect(asked).toEqual([{ basket: `mandala ${txid} 0`, include: "entire transactions", limit: 100 }]);
    expect(sent[1]!.headers["x-topics"]).toBe(`tm_mandala,tm_${txid}`);
    expect(Array.from(sent[1]!.body as Uint8Array)).toEqual(beef);
  });
  it("neither has it: an error, nothing submitted", async () => {
    const { f, sent } = stub([]);
    const wallet = { listOutputs: async () => ({ totalOutputs: 0, outputs: [] }) } as unknown as WalletInterface;
    await expect(submitDeployToTopic(base, `tm_${txid}`, wallet, f)).rejects.toThrow(/does not hold it/);
    await expect(submitDeployToTopic(base, `tm_${txid}`, undefined, f)).rejects.toThrow(/no wallet/);
    expect(sent.every((s) => s.url.endsWith("/lookup"))).toBe(true);
  });
});
