/**
 * The tokens this overlay serves: the owner's page. Reads the overlay
 * engine's registered topics (the head `<app>/topics`, through the explorer,
 * the owner's read), and changes them by the owner's `register` /
 * `deregister` messages to the app's box `<app>` (skein-overlay 0.6.0).
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useWallet } from "@1sat/react";
import { mount } from "../shell";
import { whereOf } from "../where";
import { Instance } from "./instance";
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

  async function run(label: string, c: Call) {
    if (!inst || !where) return;
    setBusy(label); setNote(undefined);
    try {
      const a = answerOf(await inst.call(where.app, c));
      setNote(a.ok ? { ok: true, text: `${a.topic}: ${a.active ? "registered" : "not registered"}` } : { ok: false, text: a.message });
    } catch (e) { setNote({ ok: false, text: (e as Error).message }); }
    setBusy("");
    await load();
  }

  if (!where) return <p className="bad">This page is served at <code>/&lt;app&gt;/mandala/tokens/</code>; its URL names no app.</p>;
  let idProblem = "";
  try { register(topic); } catch (e) { idProblem = (e as Error).message; }
  const tokenTopics = (topics ?? []).filter((t) => t !== DISCOVERY);
  const discoveryOn = topics?.includes(DISCOVERY) ?? false;

  return (
    <>
      <h1>Tokens on this overlay</h1>
      <p className="mut small">The overlay serves only the topics registered with it: <code>tm_&lt;txid&gt;</code> for a token deployed at output 0, <code>tm_&lt;txid&gt;_&lt;vout&gt;</code> for a BRC-161 token at another output. The deploy page shows the topic of a new token. Changing it is the owner's: a message from your wallet to the box <code>{where.app}</code> of <code>{where.base}</code>.</p>
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
                      <td><button type="button" disabled={!!busy} onClick={() => void run(t, deregister(t))}>{busy === t ? "Deregistering…" : "Deregister"}</button></td>
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
          {busy && <p className="status wait">Sent; waiting for the answer…</p>}
          {note && <p className={`status ${note.ok ? "ok" : "bad"}`}>{note.text}</p>}
        </>
      )}
    </>
  );
}

mount("Tokens", <TokensPage />);
