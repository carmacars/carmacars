// Blocks that many emails share, so the wording of a fact stays the same everywhere.
import { keyfacts, facts, price } from './components.mjs';

export const trip = () => keyfacts(
  { label: 'Pickup', value: '{{pickup_date}}', sub: '{{pickup_time}}' },
  { label: 'Return', value: '{{return_date}}', sub: '{{return_time}}' },
);
export const places = () => facts(
  ['Pickup place', '{{pickup_place}}'],
  ['Return place', '{{return_place}}'],
);
export const bookingPrice = (totalLabel = 'Total') => price({ each: 'line_items', total: [totalLabel, '{{total_amount}}'] });
