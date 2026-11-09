'use client';
import { useEffect, useState, useTransition } from 'react';
import { toStandardImage } from '@/features/uploads/standard-image';
import { DateInput } from '@/components/DateInput';
import { renterAccidentMedia, renterAccidentReport, type AccidentSent } from '@/server/actions/accident';
import { draftPayload, draftProblem, emptyDraft, type AccidentDraft } from './report';

// Report an accident (release 35, migration 0912), from the accident card on the renter's booking while they have the car.
// Phone first: big fields one under the other; the draft is kept on this phone as they type (a reload or a lost signal keeps
// it); each photo or video uploads as it is picked. Sent, it opens the incident staff work, alerts Admin and Fleet at once,
// and shows the next steps with our phone number.
const KEY = (b: string) => `cc-accident-draft:${b}`;
type Media = AccidentDraft['media'][number];

async function upload(booking: string, f: File): Promise<Media> {
  const blob = f.type.startsWith('image/') ? await toStandardImage(f) : f;
  const fd = new FormData();
  fd.append('file', blob, f.name || 'file'); fd.append('booking', booking);
  const r = await fetch('/api/accident-media', { method: 'POST', body: fd });
  const j = (await r.json().catch(() => ({}))) as { ok?: boolean; bucket?: string; path?: string; video?: boolean; message?: string };
  if (!j.ok || !j.path) throw new Error(j.message ?? 'The file could not be uploaded.');
  return { bucket: j.bucket ?? 'condition-photos', path: j.path, video: !!j.video, name: f.name || 'file' };
}

function YesNo({ id, label, value, set }: { id: string; label: string; value: '' | 'yes' | 'no'; set: (v: 'yes' | 'no') => void }) {
  return (
    <fieldset className="field" data-testid={id}><legend className="label">{label}</legend>
      <div className="row" style={{ gap: 'var(--s-2)' }}>
        {(['yes', 'no'] as const).map((v) => <label key={v} className="check"><input type="radio" name={id} checked={value === v} onChange={() => set(v)} /> <span>{v === 'yes' ? 'Yes' : 'No'}</span></label>)}
      </div></fieldset>
  );
}

export function AccidentReport({ booking, number, phone }: { booking: string; number: string; phone: string | null }) {
  const [open, setOpen] = useState(false);
  const [d, setD] = useState<AccidentDraft>(emptyDraft());
  const [busy, setBusy] = useState(0);
  const [err, setErr] = useState<string | null>(null);
  const [sent, setSent] = useState<AccidentSent | null>(null);
  const [pending, start] = useTransition();
  // the draft on this phone only, read once and written as it changes
  const begin = () => {
    try { const x = localStorage.getItem(KEY(booking)); if (x) setD({ ...emptyDraft(), ...(JSON.parse(x) as Partial<AccidentDraft>) }); } catch { /* no storage */ }
    setOpen(true);
  };
  useEffect(() => { if (!open || sent) return; try { localStorage.setItem(KEY(booking), JSON.stringify(d)); } catch { /* no storage */ } }, [d, open, sent, booking]);
  const set = (patch: Partial<AccidentDraft>) => setD((x) => ({ ...x, ...patch }));

  async function addFiles(files: FileList | null) {
    if (!files?.length) return;
    setErr(null);
    const list = Array.from(files).slice(0, 20);
    setBusy((n) => n + list.length);
    const got: Media[] = [];
    await Promise.all(list.map(async (f) => { try { got.push(await upload(booking, f)); } catch (e) { setErr(e instanceof Error ? e.message : 'A file could not be uploaded.'); } finally { setBusy((n) => n - 1); } }));
    if (sent) { const r = await renterAccidentMedia(number, sent.incident_id, got); if (!r.ok) setErr(r.message); else setSent({ ...sent, media: sent.media + r.data.added }); }
    else setD((x) => ({ ...x, media: [...x.media, ...got] }));
  }
  function locate() {
    if (!navigator.geolocation) { setErr('This phone does not give its location: type the place.'); return; }
    navigator.geolocation.getCurrentPosition((p) => set({ latitude: Number(p.coords.latitude.toFixed(6)), longitude: Number(p.coords.longitude.toFixed(6)) }),
      () => setErr('The location was not shared: type the place.'), { timeout: 10_000 });
  }
  const send = () => start(async () => {
    setErr(null);
    const problem = draftProblem(d);
    if (problem) { setErr(problem); return; }
    const r = await renterAccidentReport(number, draftPayload(booking, d));
    if (!r.ok) { setErr(r.message); return; }
    setSent(r.data);
    try { localStorage.removeItem(KEY(booking)); } catch { /* no storage */ }
  });

  const tel = (n: string | null) => (n ? `tel:${n.replace(/[^\d+]/g, '')}` : undefined);
  if (sent) return (
    <div className="pt-ok stack" role="status" data-testid="accident-sent">
      <h3 className="d4">Report {sent.incident_number} sent</h3>
      <ol className="small">
        {sent.anyone_hurt && <li>Someone is hurt: call 911 first if you have not.</li>}
        <li>Our team has it now and calls you. You can call us too{sent.phone ? `: ${sent.phone}` : ''}.</li>
        {!sent.drivable && <li>Do not drive the car. Stay safe; we arrange the tow.</li>}
        <li>Keep the other driver&apos;s details and the police report number.</li>
        <li>Send any more photos or videos below within {sent.report_hours} hours.</li>
      </ol>
      {sent.phone && <p><a className="btn btn--primary" href={tel(sent.phone)} data-testid="accident-call">Call us {sent.phone}</a></p>}
      <div className="field"><label className="label" htmlFor="acc-more">Add more photos or videos ({sent.media} sent)</label>
        <input className="input" id="acc-more" type="file" accept="image/*,video/*" multiple onChange={(e) => { void addFiles(e.target.files); e.target.value = ''; }} /></div>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </div>
  );
  if (!open) return <p><button className="btn btn--primary" type="button" onClick={begin} data-testid="accident-report-open">Report an accident</button>{phone && <> <a className="btn btn--ghost" href={tel(phone)}>Call us</a></>}</p>;
  return (
    <form className="stack" data-testid="accident-report" onSubmit={(e) => { e.preventDefault(); send(); }}>
      <p className="small">Anyone hurt? Call 911 first. Your answers are kept on this phone as you type until you send them.</p>
      <div className="field"><label className="label" htmlFor="acc-what">What happened</label>
        <textarea className="textarea" id="acc-what" required maxLength={4000} value={d.description} onChange={(e) => set({ description: e.target.value })} data-testid="accident-what" /></div>
      <div className="field"><label className="label" htmlFor="acc-when">When (leave empty for now)</label>
        <DateInput className="input" id="acc-when" type="datetime-local" value={d.occurred_at} onChange={(e) => set({ occurred_at: e.target.value })} /></div>
      <div className="field"><label className="label" htmlFor="acc-where">Where</label>
        <input className="input" id="acc-where" value={d.place} placeholder="Street, intersection or address" onChange={(e) => set({ place: e.target.value })} />
        <p className="small"><button className="btn btn--ghost btn--sm" type="button" onClick={locate} data-testid="accident-locate">Use my location</button>{d.latitude !== null ? ' Location added.' : ''}</p></div>
      <div className="field"><label className="label" htmlFor="acc-media">Photos and videos (from the camera roll)</label>
        <input className="input" id="acc-media" type="file" accept="image/*,video/*" multiple onChange={(e) => { void addFiles(e.target.files); e.target.value = ''; }} data-testid="accident-media" />
        <p className="small muted">{d.media.length} added{busy ? `, uploading ${busy}` : ''}. All the cars, the plates, the damage and the scene.</p></div>
      <fieldset className="stack"><legend className="label">The other party (if any)</legend>
        <input className="input" aria-label="Their name" placeholder="Name" value={d.other_name} onChange={(e) => set({ other_name: e.target.value })} />
        <input className="input" aria-label="Their phone" placeholder="Phone" inputMode="tel" value={d.other_phone} onChange={(e) => set({ other_phone: e.target.value })} />
        <input className="input" aria-label="Their plate" placeholder="Plate" value={d.other_plate} onChange={(e) => set({ other_plate: e.target.value })} />
        <input className="input" aria-label="Their coverage" placeholder="Their insurer and policy number" value={d.other_coverage} onChange={(e) => set({ other_coverage: e.target.value })} />
      </fieldset>
      <div className="field"><label className="label" htmlFor="acc-police">Police report number (if any)</label>
        <input className="input" id="acc-police" value={d.police} onChange={(e) => set({ police: e.target.value })} /></div>
      <YesNo id="accident-hurt" label="Is anyone hurt?" value={d.anyone_hurt} set={(v) => set({ anyone_hurt: v })} />
      <YesNo id="accident-drivable" label="Can the car be driven?" value={d.drivable} set={(v) => set({ drivable: v })} />
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      <button className="btn btn--primary" type="submit" disabled={pending || busy > 0} data-testid="accident-send">{pending ? 'Sending' : busy ? 'Uploading' : 'Send the report'}</button>
    </form>
  );
}
