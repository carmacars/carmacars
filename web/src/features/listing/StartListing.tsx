'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { listingStart } from '@/server/actions/listing';

// "Add listing photos" on an owner's vehicle (09-listing-pipeline.md section 2): starts the listing; an
// owner's listing always goes to staff review before it is published.
export function StartListing({ vehicleId, label = 'Add listing photos' }: { vehicleId: string; label?: string }) {
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();
  return (
    <>
      <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="listing-start"
        onClick={() => start(async () => { const r = await listingStart({ vehicle_id: vehicleId }); if (r.ok) router.refresh(); else setErr(r.message); })}>
        {pending ? 'Starting' : label}
      </button>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </>
  );
}
