import 'server-only';
import { rpc } from '@/lib/db/repo';
import { photoUrl } from '@/lib/photo';

type CarPhoto = { path: string; variants?: Array<{ width: number; path: string }> | null };

// The cover photo of each car in a page's rows (migration 0430), at the size a row tile shows (48 by 32, twice for sharp
// screens): the smallest size at least 96 wide, else the original. The rows' cars come from reads the person already
// passed; a car without an approved cover is left out and its row shows the make's letter (CarCell).
export async function carPhotos(rows: ReadonlyArray<object>, key = 'vehicle_id'): Promise<Record<string, string>> {
  const ids = [...new Set(rows.map((r) => (r as Record<string, unknown>)[key]).filter((v): v is string => typeof v === 'string' && /^[0-9a-f-]{36}$/.test(v)))].slice(0, 500);
  if (!ids.length) return {};
  try {
    const m = (await rpc('server_row_car_photos', { p_vehicles: ids }, { role: 'service_role' })) as unknown as Record<string, CarPhoto>;
    const out: Record<string, string> = {};
    for (const [id, p] of Object.entries(m ?? {})) {
      if (!p?.path) continue;
      const v = (p.variants ?? []).filter((x) => x?.path && x.width >= 96).sort((a, b) => a.width - b.width)[0];
      out[id] = photoUrl(v?.path ?? p.path);
    }
    return out;
  } catch { return {}; }
}
