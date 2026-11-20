import { KitPrices, KitSection } from '@/features/seo/kit/Kit';
import { money } from '@/lib/format';
import { getAddons } from './data';

// The add-ons a landing page is about (release 48: "car with a charger", "car and flowers", child seats), as price cards
// read from the add-ons table, so the page shows today's price and notice and never a number typed into its copy.
const UNIT: Record<string, string> = { per_day: 'a day', per_hour: 'an hour', per_trip: 'for the rental' };
export async function AddonCards({ codes }: { codes: string[] }) {
  const all = await getAddons();
  const mine = codes.map((c) => all.find((a) => a.code === c)).filter((a): a is NonNullable<typeof a> => Boolean(a && a.price_cents));
  if (!mine.length) return null;
  return (
    <KitSection id="addons" kicker="Add-ons" h={mine.length === 1 ? `${mine[0]!.name}: the price` : 'The add-ons and their prices'} p="Tick it in the add-ons step of your request. It is its own line in your offer.">
      <KitPrices cards={mine.map((a) => ({
        forWhom: a.name, amount: money(a.price_cents!), per: UNIT[a.pricing_unit] ?? '',
        points: [...(a.description ? [a.description] : []), ...(a.cap_cents ? [`At most ${money(a.cap_cents)} for the rental`] : []),
          ...(a.lead_time_hours > 0 ? [`Ask at least ${a.lead_time_hours >= 48 ? `${Math.round(a.lead_time_hours / 24)} days` : `${a.lead_time_hours} hours`} before pickup`] : []),
          ...(a.max_per_booking > 1 ? [`Up to ${a.max_per_booking} per booking`] : [])]
      }))} fine="Add-on prices are before HST and can depend on the car; your offer shows the exact line." />
    </KitSection>
  );
}
