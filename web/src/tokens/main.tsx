/**
 * The tokens this overlay serves: the owner's page. Reads the overlay
 * engine's registered topics (the head `<app>/topics`, through the explorer,
 * the owner's read), and changes them by the owner's `register` /
 * `deregister` messages to the app's box `<app>/register` (skein-overlay 0.7.7+).
 * After a token's topic is registered, the page submits the token's deploy
 * under it (src/overlay.ts `submitDeployToTopic`), so the topic admits its own
 * deploy; "Submit deploy" does the same on demand. The lookup and the submit
 * are POSTs, so they go signed, through the instance's BRC-104 client.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useWallet } from "@1sat/react";
import { mount } from "../shell";
import { whereOf } from "../where";
import { Instance } from "./instance";
import { appBaseOf, authFetchOf, submitDeployToTopic } from "../overlay";
import { DISCOVERY, answerOf, deregister, discovery, register, topicsOf, type Call } from "./list";

const where = whereOf(location.href);

function TokensPage() {
  const { wallet, status } = useWallet();
  const inst = useMemo(() => (wallet && status === "connected" && where ? new Instance(wallet, where.base) : undefined), [wallet, status]);
  const [topics, setTopics] = useState<string[]>();
  const [readErr, setReadErr] = useState("");
  const [busy, setBusy] = useState("");
  const [note, setNote] = useState<{ ok: boolean; text: string }>();
  const [topic, setTopic] = useState("");

  const load = useCallback(async () => {
    if (!inst || !where) return;
    try { setTopics(topicsOf(await inst.head(`${where.app}/topics`))); setReadErr(""); }
    catch (e) { setTopics(undefined); setReadErr((e as Error).message); }
  }, [inst]);
  useEffect(() => { void load(); }, [load]);

  /** The token's deploy submitted under its topic: from the discovery lookup, or the wallet's copy. */
  async function submitDeploy(t: string, prefix = ""): Promise<{ ok: boolean; text: string }> {
    if (!where || !inst) return { ok: false, text: where ? "no wallet connected" : "no app" };
    try {
      const r = await submitDeployToTopic(appBaseOf(where), t, wallet ?? undefined, authFetchOf(inst.box));
      const from = r.via === "lookup" ? "from the discovery lookup" : "from your wallet (the discovery lookup had none)";
      return { ok: true, text: `${prefix}deploy submitted ${from} under ${r.topics.join(", ")}: delivery ${r.id}. The topic has it once admitted.` };
    } catch (e) { return { ok: false, text: `${prefix}deploy not submitted: ${(e as Error).message}` }; }
  }

  async function run(label: string, c: Call) {
    if (!inst || !where) return;
    setBusy(label); setNote(undefined);
    try {
      const a = answerOf(await inst.call(`${where.app}/register`, c));
      if (a.ok && a.active && c.fn === "register" && a.topic !== DISCOVERY) {
        setBusy(`${label}:submit`);
        setNote(await submitDeploy(a.topic, `${a.topic}: registered; `));
      } else {
        setNote(a.ok ? { ok: true, text: `${a.topic}: ${a.active ? "registered" : "not registered"}` } : { ok: false, text: a.message });
      }
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
      {readErr && <p className="status bad">The list: {readErr}</p>}
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
                      <td><code>{t}</code></td>
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
          {busy && <p className="status wait">{busy.startsWith("submit:") || busy.endsWith(":submit") ? "Submitting the deploy…" : "Sent; waiting for the answer…"}</p>}
          {note && <p className={`status ${note.ok ? "ok" : "bad"}`}>{note.text}</p>}
        </>
      )}
    </>
  );
}

mount("Tokens", <TokensPage />);
