/**
 * The owner's token list (`mandala.tokens/1`): the messages that change it,
 * the record that holds it, the answers. Pure; the page sends and reads.
 *
 * The list is the head `<app>/mandala`, `{kind: "mandala-tokens", topics}`
 * (docs/MANDALA.md "Activation"). A message to the app's box `<app>`:
 * `{fn: "mandala.tokens.activate" | "mandala.tokens.deactivate", args:
 * {tokenId} | {topic}}`; the answer `{fn, request, replyTo, result: {tokenId?,
 * topic, active}} | {…, error: {code, message}}`.
 */

export const DISCOVERY = "tm_mandala_deploys";
export const FN = { activate: "mandala.tokens.activate", deactivate: "mandala.tokens.deactivate" } as const;
export type Op = keyof typeof FN;

export interface Call {
  fn: (typeof FN)[Op];
  args: { tokenId: string } | { topic: string };
}

/** A token id `<txid>_<vout>` as the topic manager takes it (the `.` form accepted, normalized). */
export function tokenIdOf(text: string): string {
  const m = /^([0-9a-fA-F]{64})[_.](0|[1-9]\d*)$/.exec(text.trim());
  if (!m || Number(m[2]) > 0xffffffff) throw new Error("a token id: <txid>_<vout> (64 hex characters, then the output index)");
  return `${m[1]!.toLowerCase()}_${m[2]}`;
}

/** A token's topic: `tm_<txid>` for output 0, `tm_<txid>_<vout>` otherwise. */
export function topicOfToken(tokenId: string): string {
  const [txid, vout] = tokenIdOf(tokenId).split("_");
  return vout === "0" ? `tm_${txid}` : `tm_${txid}_${vout}`;
}

/** The token id a topic names; undefined for the discovery topic or a name that is not a token's. */
export function tokenOfTopic(topic: string): string | undefined {
  const m = /^tm_([0-9a-f]{64})(?:_(0|[1-9]\d*))?$/.exec(topic);
  if (!m || m[2] === "0") return undefined;
  return `${m[1]}_${m[2] ?? "0"}`;
}

export function activate(tokenId: string): Call {
  return { fn: FN.activate, args: { tokenId: tokenIdOf(tokenId) } };
}

/** Deactivate by topic: every row of the list is a topic. */
export function deactivate(topic: string): Call {
  return { fn: FN.deactivate, args: { topic } };
}

/** The discovery topic switched on or off. */
export function discovery(on: boolean): Call {
  return { fn: on ? FN.activate : FN.deactivate, args: { topic: DISCOVERY } };
}

/** The topics of the list record; [] for none (the head not written yet). */
export function topicsOf(record: unknown): string[] {
  if (record === undefined) return [];
  const r = record as { kind?: unknown; topics?: unknown };
  if (r.kind !== "mandala-tokens" || !Array.isArray(r.topics) || !r.topics.every((t) => typeof t === "string")) {
    throw new Error("the head is not a token list ({kind: \"mandala-tokens\", topics})");
  }
  return r.topics as string[];
}

export type Answer =
  | { ok: true; topic: string; active: boolean; tokenId?: string }
  | { ok: false; message: string };

/** An answer (the step's stdout, decoded) read as the outcome of the call. */
export function answerOf(v: unknown): Answer {
  const a = (v ?? {}) as { result?: { topic?: unknown; active?: unknown; tokenId?: unknown }; error?: { code?: unknown; message?: unknown } };
  if (a.error) return { ok: false, message: `${String(a.error.code ?? "error")}: ${String(a.error.message ?? "")}` };
  const r = a.result;
  if (r && typeof r.topic === "string" && typeof r.active === "boolean") {
    return { ok: true, topic: r.topic, active: r.active, ...(typeof r.tokenId === "string" && { tokenId: r.tokenId }) };
  }
  return { ok: false, message: `an answer not in the mandala.tokens/1 shape: ${JSON.stringify(v)}` };
}
