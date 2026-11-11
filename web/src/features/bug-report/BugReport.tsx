'use client';
import './bug-report.css';
import { useEffect, useId, useRef, useState } from 'react';
import { usePathname } from 'next/navigation';
import { installBugRing, bugRingEntries } from './install';
import { capturePage, captureScreen } from './capture';
import { MAX_SHOTS, MAX_SHOT_BYTES, MIN_HAPPENED, SEVERITIES, type Severity } from './logs';

// Release 37 (2340): "Report a bug" in the frame of the Admin portal and every staff portal (office and field). Pressing it
// takes a picture of the page first (masked: capture.ts), then opens the form: what happened (30 characters at least), what
// was expected, the steps, how bad it is, and more pictures (choose or paste). The page, the browser, the build and the
// last 50 errors and failed calls (install.ts, redacted) go with it. The Admins see it in Admin > Bug reports; the
// reporter sees its status in My bug reports.
type Pic = { blob: Blob; url: string; auto: boolean };

export function BugReportButton({ portal, mineHref }: { portal: 'admin' | 'staff' | 'field'; mineHref: string }) {
  const pathname = usePathname();
  const dlg = useRef<HTMLDialogElement>(null);
  const idp = useId();
  const [busy, setBusy] = useState<'capture' | 'send' | null>(null);
  const [pics, setPics] = useState<Pic[]>([]);
  const [happened, setHappened] = useState('');
  const [expected, setExpected] = useState('');
  const [steps, setSteps] = useState('');
  const [severity, setSeverity] = useState<Severity | ''>('');
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState<string | null>(null);

  const [canScreen, setCanScreen] = useState(false);
  const live = useRef<Pic[]>([]);
  useEffect(() => { live.current = pics; }, [pics]);
  useEffect(() => { installBugRing(); return () => live.current.forEach((p) => URL.revokeObjectURL(p.url)); }, []);
  const drop = (i: number) => setPics((x) => { const gone = x[i]; if (gone) URL.revokeObjectURL(gone.url); return x.filter((_, j) => j !== i); });
  const fieldPortal = portal === 'field' || pathname?.startsWith('/staff/field');

  const add = (blob: Blob | null, auto = false) => {
    if (!blob) return;
    if (!/^image\/(png|jpeg|webp)$/.test(blob.type)) { setError('Pictures must be PNG, JPEG or WebP images.'); return; }
    if (blob.size > MAX_SHOT_BYTES) { setError('Each picture must be under 5 MB.'); return; }
    setPics((p) => (p.length >= MAX_SHOTS ? p : [...p, { blob, url: URL.createObjectURL(blob), auto }]));
  };

  async function open() {
    setError(null); setSent(null);
    setBusy('capture');
    const shot = await capturePage();
    setBusy(null);
    setCanScreen(!!navigator.mediaDevices && 'getDisplayMedia' in navigator.mediaDevices);
    pics.forEach((p) => URL.revokeObjectURL(p.url));
    setPics([]);
    if (shot) add(shot, true);
    dlg.current?.showModal();
  }

  async function grabScreen() {
    dlg.current?.close();
    const shot = await captureScreen();
    dlg.current?.showModal();
    if (shot) add(shot); else setError('The screen was not captured. Choose a picture instead.');
  }

  async function send(e: React.FormEvent) {
    e.preventDefault();
    if (happened.trim().length < MIN_HAPPENED) { setError(`Describe what happened in at least ${MIN_HAPPENED} characters.`); return; }
    if (!severity) { setError('Choose how bad it is.'); return; }
    setBusy('send'); setError(null);
    const fd = new FormData();
    fd.set('report', JSON.stringify({
      happened, expected, steps, severity, portal: fieldPortal ? 'field' : portal, page: window.location.pathname + window.location.search, auto_shot: pics[0]?.auto === true,
      logs: bugRingEntries(),
      context: { viewport: `${window.innerWidth}x${window.innerHeight}`, screen: `${window.screen?.width ?? 0}x${window.screen?.height ?? 0}`, dpr: window.devicePixelRatio,
        device: /Mobi|Android|iPhone|iPad/i.test(navigator.userAgent) ? 'phone or tablet' : 'computer', browser: navigator.userAgent,
        platform: (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData?.platform ?? navigator.platform, language: navigator.language,
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone, online: navigator.onLine, title: document.title, tab: new URLSearchParams(window.location.search).get('tab') ?? '',
        capture: pics[0]?.auto ? 'page' : pics.length ? 'upload' : 'none' }
    }));
    pics.forEach((p, i) => fd.append('shot', p.blob, `shot-${i + 1}.${p.blob.type.split('/')[1]}`));
    try {
      const res = await fetch('/api/bug-report', { method: 'POST', body: fd });
      const j = (await res.json().catch(() => ({}))) as { ok?: boolean; message?: string; data?: { number?: string } };
      if (!res.ok || !j.ok) { setError(j.message ?? 'The report was not sent. Try again.'); return; }
      setSent(j.data?.number ?? 'your report');
      setHappened(''); setExpected(''); setSteps(''); setSeverity(''); pics.forEach((p) => URL.revokeObjectURL(p.url)); setPics([]);
    } catch { setError('The report was not sent (no connection). Try again.'); } finally { setBusy(null); }
  }

  return (
    <>
      <button type="button" className="btn btn--quiet btn--sm hd-act" title="Report a bug" onClick={open} disabled={busy === 'capture'} data-testid="bug-report-open" data-bug-report-ui>
        <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M8 9a4 4 0 0 1 8 0v5a4 4 0 0 1-8 0z" /><path d="M12 9v9M4 13h4M16 13h4M5 7l3 2M19 7l-3 2M5 19l3-2M19 19l-3-2M10 5l-1-2M14 5l1-2" /></svg>
        <span className="hd-lbl">{busy === 'capture' ? 'Capturing…' : 'Report a bug'}</span>
      </button>
      <dialog ref={dlg} className="ad-dialog ad-dialog--wide br-dialog" aria-labelledby={`${idp}-t`} data-testid="bug-report-dialog" data-bug-report-ui
        onPaste={(e) => { for (const it of Array.from(e.clipboardData.items)) if (it.kind === 'file') add(it.getAsFile()); }}>
        {sent ? (
          <div className="stack">
            <h2 id={`${idp}-t`}>Thank you: {sent} is sent</h2>
            <p>The Admins see it with the page, your browser and its last errors. {severity === 'blocks_work' ? 'They are alerted now.' : ''} You can follow its status in My bug reports.</p>
            <p className="br-actions"><a className="btn btn--sm" href={mineHref} data-testid="bug-report-mine">My bug reports</a><button type="button" className="btn btn--sm btn--primary" onClick={() => dlg.current?.close()}>Close</button></p>
          </div>
        ) : (
          <form className="stack" onSubmit={send} data-testid="bug-report-form">
            <h2 id={`${idp}-t`}>Report a bug</h2>
            <p className="small muted">This page, your browser and its recent errors are attached. Passwords and card fields are hidden in the picture.</p>
            <label className="field"><span>What happened? <b aria-hidden="true">*</b></span>
              <textarea className="input ad-textarea" required minLength={MIN_HAPPENED} maxLength={4000} rows={4} value={happened} onChange={(e) => setHappened(e.target.value)} data-testid="bug-report-happened"
                placeholder="What you did, what you saw (an error message, a wrong number, a button that does nothing)" />
              <span className="small muted">{happened.trim().length < MIN_HAPPENED ? `${MIN_HAPPENED - happened.trim().length} more characters` : 'Thank you'}</span></label>
            <label className="field"><span>What did you expect?</span>
              <textarea className="input ad-textarea" rows={2} maxLength={2000} value={expected} onChange={(e) => setExpected(e.target.value)} data-testid="bug-report-expected" /></label>
            <label className="field"><span>Steps to make it happen again (optional)</span>
              <textarea className="input ad-textarea" rows={3} maxLength={4000} value={steps} onChange={(e) => setSteps(e.target.value)} placeholder={'1. Open ...\n2. Press ...'} data-testid="bug-report-steps" /></label>
            <fieldset className="field br-sev"><legend>How bad is it? <b aria-hidden="true">*</b></legend>
              {SEVERITIES.map(([k, l]) => (
                <label key={k} className="br-sev__opt"><input type="radio" name="severity" value={k} checked={severity === k} onChange={() => setSeverity(k)} required data-testid={`bug-report-sev-${k}`} /> {l}</label>
              ))}
            </fieldset>
            <div className="field"><span>Pictures ({pics.length} of {MAX_SHOTS})</span>
              <ul className="br-pics">{pics.map((p, i) => (
                // eslint-disable-next-line @next/next/no-img-element
                <li key={p.url}><img src={p.url} alt={p.auto ? 'Picture of this page' : `Picture ${i + 1}`} /><button type="button" className="btn btn--quiet btn--sm" onClick={() => drop(i)}>Remove</button></li>
              ))}</ul>
              <p className="br-actions">
                <label className="btn btn--sm">Add a picture<input type="file" accept="image/png,image/jpeg,image/webp" multiple hidden onChange={(e) => { Array.from(e.target.files ?? []).forEach((f) => add(f)); e.target.value = ''; }} data-testid="bug-report-file" /></label>
                {canScreen ? <button type="button" className="btn btn--sm btn--quiet" onClick={grabScreen}>Capture my screen</button> : null}
                <span className="small muted">or paste one here</span>
              </p>
            </div>
            {error ? <p className="err" role="alert" data-testid="bug-report-error">{error}</p> : null}
            <p className="br-actions">
              <button type="button" className="btn btn--sm btn--quiet" onClick={() => dlg.current?.close()}>Cancel</button>
              <a className="btn btn--sm btn--quiet" href={mineHref}>My bug reports</a>
              <button type="submit" className="btn btn--sm btn--primary" disabled={busy === 'send'} data-testid="bug-report-send">{busy === 'send' ? 'Sending…' : 'Send report'}</button>
            </p>
          </form>
        )}
      </dialog>
    </>
  );
}
