/**
 * The owner's token list (`mandala.tokens/1`): the messages that change it,
 * the record that holds it, the answers. Pure; the page sends and reads.
 *
 * The list is the head `<app>/mandala`, `{kind: "mandala-tokens", topics}`
 * (docs/MANDALA.md "Activation"). A message to the app's box `<app>`:
 * `{fn: "mandala.tokens.activate" | "mandala.tokens.deactivate", args:
 * {topic}}`, the topic `tm_<txid>`, `tm_<txid>_<vout>` or
 * `tm_mandala_deploys`; the answer `{fn, request, replyTo, result: {topic,
 * active}} | {…, error: {code, message}}`.
 */

export const DISCOVERY = "tm_mandala_deploys";
export const FN = { activate: "mandala.tokens.activate", deactivate: "mandala.tokens.deactivate" } as const;
export type Op = keyof typeof FN;

export interface Call {
  fn: (typeof FN)[Op];
  args: { topic: string };
}

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

export function activate(topic: string): Call {
  return { fn: FN.activate, args: { topic: tokenTopicOf(topic) } };
}

/** Deactivate a topic of the list. */
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
    throw new Error('the head is not a token list ({kind: "mandala-tokens", topics})');
  }
  return r.topics as string[];
}

export type Answer = { ok: true; topic: string; active: boolean } | { ok: false; message: string };

/** An answer (the step's stdout, decoded) read as the outcome of the call. */
export function answerOf(v: unknown): Answer {
  const a = (v ?? {}) as { result?: { topic?: unknown; active?: unknown }; error?: { code?: unknown; message?: unknown } };
  if (a.error) return { ok: false, message: `${String(a.error.code ?? "error")}: ${String(a.error.message ?? "")}` };
  const r = a.result;
  if (r && typeof r.topic === "string" && typeof r.active === "boolean") return { ok: true, topic: r.topic, active: r.active };
  return { ok: false, message: `an answer not in the mandala.tokens/1 shape: ${JSON.stringify(v)}` };
}
