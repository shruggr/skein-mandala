/**
 * The tokens this overlay serves: the owner's page. Reads the overlay
 * engine's registered topics (the head `<app>/topics`, through the explorer,
 * the owner's read), and changes them by the owner's `register` /
 * `deregister` messages to the app's box `<app>/register` (skein-overlay 0.7.7+).
 * A token's register seeds its topic with the token's deploy (skein-overlay
 * 0.7.8, `seed: [<deploy txid>]`): the engine judges it from what the
 * instance's chain state holds, and the answer says `seeded` or `missing`.
 * Missing (the overlay never held the deploy), the page submits the wallet's
 * copy (src/overlay.ts `submitWalletDeploy`). "Submit deploy to this
 * overlay" submits the deploy on demand (`submitDeployToTopic`: the discovery
 * lookup's, else the wallet's). The lookup and the submit are POSTs, so they
 * go signed, through the instance's BRC-104 client.
 *
 * The two switches, Market and Validator (skein-overlay 0.9.2): the owner's
 * `market` / `validator` message to the same box `<app>/register`, as register
 * is sent; the answer is the roles in effect. Read from the set's record
 * (the switch, once sent) over the app record's `config.overlay`.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useWallet } from "@1sat/react";
import { mount } from "../shell";
import { Id, Ids } from "../Id";
import { whereOf } from "../where";
import { Instance } from "./instance";
import { appBaseOf, authFetchOf, submitDeployToTopic, submitWalletDeploy, type Submitted } from "../overlay";
import { DISCOVERY, answerOf, deployTxidOf, deregister, discovery, register, roleSwitch, rolesAnswerOf, rolesOf, topicsOf, type Call, type Role, type Roles, type Seeding } from "./list";

const where = whereOf(location.href);

function TokensPage() {
  const { wallet, status } = useWallet();
  const inst = useMemo(() => (wallet && status === "connected" && where ? new Instance(wallet, where.base) : undefined), [wallet, status]);
  const [topics, setTopics] = useState<string[]>();
  const [readErr, setReadErr] = useState("");
  const [busy, setBusy] = useState("");
  const [note, setNote] = useState<{ ok: boolean; text: string }>();
  const [topic, setTopic] = useState("");
  const [roles, setRoles] = useState<Roles>();

  const load = useCallback(async () => {
    if (!inst || !where) return;
    try {
      const set = await inst.head(`${where.app}/topics`);
      setTopics(topicsOf(set));
      setRoles(rolesOf(set, await inst.head(`${where.app}/app`)));
      setReadErr("");
    }
    catch (e) { setTopics(undefined); setRoles(undefined); setReadErr((e as Error).message); }
  }, [inst]);
  useEffect(() => { void load(); }, [load]);

  /** The token's deploy submitted under its topic: from the discovery lookup, or the wallet's copy; `walletOnly` the wallet's. */
  async function submitDeploy(t: string, prefix = "", walletOnly = false): Promise<{ ok: boolean; text: string }> {
    if (!where || !inst) return { ok: false, text: where ? "no wallet connected" : "no app" };
    try {
      const f = authFetchOf(inst.box);
      const r: Submitted = walletOnly
        ? await submitWalletDeploy(appBaseOf(where), t, wallet ?? undefined, f, "the overlay's chain state does not hold the deploy")
        : await submitDeployToTopic(appBaseOf(where), t, wallet ?? undefined, f);
      const from = r.via === "lookup" ? "from the discovery lookup" : walletOnly ? "from your wallet" : "from your wallet (the discovery lookup had none)";
      return { ok: true, text: `${prefix}deploy submitted ${from} under ${r.topics.join(", ")}: ${r.answer}.` };
    } catch (e) { return { ok: false, text: `${prefix}deploy not submitted: ${(e as Error).message}` }; }
  }

  /** What a token's register seeded (skein-overlay 0.7.8): the deploy seeded, or missing (→ the wallet's copy), or held but not taken. */
  async function afterSeeding(topic: string, s: Seeding | undefined): Promise<{ ok: boolean; text: string }> {
    const deploy = deployTxidOf(topic);
    const seeded = `seeded: ${s?.seeded.length ? s.seeded.join(", ") : "none"}; missing: ${s?.missing.length ? s.missing.join(", ") : "none"}`;
    if (s?.seeded.includes(deploy)) return { ok: true, text: `${topic}: registered; the deploy was seeded from the overlay's chain state (${seeded}).` };
    if (s?.untaken.includes(deploy)) return { ok: false, text: `${topic}: registered; the overlay holds the deploy, but the topic took nothing of it (${seeded}).` };
    // Missing (or an engine before 0.7.8, which answers no seeding): the wallet's copy.
    setBusy(`${topic}:submit`);
    return submitDeploy(topic, `${topic}: registered (${s ? seeded : "no seeding in the answer"}); `, true);
  }

  async function run(label: string, c: Call) {
    if (!inst || !where) return;
    setBusy(label); setNote(undefined);
    try {
      const a = answerOf(await inst.call(`${where.app}/register`, c));
      if (a.ok && a.active && c.fn === "register" && a.topic !== DISCOVERY) {
        setNote(await afterSeeding(a.topic, a.seeding));
      } else {
        setNote(a.ok ? { ok: true, text: `${a.topic}: ${a.active ? "registered" : "not registered"}` } : { ok: false, text: a.message });
      }
    } catch (e) { setNote({ ok: false, text: (e as Error).message }); }
    setBusy("");
    await load();
  }

  /** The owner's switch of a role (skein-overlay 0.9.2): the answer is the roles in effect. */
  async function switchRole(role: Role, on: boolean) {
    if (!inst || !where) return;
    setBusy(role); setNote(undefined);
    try {
      const a = rolesAnswerOf(await inst.call(`${where.app}/register`, roleSwitch(role, on)));
      if (a.ok) {
        setRoles(a.roles);
        setNote({ ok: true, text: `${role}: ${a.roles[role] ? "on" : "off"}. In effect: ${rolesText(a.roles)}.` });
      } else setNote({ ok: false, text: a.message });
    } catch (e) { setNote({ ok: false, text: (e as Error).message }); }
    setBusy("");
    await load();
  }

  async function resubmit(t: string) {
    setBusy(`submit:${t}`); setNote(undefined);
    setNote(await submitDeploy(t, `${t}: `));
    setBusy("");
  }

  if (!where) return <p className="bad">This page is served at <code>/&lt;app&gt;/mandala/tokens/</code>; its URL names no app.</p>;
  let idProblem = "";
  try { register(topic); } catch (e) { idProblem = (e as Error).message; }
  const tokenTopics = (topics ?? []).filter((t) => t !== DISCOVERY);
  const discoveryOn = topics?.includes(DISCOVERY) ?? false;

  return (
    <>
      <h1>Tokens on this overlay</h1>
      <p className="mut small">The overlay serves only the topics registered with it: <code>tm_&lt;txid&gt;</code> for a token deployed at output 0, <code>tm_&lt;txid&gt;_&lt;vout&gt;</code> for a BRC-161 token at another output. The deploy page shows the topic of a new token. Changing it is the owner's: a message from your wallet to the box <code>{where.app}/register</code> of <code>{where.base}</code>.</p>
      {status !== "connected" && <p className="mut">Connect the owner's wallet.</p>}
      {readErr && <p className="status bad">The list: <Ids text={readErr} /></p>}
      {inst && (
        <>
          <div className="card">
            <h2>Register a topic</h2>
            <form className="row" onSubmit={(e) => { e.preventDefault(); if (!idProblem) void run("register", register(topic)); }}>
              <input type="text" value={topic} onChange={(e) => setTopic(e.target.value)} placeholder="tm_<txid>" />
              <button type="submit" className="go" disabled={!!busy || !!idProblem}>{busy === "register" ? "Registering…" : "Register"}</button>
            </form>
            {topic && idProblem && <p className="mut small">{idProblem}</p>}
          </div>
          <div className="card">
            <h2>Registered tokens</h2>
            {topics === undefined ? <p className="mut small">{readErr ? "Not read." : "Reading…"}</p> : tokenTopics.length === 0 ? <p className="mut small">None.</p> : (
              <table>
                <thead><tr><th>topic</th><th></th></tr></thead>
                <tbody>
                  {tokenTopics.map((t) => (
                    <tr key={t}>
                      <td><Id value={t} /></td>
                      <td>
                        <button type="button" disabled={!!busy} onClick={() => void resubmit(t)} title="The token's deploy, from the discovery lookup or your wallet, submitted under this topic">{busy === `submit:${t}` ? "Submitting…" : "Submit deploy to this overlay"}</button>{" "}
                        <button type="button" disabled={!!busy} onClick={() => void run(t, deregister(t))}>{busy === t ? "Deregistering…" : "Deregister"}</button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
          <div className="card">
            <h2>Discovery</h2>
            <label className="inline">
              <input type="checkbox" checked={discoveryOn} disabled={!!busy || topics === undefined} onChange={(e) => void run("discovery", discovery(e.target.checked))} />
              Serve <code>{DISCOVERY}</code>: every token's deploy output, so the metadata each token was deployed with can be found (lookup <code>ls_mandala_deploys</code>).
            </label>
          </div>
          <div className="card">
            <h2>Market and validator</h2>
            <p className="mut small">Two settings of this overlay, yours to turn on or off; each is a message to <code>{where.app}/register</code>, and applies to every registered token at once.</p>
            <label className="inline">
              <input type="checkbox" checked={!!roles?.market} disabled={!!busy || roles === undefined} onChange={(e) => void switchRole("market", e.target.checked)} />
              Market: keep who is validating each registered token (the beats on <code>tm_&lt;txid&gt;-live</code>{roles?.market ? <>, a window of {roles.market.window / 1000} s</> : null}).
            </label>
            <label className="inline">
              <input type="checkbox" checked={!!roles?.validator} disabled={!!busy || roles === undefined} onChange={(e) => void switchRole("validator", e.target.checked)} />
              Validator: beat on each registered token's <code>tm_&lt;txid&gt;-live</code>{roles?.validator ? <>, every {roles.validator.every / 1000} s</> : null}, and sign for it.
            </label>
          </div>
          {busy && <p className="status wait">{busy.startsWith("submit:") || busy.endsWith(":submit") ? "Submitting the deploy…" : "Sent; waiting for the answer…"}</p>}
          {note && <p className={`status ${note.ok ? "ok" : "bad"}`}><Ids text={note.text} /></p>}
        </>
      )}
    </>
  );
}

function rolesText(r: Roles): string {
  const on = [r.market && `market (window ${r.market.window / 1000} s)`, r.validator && `validator (a beat every ${r.validator.every / 1000} s)`].filter(Boolean);
  return on.length ? on.join(", ") : "neither";
}

mount("Tokens", <TokensPage />);
