// Vetted static facts for the place pages (release 35, part M; docs/changes/2026-11-08-r35-seo-depth.md). Only facts
// that do not change often and that a public source states, each with its source. A city that is not here gets no
// highway or parking line: nothing is guessed. Distances, drive times, stops and hotels are never here: they are
// computed from coordinates (depth.ts) or loaded with their source (place_pois, the seo-data workflow).
// Keys: the municipality's name as the place data writes it, Ontario only. Relative imports only (the unit test runs it in Node).

export interface CityFacts {
  /** The 400-series and other controlled-access highways that run through the municipality. */
  highways: string[];
  /** One on-street parking rule, as the city's by-law states it. */
  parking?: { text: string; source: string };
  source: string;
}

const MTO = 'https://www.ontario.ca/document/ontario-road-maps';
export const ETR407 = { source: 'https://www.407etr.com/en/tolls/tolls/how-tolls-work.html' };

export const CITY_FACTS: Record<string, CityFacts> = {
  Toronto: { highways: ['Highway 401', 'Highway 400', 'Highway 404', 'Highway 427', 'the Gardiner Expressway', 'the Don Valley Parkway'], source: MTO,
    parking: { text: 'On-street parking is limited to 3 hours unless a sign says otherwise.', source: 'https://www.toronto.ca/legdocs/municode/1184_950.pdf' } },
  Mississauga: { highways: ['Highway 401', 'Highway 403', 'Highway 410', 'Highway 427', 'the QEW', 'Highway 407 ETR'], source: MTO,
    parking: { text: 'On-street parking is limited to 5 hours unless a sign says otherwise.', source: 'https://www.mississauga.ca/services-and-programs/transportation-and-streets/parking/' } },
  Brampton: { highways: ['Highway 410', 'Highway 407 ETR'], source: MTO },
  Vaughan: { highways: ['Highway 400', 'Highway 407 ETR', 'Highway 427'], source: MTO },
  Markham: { highways: ['Highway 404', 'Highway 407 ETR'], source: MTO },
  'Richmond Hill': { highways: ['Highway 404', 'Highway 407 ETR'], source: MTO },
  Oakville: { highways: ['the QEW', 'Highway 403', 'Highway 407 ETR'], source: MTO },
  Burlington: { highways: ['the QEW', 'Highway 403', 'Highway 407 ETR'], source: MTO },
  Milton: { highways: ['Highway 401', 'Highway 407 ETR'], source: MTO },
  Pickering: { highways: ['Highway 401', 'Highway 407 ETR'], source: MTO },
  Ajax: { highways: ['Highway 401'], source: MTO },
  Whitby: { highways: ['Highway 401', 'Highway 412', 'Highway 407 ETR'], source: MTO },
  Oshawa: { highways: ['Highway 401', 'Highway 407 ETR'], source: MTO },
  Hamilton: { highways: ['Highway 403', 'the QEW', 'the Lincoln M. Alexander Parkway', 'the Red Hill Valley Parkway'], source: MTO }
};

/** The facts for a place: its own (a city) or its city's (a neighbourhood), Ontario only. */
export function cityFacts(place: { name: string; kind: string; region: string | null }, parentCity?: string | null): CityFacts | null {
  if (place.region && place.region !== 'CA-ON') return null;
  const key = place.kind === 'neighbourhood' ? parentCity ?? '' : place.name;
  return CITY_FACTS[key] ?? null;
}
