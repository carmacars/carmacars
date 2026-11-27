'use client';
import { useState } from 'react';
import { PHOTO_ACCEPT } from '@/features/uploads/formats';
import { pickedTime, useUploads, type Kind } from './useUploads';
import { UploadList } from './UploadList';

// Add old photos to one booking (5185): pick the check-in or the check-out, then many photos from the phone at once. Each
// keeps the time it was taken (EXIF); they upload in the background and land on that report "added later by" this person.
export function OneBooking({ booking, kinds, counts }: { booking: string; kinds: Kind[]; counts: Record<Kind, number> }) {
  const [kind, setKind] = useState<Kind | null>(kinds.length === 1 ? kinds[0]! : null);
  const [reading, setReading] = useState(false);
  const up = useUploads();
  async function pick(files: FileList | null) {
    if (!files?.length || !kind) return;
    setReading(true);
    const list = Array.from(files);
    const timed = await Promise.all(list.map(async (file) => ({ file, at: await pickedTime(file) })));
    setReading(false);
    up.add(timed, booking, kind);
  }
  return (
    <div className="op-stack" data-testid="op-one">
      <fieldset className="op-choose">
        <legend className="op-h3">Which photos are these?</legend>
        <div className="op-seg">
          {(['pickup', 'return'] as const).map((k) => (
            <button key={k} type="button" aria-pressed={kind === k} disabled={!kinds.includes(k)} aria-describedby={`op-kind-${k}-hint`} onClick={() => setKind(k)} data-testid={`op-kind-${k}`}>
              <b>{k === 'pickup' ? 'Check-in' : 'Check-out'}</b>
              <span id={`op-kind-${k}-hint`}>{!kinds.includes(k) ? (k === 'return' ? 'Not back yet' : 'Too long ago') : `${counts[k]} photo${counts[k] === 1 ? '' : 's'} on it now`}</span>
            </button>))}
        </div>
      </fieldset>
      <label className={`op-drop${kind ? '' : ' is-off'}`} data-testid="op-pick">
        <input type="file" accept={PHOTO_ACCEPT} multiple disabled={!kind || reading} onChange={(e) => { void pick(e.target.files); e.target.value = ''; }} data-testid="op-pick-input" />
        <b>{reading ? 'Reading the photos' : kind ? `Choose ${kind === 'pickup' ? 'check-in' : 'check-out'} photos` : 'Choose the check-in or the check-out first'}</b>
        <span>Pick as many as you have from the camera roll. HEIC is fine. The time each was taken is kept.</span>
      </label>
      <UploadList {...up} />
    </div>
  );
}
