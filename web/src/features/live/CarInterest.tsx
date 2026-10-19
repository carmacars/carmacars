import Link from 'next/link';
import { pct } from '@/lib/format';

// Interest in one car (migration 0060), on Admin > Cars > a car: views today and in 7 days, people looking now,
// requests and conversion over 30 days, and the last 14 days of views.
export interface Interest { views_today: number; views_7d: number; viewers_7d: number; requests_30d: number; viewers_30d: number; bookings_30d: number; conversion_bps: number | null; looking_now: number; days: Array<{ day: string; views: number }> }

export function CarInterest({ i }: { i: Interest | null }) {
  if (!i) return <p className="small muted">Not available.</p>;
  const max = Math.max(1, ...i.days.map((x) => x.views));
  return (
    <div className="stack" data-testid="car-interest">
      <div className="ad-tiles">
        <div className="ad-tile"><span className="ad-tile__k">Looking now</span><b className="ad-tile__v">{i.looking_now}</b></div>
        <div className="ad-tile"><span className="ad-tile__k">Views today</span><b className="ad-tile__v">{i.views_today}</b></div>
        <div className="ad-tile"><span className="ad-tile__k">Views, 7 days</span><b className="ad-tile__v">{i.views_7d}</b><span className="ad-tile__s">{i.viewers_7d} people</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Conversion, 30 days</span><b className="ad-tile__v">{i.conversion_bps === null ? 'none yet' : pct(i.conversion_bps)}</b><span className="ad-tile__s">{i.requests_30d} requests from {i.viewers_30d} people</span></div>
      </div>
      <div className="ci-bars" role="img" aria-label={`Views in the last 14 days: ${i.days.map((x) => x.views).join(', ')}`}>
        {i.days.map((x) => <span key={x.day} className="ci-bar" style={{ height: `${Math.max(2, Math.round((x.views / max) * 48))}px` }} title={`${x.day.slice(0, 10)}: ${x.views}`} />)}
      </div>
      <p className="small muted">Views by visitors who accepted analytics. <Link prefetch={false} className="link" href="/admin/live">Live visitors</Link></p>
    </div>
  );
}
