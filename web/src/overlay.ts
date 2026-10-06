/**
 * The overlay the pages are served from, over its HTTP routes
 * (skein-overlay docs/OVERLAY.md "Submitting" and the routes table). A skein
 * takes no unsigned HTTP but GET/HEAD: a POST without a BRC-104 session is
 * 401. Every POST here goes through the connected wallet's BRC-104 client
 * (`signedFetch`, skein's `RawBox` AuthFetch); the `Fetch` parameter is there
 * for tests.
 *
 * - `POST <app base>/submit`: the BEEF as the body, `X-Topics` a comma list;
 *   `200 {id}` is delivery only (the request record's CID). The verdict goes
 *   to the submitter's box; an anonymous page sees it by a lookup.
 * - `POST <app base>/lookup {service, query}` →
 *   `{type: "output-list", outputs: [{beef, outputIndex}]}`.
 *
 * `<app base>` is `<base>/<app>` (the page's place, src/where.ts). The engine
 * ignores a topic it does not serve, so a submit to an unregistered topic
 * still lands (and is admitted by no one).
 */
import type { WalletInterface } from "@bsv/sdk";
import { RawBox } from "skein/src/client/raw.ts";
import { DISCOVERY } from "./tokens/list";

export { DISCOVERY };

export const DEPLOYS_LOOKUP = "ls_mandala_deploys";

export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

/**
 * The connected wallet's BRC-104 client to the instance at `base` (the
 * instance's place, `where.base`, not the app's): skein's `RawBox` AuthFetch,
 * which shakes hands under a `/@<handle>` prefix too.
 */
export function signedFetch(wallet: WalletInterface, base: string): Fetch {
  return authFetchOf(new RawBox(wallet, base));
}

/** A `RawBox`'s AuthFetch as a `Fetch` (the tokens page reuses its instance's). */
export function authFetchOf(box: RawBox): Fetch {
  return (url, init) => box.af.fetch(url, init as Parameters<RawBox["af"]["fetch"]>[1]);
}

/** The app's routes' base: `<base>/<app>`. */
export function appBaseOf(w: { base: string; app: string }): string {
  return `${w.base}/${w.app}`;
}

/** Submit a BEEF under topics; the delivery id. */
export async function submitBeef(appBase: string, beef: ArrayLike<number>, topics: string[], f: Fetch): Promise<string> {
  const r = await f(`${appBase}/submit`, {
    method: "POST",
    headers: { "content-type": "application/octet-stream", "x-topics": topics.join(",") },
    body: Uint8Array.from(beef) as unknown as BodyInit,
  });
  const text = await r.text();
  if (r.status !== 200) throw new Error(`submit: HTTP ${r.status} ${text.slice(0, 200)}`);
  let id: unknown;
  try { id = (JSON.parse(text) as { id?: unknown }).id; } catch { /* below */ }
  if (typeof id !== "string") throw new Error(`submit: an answer without an id: ${text.slice(0, 200)}`);
  return id;
}

/** The token a topic serves: `tm_<txid>` → `<txid>`, `tm_<txid>_<vout>` → `<txid>_<vout>`. */
export function tokenOfTopic(topic: string): { tokenId: string; txid: string; vout: number } {
  const m = /^tm_([0-9a-f]{64})(?:_([1-9]\d*))?$/.exec(topic);
  if (!m) throw new Error(`${topic}: not a token's topic (tm_<txid> or tm_<txid>_<vout>)`);
  const vout = m[2] === undefined ? 0 : Number(m[2]);
  return { tokenId: m[2] === undefined ? m[1]! : `${m[1]}_${m[2]}`, txid: m[1]!, vout };
}

/** The deploy's BEEF from the discovery lookup; undefined when it has none. */
export async function lookupDeployBeef(appBase: string, tokenId: string, f: Fetch): Promise<Uint8Array | undefined> {
  const r = await f(`${appBase}/lookup`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ service: DEPLOYS_LOOKUP, query: { tokenId } }),
  });
  const text = await r.text();
  if (r.status !== 200) throw new Error(`lookup ${DEPLOYS_LOOKUP}: HTTP ${r.status} ${text.slice(0, 200)}`);
  const a = JSON.parse(text) as { type?: unknown; outputs?: Array<{ beef?: unknown }> };
  if (a.type !== "output-list" || !Array.isArray(a.outputs)) throw new Error(`lookup ${DEPLOYS_LOOKUP}: not an output-list: ${text.slice(0, 200)}`);
  const beef = a.outputs[0]?.beef;
  return Array.isArray(beef) && beef.length > 0 ? Uint8Array.from(beef as number[]) : undefined;
}

/**
 * The deploy's BEEF from the connected wallet: the deploy output in the
 * token's basket `mandala <txid> <vout>` (@1sat/actions' filing), its
 * transaction as BEEF (`include: "entire transactions"`). Undefined when the
 * wallet does not hold it (not the deployer's, or the output spent).
 */
export async function walletDeployBeef(wallet: WalletInterface, txid: string, vout: number): Promise<ArrayLike<number> | undefined> {
  const r = await wallet.listOutputs({ basket: `mandala ${txid} ${vout}`, include: "entire transactions", limit: 100 });
  const held = r.outputs.some((o) => o.outpoint === `${txid}.${vout}`);
  return held && r.BEEF && r.BEEF.length > 0 ? r.BEEF : undefined;
}

export type Submitted = { id: string; via: "lookup" | "wallet"; topics: string[] };

/**
 * Submit a token's deploy to its own topic: the deploy's BEEF from the
 * discovery lookup, submitted under the token's topic; if the lookup has none
 * (a token deployed before the deploy page submitted to discovery), the
 * wallet's copy, submitted under both the discovery topic and the token's.
 */
export async function submitDeployToTopic(appBase: string, topic: string, wallet: WalletInterface | undefined, f: Fetch): Promise<Submitted> {
  const { tokenId } = tokenOfTopic(topic);
  const found = await lookupDeployBeef(appBase, tokenId, f);
  if (found) {
    const topics = [topic];
    return { id: await submitBeef(appBase, found, topics, f), via: "lookup", topics };
  }
  return submitWalletDeploy(appBase, topic, wallet, f, `the discovery lookup has no deploy for ${tokenId}`);
}

/**
 * The wallet's copy of a token's deploy submitted under the discovery topic
 * and the token's: for a deploy the overlay never held (a register's seeding
 * answered it `missing`, skein-overlay 0.7.8). `why` begins the error when the
 * wallet cannot give it.
 */
export async function submitWalletDeploy(appBase: string, topic: string, wallet: WalletInterface | undefined, f: Fetch, why = "the overlay does not hold the deploy"): Promise<Submitted> {
  const { txid, vout } = tokenOfTopic(topic);
  if (!wallet) throw new Error(`${why}, and no wallet is connected to give it`);
  const beef = await walletDeployBeef(wallet, txid, vout);
  if (!beef) throw new Error(`${why}, and this wallet does not hold it (basket mandala ${txid} ${vout})`);
  const topics = [DISCOVERY, topic];
  return { id: await submitBeef(appBase, beef, topics, f), via: "wallet", topics };
}
