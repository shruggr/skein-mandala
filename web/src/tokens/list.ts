/**
 * The topics this overlay serves: the overlay engine's registered set
 * (skein-overlay 0.6.0, docs/OVERLAY.md "Register a topic"), the messages
 * that change it, the answers. Pure; the page sends and reads.
 *
 * The set is the engine's head `<app>/topics`, `{kind: "overlay-topics",
 * topics: [{topic, program}]}`. A message to the app's box `<app>/register` (skein-overlay 0.7.7): `{fn:
 * "register", args: {topic, program: "mandala-topic", seed?}}` or `{fn:
 * "deregister", args: {topic}}`, the topic `tm_<txid>`, `tm_<txid>_<vout>`
 * or `tm_mandala`. A token's register seeds its topic with its deploy
 * (skein-overlay 0.7.8): `seed: [<the deploy txid>]`, judged from what the
 * instance's chain state holds. The step's answer is its result record (its
 * CID on stdout): `{kind: "overlay-result", op, topic, active, changed,
 * seeded?, missing?, untaken?}` or `{kind: "overlay-result", op, error}` for a
 * refusal.
 */

export const DISCOVERY = "tm_mandala";
/** The role in the app's `programs` that judges a Mandala topic. */
export const PROGRAM = "mandala-topic";

export type Call =
  | { fn: "register"; args: { topic: string; program: string; seed?: string[] } }
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

/** The deploy txid a token's topic names: `tm_<txid>` / `tm_<txid>_<vout>` → `<txid>`. */
export function deployTxidOf(topic: string): string {
  return tokenTopicOf(topic).slice(3, 67);
}

/** Register a token's topic, judged by mandala-topic, seeded with its deploy (skein-overlay 0.7.8). */
export function register(topic: string): Call {
  const t = tokenTopicOf(topic);
  return { fn: "register", args: { topic: t, program: PROGRAM, seed: [deployTxidOf(t)] } };
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

/**
 * A register's seeding (skein-overlay 0.7.8): `seeded` the seeds the topic
 * holds now, `missing` the seeds the instance's chain state does not hold,
 * `untaken` the held seeds the topic took nothing of.
 */
export interface Seeding {
  seeded: string[];
  missing: string[];
  untaken: string[];
}

export type Answer = { ok: true; topic: string; active: boolean; seeding?: Seeding } | { ok: false; message: string };

const txids = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);

/** The step's result record read as the outcome of the call. */
export function answerOf(v: unknown): Answer {
  const r = (v ?? {}) as { kind?: unknown; topic?: unknown; active?: unknown; error?: unknown; seeded?: unknown; missing?: unknown; untaken?: unknown };
  if (r.kind === "overlay-result" && r.error !== undefined) return { ok: false, message: String(r.error) };
  if (r.kind === "overlay-result" && typeof r.topic === "string" && typeof r.active === "boolean") {
    const a: Answer = { ok: true, topic: r.topic, active: r.active };
    if (r.seeded !== undefined || r.missing !== undefined) a.seeding = { seeded: txids(r.seeded), missing: txids(r.missing), untaken: txids(r.untaken) };
    return a;
  }
  return { ok: false, message: `an answer not in the overlay-result shape: ${JSON.stringify(v)}` };
}

/**
 * The engine's two roles, the owner's switch (skein-overlay 0.9.2; David,
 * 2026-10-07: "this shouldn't have been a config in the manifest. This
 * should be a setting that the user is configuring"). Sent where register
 * is, `<app>/register`: `{fn: "market", args: {window} | {off: true}}`,
 * `{fn: "validator", args: {every} | {off: true}}`. The answer (the step's
 * result record) carries the roles in effect, `market?: {window}` and
 * `validator?: {every}`, each only when on. The switch is kept beside the
 * set in `<app>/topics` (`market?` / `validator?`: `{window}` / `{every}` or
 * `{off: true}`); never switched, the role is the manifest's
 * `config.overlay.market` / `.validator` (the app record `<app>/app`).
 */
export type Role = "market" | "validator";
export interface Roles {
  market?: { window: number };
  validator?: { every: number };
}
export type RoleCall = { fn: "market"; args: { window: number } | { off: true } } | { fn: "validator"; args: { every: number } | { off: true } };

/** The ms a switch turned on asks for when the page names none: a liveness window of 40 s, a beat every 30 s. */
export const DEFAULT_WINDOW = 40_000;
export const DEFAULT_EVERY = 30_000;

/** A role switched on (with its ms) or off. */
export function roleSwitch(role: Role, on: boolean, ms?: number): RoleCall {
  if (!on) return role === "market" ? { fn: "market", args: { off: true } } : { fn: "validator", args: { off: true } };
  return role === "market" ? { fn: "market", args: { window: ms ?? DEFAULT_WINDOW } } : { fn: "validator", args: { every: ms ?? DEFAULT_EVERY } };
}

const msOf = (v: unknown, field: "window" | "every"): number | undefined => {
  const n = (v as Record<string, unknown> | undefined)?.[field];
  return typeof n === "number" && Number.isInteger(n) ? n : undefined;
};

/**
 * The roles in effect, as the engine reads them: the switch kept in the set's
 * record (`<app>/topics`) when sent, else the app record's (`<app>/app`)
 * `config.overlay.market` / `.validator`.
 */
export function rolesOf(topicsRecord: unknown, appRecord: unknown): Roles {
  const sw = (topicsRecord ?? {}) as Record<string, unknown>;
  const cfg = (((appRecord ?? {}) as { config?: { overlay?: Record<string, unknown> } }).config?.overlay ?? {}) as Record<string, unknown>;
  const out: Roles = {};
  for (const [role, field] of [["market", "window"], ["validator", "every"]] as const) {
    const s = sw[role] as Record<string, unknown> | undefined;
    const ms = s !== undefined ? (s.off === true ? undefined : msOf(s, field)) : msOf(cfg[role], field);
    if (ms !== undefined) (out as Record<string, unknown>)[role] = { [field]: ms };
  }
  return out;
}

export type RolesAnswer = { ok: true; roles: Roles } | { ok: false; message: string };

/** A switch's step result record: the roles in effect after it. */
export function rolesAnswerOf(v: unknown): RolesAnswer {
  const r = (v ?? {}) as { kind?: unknown; op?: unknown; error?: unknown; market?: unknown; validator?: unknown };
  if (r.kind === "overlay-result" && r.error !== undefined) return { ok: false, message: String(r.error) };
  if (r.kind === "overlay-result" && (r.op === "market" || r.op === "validator")) {
    const roles: Roles = {};
    const w = msOf(r.market, "window");
    const e = msOf(r.validator, "every");
    if (w !== undefined) roles.market = { window: w };
    if (e !== undefined) roles.validator = { every: e };
    return { ok: true, roles };
  }
  return { ok: false, message: `an answer not in the overlay-result shape: ${JSON.stringify(v)}` };
}
