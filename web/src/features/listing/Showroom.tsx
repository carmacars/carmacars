'use client';
import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { staffDo, staffRead } from '@/server/actions/staff-tools';
import { PlateCarry } from './PlateCarry';

// Release 35 (0990): the showroom scene of the outside photos (features/listing/showroom.ts). On a listing: "Apply showroom
// to this car" puts every outside photo of the car in the dark showroom; under a photo in the showroom, how it was made (the
// image model, or the free showroom and why), "Redo" and "Back to the original". On the listings page (Admin and fleet): every
// car at once. The same buttons in the Admin portal and the staff portal (fleet, customer service).
type Res = { ok: boolean; text: string } | null;
const Note = ({ r }: { r: Res }) => (r ? <p className={`alert ${r.ok ? 'alert--ok' : 'alert--error'}`} role={r.ok ? 'status' : 'alert'}><span>{r.text}</span></p> : null);
const madeAgain = (n: number) => `${n} outside photo${n === 1 ? ' is' : 's are'} being made in the showroom. When ready, check the plates where asked: a car that stayed where it was keeps its plate cover, put back by itself while the listings page is open.`;

export function ShowroomCar({ vehicle, studio }: { vehicle: string; studio: number }) {
  const router = useRouter();
  const [sure, setSure] = useState(false);
  const [res, setRes] = useState<Res>(null);
  const [pending, start] = useTransition();
  if (!studio && !res) return null;
  return (
    <div className="stack" data-testid="showroom-car">
      {!sure
        ? <p className="row"><button className="btn btn--ghost btn--sm" type="button" disabled={pending || !studio} data-testid="showroom-apply" onClick={() => setSure(true)}>Apply showroom to this car</button>
          <span className="small muted">{studio} outside photo{studio === 1 ? ' is' : 's are'} on the black studio.</span></p>
        : <p className="row"><span className="small">Put this car&apos;s outside photos in the dark CarmaCars showroom (the model&apos;s name behind the car on the cover)? The versions before are kept: each photo has Back to the original.</span>
          <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="showroom-apply-yes" onClick={() => { setSure(false); start(async () => {
            const r = await staffDo<{ queued: number }>('photo_showroom', { action: 'apply', vehicle });
            setRes(r.ok ? { ok: true, text: r.data.queued ? madeAgain(r.data.queued) : 'Every outside photo is already in the showroom.' } : { ok: false, text: r.message });
            if (r.ok) router.refresh(); }); }}>Yes, apply</button>
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => setSure(false)}>Cancel</button></p>}
      <Note r={res} />
    </div>
  );
}

/** r43 (2690): "Redo photos with Gemini": every outside photo of the car is made again in the showroom with the image model
 *  (Gemini) as the only engine. If Gemini cannot make a photo (no key, its daily limit, a refusal, a changed car) the photo is
 *  left as it was and the step fails with the reason (the listing's steps show it): never the free showroom or Cloudflare. */
export function GeminiRedoCar({ vehicle }: { vehicle: string }) {
  const router = useRouter();
  const [sure, setSure] = useState(false);
  const [res, setRes] = useState<Res>(null);
  const [pending, start] = useTransition();
  return (
    <span className="stack" data-testid="gemini-redo-car">
      {!sure
        ? <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid="gemini-redo" onClick={() => setSure(true)}>Redo photos with Gemini</button>
        : <span className="row"><span className="small">Make this car&apos;s outside photos again in the showroom with Gemini only? A photo Gemini cannot make is left as it is, and the reason is shown. The versions before are kept.</span>
          <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="gemini-redo-yes" onClick={() => { setSure(false); start(async () => {
            const r = await staffDo<{ queued: number }>('photo_showroom', { action: 'gemini', vehicle });
            setRes(r.ok ? { ok: true, text: r.data.queued ? `${r.data.queued} outside photo${r.data.queued === 1 ? ' is' : 's are'} being made again with Gemini. Check the plates when asked.` : 'No outside photo to make again now (none, or they are being made already).' } : { ok: false, text: r.message });
            if (r.ok) router.refresh(); }); }}>Yes, redo with Gemini</button>
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => setSure(false)}>Cancel</button></span>}
      <Note r={res} />
    </span>
  );
}

type Made = { provider?: string; model?: string | null; note?: string | null } | null;
export function ShowroomPhoto({ photo }: { photo: { id: string; scene?: string | null; preset_version?: string | null; showroom?: Made } }) {
  const router = useRouter();
  const [res, setRes] = useState<Res>(null);
  const [pending, start] = useTransition();
  if (photo.scene !== 'showroom') return null;
  const s = photo.showroom;
  const act = (action: 'redo' | 'undo') => start(async () => {
    const r = await staffDo<{ queued: number; restored?: boolean; public?: boolean }>('photo_showroom', { action, photo: photo.id });
    setRes(r.ok ? { ok: true, text: action === 'redo' ? 'Being made again in the showroom.' : r.data.restored ? `Back to the version before the showroom${r.data.public ? ', on the site again' : ''}.` : 'Being made again on the black studio.' } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  return (
    <span className="lr-showroom" data-testid={`showroom-${photo.id}`}>
      <span className="ad-b ad-b--light" title={s?.note ?? undefined}>{photo.preset_version?.startsWith('studio_showroom') ? (s?.provider === 'ai' ? 'Showroom (photographed look)' : 'Showroom') : 'Showroom (being made)'}</span>
      {s?.note && <span className="small muted" data-testid={`showroom-note-${photo.id}`}>{s.note}</span>}
      <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={`showroom-redo-${photo.id}`} onClick={() => act('redo')}>Redo</button>
      <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={`showroom-undo-${photo.id}`} onClick={() => act('undo')}>Back to the original</button>
      <Note r={res} />
    </span>
  );
}

type CarryPhoto = Parameters<typeof PlateCarry>[0]['photos'][number];
/** r35 (1030): the plate cover of a photo made again where the car was, for every car, not only the one whose listing review is
 *  open: the list of photos waiting for it is read every 15 seconds while this card is on the screen and PlateCarry draws and saves
 *  each cover (the same carry-over the review does), so "every car" does not leave cars off the site until someone opens them. */
function ShowroomCarry() {
  const [photos, setPhotos] = useState<CarryPhoto[]>([]);
  useEffect(() => {
    let gone = false;
    const load = async () => { const r = await staffRead<{ photos: CarryPhoto[] }>('showroom_carry_pending'); if (!gone && r.ok) setPhotos(r.data.photos); };
    void load();
    const t = setInterval(() => void load(), 15_000);
    return () => { gone = true; clearInterval(t); };
  }, []);
  return <span data-testid="showroom-carry"><PlateCarry photos={photos} /></span>;
}

/** Every car at once (the listings page, Admin and fleet). */
export function ShowroomAll() {
  const router = useRouter();
  const [sure, setSure] = useState(false);
  const [res, setRes] = useState<Res>(null);
  const [pending, start] = useTransition();
  return (
    <div className="stack" data-testid="showroom-all">
      <ShowroomCarry />
      <p className="small">New outside photos go in the dark CarmaCars showroom by themselves. Photos made before on the black studio move with one press: every angle of a car in the same room, the model&apos;s name behind the car on the cover. Each photo keeps its version before (Back to the original on the listing).</p>
      {!sure
        ? <p><button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid="showroom-all-apply" onClick={() => setSure(true)}>Apply showroom to every car</button></p>
        : <p className="row"><span className="small">Make every car&apos;s outside photos again in the showroom? A photo whose car moves is off the site until its plate is checked again.</span>
          <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="showroom-all-yes" onClick={() => { setSure(false); start(async () => {
            const r = await staffDo<{ queued: number }>('photo_showroom', { action: 'apply', all: true });
            setRes(r.ok ? { ok: true, text: r.data.queued ? madeAgain(r.data.queued) : 'Every car is already in the showroom.' } : { ok: false, text: r.message });
            if (r.ok) router.refresh(); }); }}>Yes, every car</button>
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => setSure(false)}>Cancel</button></p>}
      <Note r={res} />
    </div>
  );
}
