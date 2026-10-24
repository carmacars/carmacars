import type { MapsAdapter, Place } from './types';
import { fromLabel } from '../../features/forms/address-parts.ts';

// Local and test stand-in: public Toronto landmarks (the prototype's sample list), and the
// straight-line distance times 1.3 for driving. No private addresses.
const PLACES: Place[] = [
  ['union', 'Union Station, 65 Front Street West, Toronto, ON', 43.6453, -79.3806],
  ['yyz-t1', 'Toronto Pearson Airport, Terminal 1, Mississauga, ON', 43.6777, -79.6248],
  ['yyz-t3', 'Toronto Pearson Airport, Terminal 3, Mississauga, ON', 43.6857, -79.6108],
  ['ytz', 'Billy Bishop Toronto City Airport, 1 Eireann Quay, Toronto, ON', 43.6305, -79.3961],
  ['cn', 'CN Tower, 290 Bremner Boulevard, Toronto, ON', 43.6426, -79.3871],
  ['rom', 'Royal Ontario Museum, 100 Queens Park, Toronto, ON', 43.6677, -79.3948],
  ['arena', 'Scotiabank Arena, 40 Bay Street, Toronto, ON', 43.6435, -79.3791],
  ['yorkdale', 'Yorkdale Shopping Centre, 3401 Dufferin Street, Toronto, ON', 43.7255, -79.4522],
  ['squareone', 'Square One, 100 City Centre Drive, Mississauga, ON', 43.5931, -79.6424],
  ['vaughan', 'Vaughan Mills, 1 Bass Pro Mills Drive, Vaughan, ON', 43.8256, -79.5383],
  ['markville', 'Markville Mall, 5000 Highway 7 East, Markham, ON', 43.8696, -79.2885],
  ['stc', 'Scarborough Town Centre, 300 Borough Drive, Toronto, ON', 43.7757, -79.2578],
  ['cityhall', 'Toronto City Hall, 100 Queen Street West, Toronto, ON', 43.6534, -79.3841],
  ['stlawrence', 'St. Lawrence Market, 93 Front Street East, Toronto, ON', 43.6487, -79.3716]
].map(([id, label, lat, lng]) => ({ id: id as string, label: label as string, lat: lat as number, lng: lng as number }));

// the public postal codes of the sample landmarks, so the forms' autofill is exercised locally
const POSTAL: Record<string, string> = { union: 'M5J 1E6', 'yyz-t1': 'L5P 1B2', 'yyz-t3': 'L5P 1B2', ytz: 'M5V 1A1', cn: 'M5V 3L9', rom: 'M5S 2C6', arena: 'M5J 2X2',
  yorkdale: 'M6A 2T9', squareone: 'L5B 2C9', vaughan: 'L4K 5W4', markville: 'L3R 4M9', stc: 'M1P 4P5', cityhall: 'M5H 2N2', stlawrence: 'M5E 1C3' };

export function fakeMaps(): MapsAdapter {
  return {
    name: 'fake',
    async autocomplete(query) {
      const words = query.toLowerCase().split(/[\s,]+/).filter(Boolean);
      if (query.trim().length < 2) return [];
      return PLACES.filter((p) => words.every((w) => p.label.toLowerCase().includes(w))).slice(0, 6).map(({ id, label }) => ({ id, label }));
    },
    async place(id) { const p = PLACES.find((x) => x.id === id); return p ? { ...p, parts: { ...fromLabel(p.label), postal_code: POSTAL[p.id] ?? '' } } : null; },
    async distanceKm(a, b) {
      const R = 6371; const rad = (d: number) => (d * Math.PI) / 180;
      const h = Math.sin(rad(b.lat - a.lat) / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(rad(b.lng - a.lng) / 2) ** 2;
      return Math.round(2 * R * Math.asin(Math.sqrt(h)) * 1.3 * 10) / 10;
    }
  };
}
