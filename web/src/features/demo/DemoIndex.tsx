import Link from '@/components/Link';

// r50 hotfix 2: the start of the demo portals (staff and Admin).
export function DemoIndex({ base }: { base: '/staff' | '/admin' }) {
  return (
    <div className="pt-split" data-testid="demo-index">
      <section className="pt-card stack" aria-labelledby="demo-i-r">
        <p className="pu-eyebrow">Demo</p><h2 className="d3" id="demo-i-r">Renter portal</h2>
        <p className="small">A booking from the request to the final statement: the offer, sign and pay, the countdown to pickup, the steps, the money and what the renter is sent at each stage.</p>
        <p><Link prefetch={false} className="btn btn--primary" href={`${base}/demo/renter`} data-testid="demo-open-renter">Open the demo renter portal</Link></p>
      </section>
      <section className="pt-card stack" aria-labelledby="demo-i-o">
        <p className="pu-eyebrow">Demo</p><h2 className="d3" id="demo-i-o">Owner portal</h2>
        <p className="small">An owner from the application to the first payout: the agreement, the documents, the ownership transfer, the inspection, the listing and the monthly statement.</p>
        <p><Link prefetch={false} className="btn btn--ghost" href={`${base}/demo/owner`} data-testid="demo-open-owner">Open the demo owner portal</Link></p>
      </section>
    </div>
  );
}
