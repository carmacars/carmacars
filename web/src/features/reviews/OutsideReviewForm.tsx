'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { outsideReviewAdd } from '@/server/actions/outside-reviews';

// "Add a customer review" (release 36, migration 2002): a review received outside the site, typed exactly as the
// customer gave it. Admin > Reviews and Staff > Review requests (customer service and sales).
export const REVIEW_SOURCES: Array<[string, string]> = [['turo', 'Turo'], ['previous_platform', 'Previous rental platform'], ['text_message', 'Text message'], ['phone_call', 'Phone call'],
  ['email', 'Email'], ['in_person', 'In person'], ['google', 'Google']];

export function OutsideReviewForm({ cars }: { cars: Array<{ id: string; name: string }> }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [n, setN] = useState(0);
  const [pending, run] = useTransition();
  if (!open) return <button className="btn btn--primary btn--sm" type="button" onClick={() => setOpen(true)} data-testid="outside-review-open">Add a customer review</button>;
  const submit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    run(async () => {
      const r = await outsideReviewAdd(form);
      if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
      setMsg({ ok: true, text: 'Added. It shows on the car page and the search pages with its source.' }); setN((x) => x + 1); router.refresh();
    });
  };
  return (
    <form key={n} className="stack" onSubmit={submit} data-testid="outside-review-form" aria-label="Add a customer review">
      <p className="small muted">Only real feedback from a customer, in their own words as received. Never write or change a review for them.</p>
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="or-name">Reviewer (first name and last initial)</label><input className="input" id="or-name" name="reviewer_name" placeholder="Sarah K." required /></div>
        <div className="field ad-field"><label className="label" htmlFor="or-source">Received</label>
          <select className="input" id="or-source" name="source" required defaultValue="turo">{REVIEW_SOURCES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
        <div className="field ad-field"><label className="label" htmlFor="or-date">Date received</label><input className="input" id="or-date" name="received_on" type="date" required /></div>
        <div className="field ad-field"><label className="label" htmlFor="or-rating">Rating</label>
          <select className="input" id="or-rating" name="rating" required defaultValue="5">{[5, 4, 3, 2, 1].map((x) => <option key={x} value={x}>{x} out of 5</option>)}</select></div>
        <div className="field ad-field"><label className="label" htmlFor="or-car">Car (optional)</label>
          <select className="input" id="or-car" name="vehicle_id" defaultValue=""><option value="">Not about one car</option>{cars.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></div>
        <div className="field ad-field"><label className="label" htmlFor="or-proof">Proof (optional screenshot or PDF)</label><input className="input" id="or-proof" name="proof" type="file" accept="image/jpeg,image/png,application/pdf" /></div>
      </div>
      <div className="field"><label className="label" htmlFor="or-body">The customer&apos;s words, as received</label><textarea className="input" id="or-body" name="body" rows={4} required minLength={3} maxLength={3000} /></div>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <p className="row"><button className="btn btn--primary" type="submit" disabled={pending}>{pending ? 'Adding' : 'Add the review'}</button>
        <button className="btn btn--ghost" type="button" onClick={() => setOpen(false)}>Close</button></p>
    </form>
  );
}
