/**
 * The topics this overlay serves: the overlay engine's registered set
 * (skein-overlay 0.6.0, docs/OVERLAY.md "Register a topic"), the messages
 * that change it, the answers. Pure; the page sends and reads.
 *
 * The set is the engine's head `<app>/topics`, `{kind: "overlay-topics",
 * topics: [{topic, program}]}`. A message to the app's box `<app>/register` (skein-overlay 0.7.7): `{fn:
 * "register", args: {topic, program: "mandala-topic"}}` or `{fn:
 * "deregister", args: {topic}}`, the topic `tm_<txid>`, `tm_<txid>_<vout>`
 * or `tm_mandala_deploys`. The step's answer is its result record (its CID
 * on stdout): `{kind: "overlay-result", op, topic, active, changed}` or
 * `{kind: "overlay-result", op, error}` for a refusal.
 */

export const DISCOVERY = "tm_mandala_deploys";
/** The role in the app's `programs` that judges a Mandala topic. */
export const PROGRAM = "mandala-topic";

export type Call =
  | { fn: "register"; args: { topic: string; program: string } }
  | { fn: "deregister"; args: { topic: string } };

/**
 * A token's topic as typed: `tm_<txid>` (a token deployed at output 0) or
 * `tm_<txid>_<vout>` (a BRC-161 token at a non-zero output); 64 lowercase hex.
 */
export function tokenTopicOf(text: string): string {
  const t = text.trim();
  const m = /^tm_[0-9a-f]{64}(?:_([1-9]\d*))?$/.exec(t);
  if (!m || (m[1] !== undefined && Number(m[1]) > 0xffffffff)) {
    throw new Error("a token's topic: tm_<txid> or tm_<txid>_<vout> (64 lowercase hex characters)");
  }
  return t;
}

/** Register a token's topic, judged by mandala-topic. */
export function register(topic: string): Call {
  return { fn: "register", args: { topic: tokenTopicOf(topic), program: PROGRAM } };
}

/** Deregister a topic. */
export function deregister(topic: string): Call {
  return { fn: "deregister", args: { topic } };
}

/** The discovery topic switched on or off. */
export function discovery(on: boolean): Call {
  return on ? { fn: "register", args: { topic: DISCOVERY, program: PROGRAM } } : deregister(DISCOVERY);
}

export interface Registered {
  topic: string;
  program: string;
}

/** The registered set's record; [] for none (the head not written yet). */
export function registeredOf(record: unknown): Registered[] {
  if (record === undefined) return [];
  const r = record as { kind?: unknown; topics?: unknown };
  const ok = (e: unknown) => typeof (e as Registered)?.topic === "string" && typeof (e as Registered)?.program === "string";
  if (r.kind !== "overlay-topics" || !Array.isArray(r.topics) || !r.topics.every(ok)) {
    throw new Error('the head is not the registered topics ({kind: "overlay-topics", topics: [{topic, program}]})');
  }
  return (r.topics as Registered[]).map(({ topic, program }) => ({ topic, program }));
}

/** The topics of the set that mandala-topic judges. */
export function topicsOf(record: unknown): string[] {
  return registeredOf(record).filter((e) => e.program === PROGRAM).map((e) => e.topic);
}

export type Answer = { ok: true; topic: string; active: boolean } | { ok: false; message: string };

/** The step's result record read as the outcome of the call. */
export function answerOf(v: unknown): Answer {
  const r = (v ?? {}) as { kind?: unknown; topic?: unknown; active?: unknown; error?: unknown };
  if (r.kind === "overlay-result" && r.error !== undefined) return { ok: false, message: String(r.error) };
  if (r.kind === "overlay-result" && typeof r.topic === "string" && typeof r.active === "boolean") return { ok: true, topic: r.topic, active: r.active };
  return { ok: false, message: `an answer not in the overlay-result shape: ${JSON.stringify(v)}` };
}
