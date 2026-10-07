/**
 * Deploy a token: open to anyone, a helper over the user's own wallet.
 * @1sat/actions' `deployMandala` builds the BRC-162 deploy at output 0, the
 * wallet signs and broadcasts it and files it (basket and labels
 * `mandala <txid> 0`). The page then submits the deploy to the overlay it is
 * served from under the discovery topic only (`tm_mandala`): its own topic
 * `tm_<txid>` did not exist before this transaction, so nobody serves it yet.
 * The submit is a plain `fetch`, unsigned: the skein admits an unsigned POST
 * at the overlay's `submit` row, whose filter validates the BEEF
 * (shruggr/skein#135).
 */
import { useState } from "react";
import { useWallet } from "@1sat/react";
import { createContext } from "@1sat-actions/types.js";
import { deployMandala, fileMandalaDeploy } from "@1sat-actions/mandala/deploy.js";
import { mount } from "../shell";
import { whereOf } from "../where";
import { DISCOVERY, appBaseOf, submitBeef } from "../overlay";
import { deployInput, namesOf, type DeployForm } from "./payload";
import { Id, Ids } from "../Id";

type Done = { txid: string; tx?: number[]; error?: string; submitted?: string; submitErr?: string };

const where = whereOf(location.href);

/** The deploy submitted to this overlay under the discovery topic (plain fetch, unsigned): the answer (BRC-22's STEAK, in words), or the error. */
async function submitDeploy(tx: number[] | undefined): Promise<{ submitted?: string; submitErr?: string }> {
  if (!where) return { submitErr: "this page's URL names no app, so no overlay to submit to" };
  if (!tx) return { submitErr: "the wallet returned no transaction to submit" };
  try { return { submitted: await submitBeef(appBaseOf(where), tx, [DISCOVERY]) }; }
  catch (e) { return { submitErr: (e as Error).message }; }
}

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
      if (r.txid) setDone({ txid: r.txid, tx: r.tx, error: r.error, ...(await submitDeploy(r.tx)) });
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

  async function resubmit() {
    if (!done) return;
    setBusy(true);
    setDone({ ...done, submitted: undefined, submitErr: undefined, ...(await submitDeploy(done.tx)) });
    setBusy(false);
  }

  const names = done ? namesOf(done.txid) : undefined;
  return (
    <>
      <h1>Deploy a token</h1>
      <p className="mut small">A Mandala (BRC-162) token, made by your wallet: the deploy is output 0 of a transaction your wallet signs and broadcasts, and the token's id is that output. The page then submits the deploy to this overlay's discovery topic <code>{DISCOVERY}</code>; the overlay serves the token itself once its owner registers the token's topic.</p>
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
        <label>Icon (optional): an outpoint holding the image, <code>txid.vout</code><input type="text" value={f.icon} onChange={set("icon")} /></label>
        <div className="row">
          <button type="button" className="go" disabled={status !== "connected" || busy || problem !== ""} onClick={deploy}>{busy ? "Deploying…" : "Deploy"}</button>
          {status !== "connected" ? <span className="mut small">Connect a wallet first.</span> : problem ? <span className="mut small">{problem}</span> : null}
        </div>
        {err && <p className="status bad"><Ids text={err} /></p>}
      </div>
      {done && names && (
        <div className="card">
          <h2>Deployed</h2>
          <table><tbody>
            <tr><th>transaction</th><td><Id value={done.txid} /></td></tr>
            <tr><th>token id</th><td><Id value={names.tokenId} /></td></tr>
            <tr><th>topic to register</th><td><Id value={names.topic} /></td></tr>
          </tbody></table>
          {done.error ? (
            <p className="status bad">Broadcast, not filed in your wallet: <Ids text={done.error} /> <button type="button" disabled={busy} onClick={refile}>File it again</button></p>
          ) : (
            <p className="ok small">In your wallet: basket <Id value={`mandala ${done.txid} 0`} />.</p>
          )}
          {done.submitted ? (
            <p className="ok small">Submitted to this overlay under <code>{DISCOVERY}</code>: <Ids text={done.submitted} />. The discovery topic has the deploy once admitted (lookup <code>ls_mandala_deploys</code>); if this overlay does not serve <code>{DISCOVERY}</code>, nothing admits it.</p>
          ) : done.submitErr ? (
            <p className="status bad">Not submitted to this overlay: <Ids text={done.submitErr} /> <button type="button" disabled={busy} onClick={resubmit}>Submit again</button></p>
          ) : null}
          <p className="mut small">An overlay serves the token once its owner registers the topic <Id value={names.topic} /> (<a href="../tokens/">Tokens on this overlay</a>).</p>
        </div>
      )}
    </>
  );
}

mount("Deploy a token", <DeployPage />);
