/**
 * Deploy a token: open to anyone, a helper over the user's own wallet.
 * @1sat/actions' `deployMandala` builds the BRC-162 deploy at output 0, the
 * wallet signs and broadcasts it and files it (basket and labels
 * `mandala <txid> 0`). Nothing is sent to the overlay.
 */
import { useState } from "react";
import { useWallet } from "@1sat/react";
import { createContext } from "@1sat-actions/types.js";
import { deployMandala, fileMandalaDeploy } from "@1sat-actions/mandala/deploy.js";
import { mount } from "../shell";
import { deployInput, namesOf, type DeployForm } from "./payload";

type Done = { txid: string; tx?: number[]; error?: string };

function DeployPage() {
  const { wallet, status } = useWallet();
  const [f, setF] = useState<DeployForm>({ symbol: "", decimals: "0", supply: "fixed", amount: "", icon: "" });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [done, setDone] = useState<Done>();
  const set = (k: keyof DeployForm) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });

  let problem = "";
  try { deployInput(f); } catch (e) { problem = (e as Error).message; }

  async function deploy() {
    if (!wallet) return;
    setBusy(true); setErr(""); setDone(undefined);
    try {
      const r = await deployMandala.execute(createContext(wallet), deployInput(f));
      if (r.txid) setDone({ txid: r.txid, tx: r.tx, error: r.error });
      else setErr(r.error ?? "the wallet returned no transaction");
    } catch (e) { setErr((e as Error).message); }
    setBusy(false);
  }

  async function refile() {
    if (!wallet || !done) return;
    setBusy(true);
    const r = await fileMandalaDeploy.execute(createContext(wallet), { txid: done.txid, tx: done.tx });
    setDone({ ...done, error: r.error });
    setBusy(false);
  }

  const names = done ? namesOf(done.txid) : undefined;
  return (
    <>
      <h1>Deploy a token</h1>
      <p className="mut small">A Mandala (BRC-162) token, made by your wallet: the deploy is output 0 of a transaction your wallet signs and broadcasts, and the token's id is that output. Nothing is sent to an overlay; an overlay serves the token once its owner activates it.</p>
      <div className="card">
        <label>Symbol<input type="text" value={f.symbol} onChange={set("symbol")} placeholder="TOKEN" /></label>
        <label>Decimals (0 to 18)<input type="text" inputMode="numeric" value={f.decimals} onChange={set("decimals")} /></label>
        <div className="row">
          <label className="inline"><input type="radio" checked={f.supply === "fixed"} onChange={() => setF({ ...f, supply: "fixed" })} /> Fixed supply: the whole amount now, to your wallet</label>
        </div>
        <div className="row">
          <label className="inline"><input type="radio" checked={f.supply === "authority"} onChange={() => setF({ ...f, supply: "authority" })} /> Authority: no supply now; the deploy output is the authority that mints</label>
        </div>
        {f.supply === "fixed" && (
          <label>Amount, in whole tokens{Number(f.decimals) > 0 ? ` (up to ${f.decimals} decimal places)` : ""}<input type="text" inputMode="decimal" value={f.amount} onChange={set("amount")} /></label>
        )}
        <label>Icon (optional): an outpoint holding the image, <code>txid_vout</code><input type="text" value={f.icon} onChange={set("icon")} /></label>
        <div className="row">
          <button type="button" className="go" disabled={status !== "connected" || busy || problem !== ""} onClick={deploy}>{busy ? "Deploying…" : "Deploy"}</button>
          {status !== "connected" ? <span className="mut small">Connect a wallet first.</span> : problem ? <span className="mut small">{problem}</span> : null}
        </div>
        {err && <p className="status bad">{err}</p>}
      </div>
      {done && names && (
        <div className="card">
          <h2>Deployed</h2>
          <table><tbody>
            <tr><th>transaction</th><td><code>{done.txid}</code></td></tr>
            <tr><th>token id</th><td><code>{names.tokenId}</code></td></tr>
            <tr><th>topic to activate</th><td><code>{names.topic}</code></td></tr>
          </tbody></table>
          {done.error ? (
            <p className="status bad">Broadcast, not filed in your wallet: {done.error} <button type="button" disabled={busy} onClick={refile}>File it again</button></p>
          ) : (
            <p className="ok small">In your wallet: basket <code>mandala {done.txid} 0</code>.</p>
          )}
          <p className="mut small">An overlay serves the token once its owner activates the topic <code>{names.topic}</code> (<a href="../tokens/">Tokens on this overlay</a>).</p>
        </div>
      )}
    </>
  );
}

mount("Deploy a token", <DeployPage />);
