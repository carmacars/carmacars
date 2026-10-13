'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { fieldAct } from '@/server/actions/field';
import { preparePhoto, uploads } from './queue';

// The field report (06-field.md section 9): a car of today's jobs, what happened, details, photos (up to 10;
// required for damage), and for a collision whether anyone is hurt (yes: "Call 911 now" above everything).
const WHAT: Array<[string, string]> = [['new_damage', 'New damage found'], ['warning_light', 'Warning light'], ['collision', 'Collision while I was driving'],
  ['ticket_or_toll', 'Ticket or toll while I was driving'], ['lost_property', 'Lost property found'], ['other', 'Something else']];

export function FieldReport({ vehicles }: { vehicles: Array<{ id: string; name: string; job: string }> }) {
  const router = useRouter();
  const [vehicle, setVehicle] = useState(vehicles[0]?.id ?? '');
  const [what, setWhat] = useState('');
  const [details, setDetails] = useState('');
  const [hurt, setHurt] = useState<boolean | null>(null);
  const [photos, setPhotos] = useState<string[]>([]);
  const [sending, setSending] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const job = vehicles.find((v) => v.id === vehicle)?.job ?? '';
  const add = async (files: FileList | null) => {
    if (!files?.length || !job) return;
    setSending(true);
    try {
      for (const f of Array.from(files).slice(0, 10 - photos.length)) {
        const p = await preparePhoto(f);
        const k = await uploads.addAndWait({ job, seq: 700 + photos.length, shot: 'report', mode: 'raw', blob: p.blob, taken_at: new Date().toISOString(), width: p.width, height: p.height, flags: p.flags });
        setPhotos((x) => [...x, k]);
      }
    } catch (e) { setMsg({ ok: false, text: e instanceof Error ? e.message : 'The photo could not be sent.' }); } finally { setSending(false); }
  };
  if (!vehicles.length) return <p className="pt-empty">A report is made on a car of one of your jobs. You have none in the last two days or the next 36 hours.</p>;
  if (msg?.ok) return <p className="alert alert--ok" role="status" data-testid="report-sent"><span>{msg.text}</span></p>;
  return (
    <form className="stack" noValidate data-testid="field-report" onSubmit={(e) => { e.preventDefault(); start(async () => {
      const r = await fieldAct('report', { vehicle, what, details: details.trim(), anyone_hurt: what === 'collision' ? hurt === true : null, photos });
      setMsg(r.ok ? { ok: true, text: 'Sent. Fleet has it now; for a collision an Admin is told at once.' } : { ok: false, text: r.message });
      if (r.ok) router.refresh();
    }); }}>
      {what === 'collision' && hurt && <p className="fd-911" role="alert">Call 911 now. Then call CarmaCars.</p>}
      <label className="field"><span className="label">Car</span><select className="select" value={vehicle} onChange={(e) => setVehicle(e.target.value)}>{vehicles.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label>
      <fieldset className="fd-form"><legend className="label">What happened</legend>
        <div className="fd-pick fd-pick--stack">{WHAT.map(([k, l]) => <button key={k} type="button" className={`btn ${what === k ? 'btn--primary' : 'btn--ghost'}`} aria-pressed={what === k} onClick={() => setWhat(k)} data-testid={`what-${k}`}>{l}</button>)}</div></fieldset>
      {what === 'collision' && <fieldset className="fd-form"><legend className="label">Is anyone hurt?</legend>
        <div className="fd-pick"><button type="button" className={`btn ${hurt === true ? 'btn--primary ad-btn--danger' : 'btn--ghost'}`} aria-pressed={hurt === true} onClick={() => setHurt(true)}>Yes</button>
          <button type="button" className={`btn ${hurt === false ? 'btn--primary' : 'btn--ghost'}`} aria-pressed={hurt === false} onClick={() => setHurt(false)}>No</button></div></fieldset>}
      <label className="field"><span className="label">Details</span><textarea className="textarea" value={details} onChange={(e) => setDetails(e.target.value)} minLength={10} maxLength={2000} data-testid="report-details" /></label>
      <div className="stack"><p className="small">{photos.length} photo(s){what === 'new_damage' ? '; at least one for damage' : ''}.</p>
        <label className="btn btn--ghost fd-wide">{sending ? 'Sending' : 'Take a photo'}<input className="vh" type="file" accept="image/*" capture="environment" multiple onChange={(e) => { void add(e.target.files); e.target.value = ''; }} data-testid="report-photo" /></label></div>
      {msg && !msg.ok && <p className="alert alert--error" role="alert"><span>{msg.text}</span></p>}
      <button className="btn btn--primary fd-wide" type="submit" disabled={pending || sending || !what || details.trim().length < 10} data-testid="report-send">{pending ? 'Sending' : 'Send the report'}</button>
    </form>
  );
}
