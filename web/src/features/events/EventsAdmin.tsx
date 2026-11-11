import Link from '@/components/Link';
import { Act, type Field } from '@/features/admin/Act';
import { Badge, Card, Table } from '@/features/admin/ui';

// The event pages' list (release 36, part 5; migration 2003): Admin > Marketing > Events pages and Sales > Marketing.
// Add an event, or set this year's dates once the organiser announces them (the page says "usually in <month>" until then).
export type EventRow = { slug: string; name: string; category: string; venue: string; usual_months: string; starts_on: string | null; ends_on: string | null; is_active: boolean; source_url: string; updated_at: string };
const CATS: Array<[string, string]> = [['festival', 'Festival'], ['film', 'Film'], ['parade', 'Parade'], ['concerts', 'Concerts'], ['sports_season', 'Sports season'], ['fair', 'Fair'], ['show', 'Show'], ['race', 'Race'], ['holiday_market', 'Holiday market'], ['theme_park', 'Theme park']];
const NEW: Field[] = [
  { name: 'name', label: 'Event name', required: true }, { name: 'category', label: 'Kind', type: 'select', options: CATS, required: true }, { name: 'venue', label: 'Venue', required: true },
  { name: 'venue_address', label: 'Venue address', type: 'address' }, { name: 'city', label: 'City', value: 'Toronto' }, { name: 'lat', label: 'Venue latitude', type: 'number', required: true }, { name: 'lng', label: 'Venue longitude', type: 'number', required: true },
  { name: 'usual_months', label: 'Usually held (months)', required: true, placeholder: 'July and August' }, { name: 'starts_on', label: 'Starts (when announced)', type: 'date' }, { name: 'ends_on', label: 'Ends', type: 'date' },
  { name: 'summary', label: 'One or two sentences, from the organiser', type: 'textarea', required: true }, { name: 'source_name', label: 'Source (the organiser)', required: true }, { name: 'source_url', label: 'Source page (https)', required: true }
];
export function EventsAdmin({ rows, refresh }: { rows: EventRow[]; refresh: string[] }) {
  return (
    <Card title="Event pages" testId="events-admin">
      <p className="small muted">Each event has a &quot;Rent a car for&quot; page at /events/&lt;name&gt;. Set the dates only once the organiser announces them, with the organiser&apos;s page as the source.</p>
      <Act action="seo_event_save" label="Add an event" variant="primary" fields={NEW} refresh={refresh} />
      <Table<EventRow> testId="events-list" rows={rows} rowKey={(r) => r.slug} empty="No events yet."
        cols={[{ key: 'name', label: 'Event', render: (r) => <Link prefetch={false} className="link" href={`/events/${r.slug}`}>{r.name}</Link> }, { key: 'venue', label: 'Venue' },
          { key: 'usual_months', label: 'Usually' }, { key: 'starts_on', label: 'Dates', render: (r) => (r.starts_on ? `${r.starts_on}${r.ends_on && r.ends_on !== r.starts_on ? ` to ${r.ends_on}` : ''}` : 'To be announced') },
          { key: 'is_active', label: 'Page', render: (r) => <Badge s={r.is_active ? 'published' : 'hidden'} /> },
          { key: 'act', label: 'Actions', render: (r) => <Act action="seo_event_save" payload={{ slug: r.slug }} label="Edit" refresh={refresh}
            fields={[{ name: 'starts_on', label: 'Starts', type: 'date', value: r.starts_on }, { name: 'ends_on', label: 'Ends', type: 'date', value: r.ends_on }, { name: 'usual_months', label: 'Usually held', value: r.usual_months },
              { name: 'source_url', label: 'Source page (https)', value: r.source_url }, { name: 'is_active', label: 'Page on', type: 'bool', value: r.is_active }]} /> }]} />
    </Card>
  );
}
