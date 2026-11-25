'use client';
import { useEffect, useRef, useState, useTransition, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { PackageSignForm } from '@/features/signing/PackageSignForm';
import { companyDocumentFields, companyDocumentRetry, companyDocumentSign } from '@/server/actions/company-documents';
import { fieldLabel } from '@/features/company-documents/model';

// Admin > Company documents > one document (r50, migration 5060): the fill-ins (until the first signature), and signing.

/** The fill-ins of a version: complete, it is rendered and sent to the signers. */
export function CompanyDocFields({ document, version, keys, values, sent }: { document: string; version: string; keys: string[]; values: Record<string, string>; sent: boolean }) {
  const router = useRouter();
  const [v, setV] = useState<Record<string, string>>(() => Object.fromEntries(keys.map((k) => [k, values[k] ?? ''])));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const missing = keys.filter((k) => !v[k]?.trim());
  const save = () => run(async () => {
    setMsg(null);
    const r = await companyDocumentFields(document, version, v);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: r.data.sent ? 'Saved and sent: each signer is asked to sign.' : `Saved. Still to fill in: ${r.data.missing.map(fieldLabel).join(', ')}.` });
    router.refresh();
  });
  return (
    <form className="stack" onSubmit={(e) => { e.preventDefault(); save(); }} data-testid="cdoc-fields">
      {sent && <p className="small muted">Already sent for signing. Saving a change withdraws the requests and sends the new text to everyone again.</p>}
      <div className="ad-grid ad-grid--2">{keys.map((k) => (
        <label key={k} className="field"><span className="label">{fieldLabel(k)}</span>
          <input className="input" value={v[k] ?? ''} maxLength={2000} onChange={(e) => setV((x) => ({ ...x, [k]: e.target.value }))} data-testid={`cdoc-field-${k}`} /></label>))}</div>
      <p className="ad-actions"><button type="submit" className="btn btn--primary btn--sm" disabled={pending} aria-busy={pending || undefined} data-testid="cdoc-fields-save">
        {pending ? 'Saving' : missing.length ? 'Save the fill-ins' : 'Save and send for signing'}</button></p>
      {msg && <p className={msg.ok ? 'small' : 'error'} role={msg.ok ? 'status' : 'alert'} data-testid="cdoc-fields-msg">{msg.text}</p>}
    </form>
  );
}

/** Send again, or file the signed copy again, when that step failed. */
export function CompanyDocRetry({ document, version, what, label }: { document: string; version: string; what: 'send' | 'signed_copy'; label: string }) {
  const router = useRouter();
  const [err, setErr] = useState<string | null>(null);
  const [pending, run] = useTransition();
  return (<span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}>
    <button type="button" className="btn btn--ghost btn--sm" disabled={pending} aria-busy={pending || undefined} data-testid={`cdoc-retry-${what}`}
      onClick={() => run(async () => { setErr(null); const r = await companyDocumentRetry(document, version, what); if (!r.ok) setErr(r.message); else router.refresh(); })}>{pending ? 'Working' : label}</button>
    {err && <span className="error small" role="alert">{err}</span>}</span>);
}

/** The document in a box read to the end, the tick, then the platform's signing steps. */
export function CompanyDocSign({ document, version, request, sha, title, signerName, role, children }: {
  document: string; version: string; request: string; sha: string; title: string; signerName: string; role: string; children: ReactNode;
}) {
  const box = useRef<HTMLDivElement>(null);
  const [read, setRead] = useState(false);
  const [ack, setAck] = useState(false);
  const onScroll = () => { const b = box.current; if (b && b.scrollTop + b.clientHeight >= b.scrollHeight - 24) setRead(true); };
  // a document short enough to show whole is read without scrolling
  useEffect(onScroll, []);
  return (
    <div className="stack-lg">
      <div ref={box} className="cdoc-read" tabIndex={0} role="region" aria-label={`${title}: read to the end`} onScroll={onScroll} data-testid="cdoc-read"
        style={{ maxHeight: '60dvh', overflowY: 'auto', padding: 'var(--s-3)', border: '1px solid var(--grey-200)', borderRadius: 'var(--ui-r-tile)' }}>
        {children}
        <p className="small muted">End of the document.</p>
      </div>
      <label className="check"><input type="checkbox" checked={ack} disabled={!read} onChange={(e) => setAck(e.target.checked)} data-testid="cdoc-ack" />
        <span>I have read it and had the chance to get legal advice.{!read && <span className="muted"> Scroll to the end of the document first.</span>}</span></label>
      {ack && <PackageSignForm docs={[{ key: request, title }]} signerName={signerName} button={`Sign as ${role}`} testId="cdoc-sign-form"
        consent="By pressing Sign you sign this document electronically, with the same effect as signing on paper. We record the time, your IP address and device, and the document's SHA-256 with your signature."
        esign={{ kind: 'documents', role: 'staff', docs: [{ kind: 'request', ref: request, sha, title }] }}
        action={(input) => companyDocumentSign({ document, version, request, sha, acknowledged: ack }, input)} />}
    </div>
  );
}
