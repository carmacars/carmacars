import { LegalPage } from '@/features/legal/LegalPage';
import { legalHtml } from '@/features/legal/render';
import { seoMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { money } from '@/lib/format';
import { fill, getFacts, getTokens } from '@/lib/site';

export const revalidate = 3600;
export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('Cancellation and refund policy | {{brand}}', t), path: '/cancellation-policy',
    description: fill('{{brand}} refunds by timing: {{c1}} within {{cGrace}} hours of booking, {{c2}} at {{cEarly}} hours or more before pickup, {{c3}} between {{cLate}} and {{cEarly}} hours, none inside {{cLate}} hours.', t) });
}

// Worked examples are computed by the cancellation rule itself (public.calc_cancellation).
async function example(label: string, bookedH: number, receivedH: number, startH: number, paid: number) {
  const t0 = Date.UTC(2026, 10, 2, 15); const iso = (h: number) => new Date(t0 + h * 3600e3).toISOString();
  const r = (await rpc('calc_cancellation', { p_booked_at: iso(bookedH), p_received_at: iso(receivedH), p_start_at: iso(startH), p_non_refundable: false, p_total_paid_cents: paid })) as unknown as { refund_bps: number; refund_cents: number; retained_cents: number }[];
  const x = r[0]!;
  return `<tr><th scope="row">${label}</th><td>${x.refund_bps / 100}%</td><td class="r">${money(x.refund_cents, { cents: true })}</td><td class="r">${money(x.retained_cents, { cents: true })}</td></tr>`;
}

export default async function Cancellation() {
  const [body0, f] = await Promise.all([legalHtml('legal.cancellation'), getFacts()]);
  const rent = 60000; const hst = Math.round((rent * f.hst_bps) / 10000); const paid = rent + hst;
  const rows = await Promise.all([
    example('Booked 10 days ahead, cancelled 5 hours after booking', 0, 5, 240, paid),
    example('Cancelled 3 days before pickup', -240, 0, 72, paid),
    example('Booked 30 hours before pickup, cancelled 1 hour later', 0, 1, 30, paid)
  ]);
  const ex = `<h2 class="d4" id="examples">Worked examples</h2><p>A booking with a ${money(rent, { cents: true })} rental charge and ${money(hst, { cents: true })} HST, ${money(paid, { cents: true })} paid.</p><div class="table-scroll" tabindex="0" role="region" aria-label="Worked examples"><table class="data"><thead><tr><th scope="col">What happened</th><th scope="col">Tier</th><th scope="col" class="r">Refund</th><th scope="col" class="r">Kept</th></tr></thead><tbody>${rows.join('')}</tbody></table></div>`;
  let body = body0;
  const cut = body.indexOf('<ul>'); if (cut > -1) body = body.slice(0, cut) + '<h2 class="d4" id="details">The details</h2>' + body.slice(cut);
  body = body.replace('<p>This policy does not limit', ex + '<p>This policy does not limit').replace('<div class="table-scroll"', '<h2 class="d4" id="tiers">Refund by timing</h2><div class="table-scroll"');
  return <LegalPage path="/cancellation-policy" h1="Cancellation policy" lead="Your refund depends on when we receive your cancellation. Four tiers, first match wins." body={body} />;
}
