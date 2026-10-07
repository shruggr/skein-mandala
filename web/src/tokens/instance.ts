/**
 * The instance, read and written as root (shruggr/skein#143): skein-site's way
 * (shruggr/skein-site app.js, class `Skein`: `fetch`, `read`, `send`,
 * `threadOf`, and `identityAt`), over skein's own BRC-104 client `RawBox`
 * (skein src/client/raw.ts).
 *
 * - A message is `RawBox.send(<instance identity>, <box>, body)`: the
 *   BRC-104-signed `POST <base>/sendMessage`, BRC-231 CBOR `{message:
 *   {recipient, messageBox, body}}` — what `skein send` and any BRC-100
 *   wallet send (skein#124, docs/MESSAGES.md "The messagebox").
 * - The instance's identity is the key its signed answers carry
 *   (`x-bsv-auth-identity-key`).
 * - Reads are the explorer (`/explore…`, gated by root): a head
 *   (`/explore/head/<name>`), a record (`/explore/record/<cid>`), and the
 *   answer to a message from the thread it launched
 *   (`/explore/edges/<message>?rel=launched-by`, then `/explore/thread/<origin>`
 *   until it rests; the step's stdout is the CID of its result record).
 */
import type { WalletInterface } from "@bsv/sdk";
import * as dagJson from "@ipld/dag-json";
import { CID } from "multiformats/cid";
import { RawBox } from "skein/src/client/raw.ts";

export class ReadError extends Error {
  constructor(readonly status: number, text: string) {
    super(status === 403 ? "your key may not read this skein: its explorer is root's" : `HTTP ${status} ${text}`);
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class Instance {
  readonly box: RawBox;
  /** The identity the instance's answers are signed by (hex), once one is read. */
  answeredBy?: string;

  constructor(wallet: WalletInterface, readonly base: string) {
    this.box = new RawBox(wallet, base);
  }

  /** A signed GET to the instance; the identity its answer is signed by is remembered. */
  async fetch(path: string): Promise<Response> {
    const r = await this.box.af.fetch(this.base + path, { method: "GET" });
    const id = r.headers.get("x-bsv-auth-identity-key");
    if (id) this.answeredBy = id;
    return r;
  }

  /** A read of the explorer: DAG-JSON decoded; 404 → undefined. */
  async read(path: string): Promise<unknown> {
    const r = await this.fetch(`/explore${path}`);
    const bytes = new Uint8Array(await r.arrayBuffer());
    if (r.status === 404) return undefined;
    if (r.status !== 200) throw new ReadError(r.status, new TextDecoder().decode(bytes).slice(0, 200));
    return dagJson.decode(bytes);
  }

  /** The record a head names; undefined when the head is not written. */
  async head(name: string): Promise<unknown> {
    const h = (await this.read(`/head/${name}`)) as { tree?: { toString(): string } } | undefined;
    if (!h?.tree) return undefined;
    return this.read(`/record/${h.tree.toString()}`);
  }

  /** The instance's identity: from a signed answer (a read the instance may refuse; the signature is what counts). */
  async identity(): Promise<string> {
    if (!this.answeredBy) await this.fetch("/explore");
    if (!this.answeredBy) throw new Error(`${this.base}: no signed answer (is it a skein?)`);
    return this.answeredBy;
  }

  /** A message from the wallet's key to the instance's `box`: its id. */
  async send(box: string, body: unknown): Promise<string> {
    return (await this.box.send(await this.identity(), box, body)).id.toString();
  }

  /** The thread a message launched, read until it comes to rest: its last update. */
  async threadOf(message: string, timeoutMs = 120_000): Promise<{ origin: string; update: Record<string, unknown> }> {
    const deadline = Date.now() + timeoutMs;
    for (let wait = 500; ; wait = Math.min(wait * 2, 5000)) {
      const e = (await this.read(`/edges/${message}?rel=launched-by`)) as { edges?: Array<{ from: { toString(): string } }> } | undefined;
      for (const edge of e?.edges ?? []) {
        const t = (await this.read(`/thread/${edge.from.toString()}`)) as { updates?: Array<{ record?: Record<string, unknown> }> } | undefined;
        const last = t?.updates?.at(-1)?.record;
        if (last && (last.state === "finished" || last.state === "errored")) return { origin: edge.from.toString(), update: last };
      }
      if (Date.now() > deadline) throw new Error("no answer yet: the thread has not come to rest (see the explorer's threads)");
      await sleep(wait);
    }
  }

  /**
   * A call's answer: the message sent, its thread read until it rests, and
   * the result record its step printed the CID of (hex, one line on stdout;
   * skein-overlay docs/OVERLAY.md "Result").
   */
  async call(box: string, body: unknown): Promise<unknown> {
    const id = await this.send(box, body);
    const { update } = await this.threadOf(id);
    if (update.state === "errored") throw new Error(`the thread errored: ${JSON.stringify(update.error ?? {})}`);
    const out = new TextDecoder().decode((update.result as { stdout?: Uint8Array } | undefined)?.stdout ?? new Uint8Array()).trim();
    if (!/^([0-9a-f]{2})+$/.test(out)) throw new Error(`no result record on the step's stdout: ${JSON.stringify(out.slice(0, 200))}`);
    return this.read(`/record/${CID.decode(Uint8Array.from(out.match(/../g)!, (h) => parseInt(h, 16))).toString()}`);
  }
}
