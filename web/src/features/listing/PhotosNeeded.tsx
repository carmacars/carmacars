'use client';
import Link from 'next/link';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { listingFromHandover } from '@/server/actions/listing';

// Cars on sample photos (migration 0236): each real car whose listing still shows sample photos, with what the newest
// handover photographed. "Use the handover photos" copies them into the car's listing (the studio editor then puts the
// car on the CarmaCars backdrop and the listing waits for review); otherwise field staff take them (Start a listing).
export type NeedRow = { vehicle_id: string; name: string; fleet_number: string | null; status: string; listing_status: string | null; handover_at: string | null;
  handover_shots: number; handover_required: number; intake: { id: string; state: string } | null };

export function UseHandoverPhotos({ vehicleId, shots, required }: { vehicleId: string; shots: number; required: number }) {
  const router = useRouter();
  const [pending, run] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  return (
    <span className="stack">
      <button className="btn btn--sm" type="button" disabled={pending} data-testid={`use-handover-${vehicleId}`} onClick={() => run(async () => {
        setMsg(null);
        const r = await listingFromHandover(vehicleId, ['/admin/listings']);
        if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
        setMsg({ ok: true, text: r.data.submitted ? `${r.data.copied} photos added and sent to the studio editor; the listing waits for review.`
          : `${r.data.copied} photos added. Still needed: ${r.data.missing.join(', ') || 'none'}.` });
        router.refresh();
      })}>{pending ? 'Copying' : `Use the handover photos (${shots}${required ? `, ${required} required` : ''})`}</button>
      {msg && <span className={`small${msg.ok ? '' : ' form-error'}`} role="status" data-testid={`use-handover-msg-${vehicleId}`}>{msg.text}</span>}
    </span>
  );
}

export function NeedCell({ r }: { r: NeedRow }) {
  if (r.handover_shots > 0) return <UseHandoverPhotos vehicleId={r.vehicle_id} shots={r.handover_shots} required={r.handover_required} />;
  if (r.intake) return <Link prefetch={false} className="link small" href={`/admin/listings/${r.intake.id}`}>Open the listing ({r.intake.state.replace(/_/g, ' ')})</Link>;
  return <span className="small muted">No handover photos yet: take them at the next handover, or Start a listing.</span>;
}
