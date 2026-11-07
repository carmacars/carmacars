import { loadBundle, blindSpotFacts } from '@/server/agreements/bundle';
import { EDITABLE_BOXES, layout } from '@/features/blindspot/layout';
import { BlindSpotBoxesForm } from './BlindSpotBoxesForm';

// 0544: Type into the Blind Spot agreement: each box as the form prints it now, editable; what is saved is drawn in place
// of the booking's value (and written back to the booking where it has a home: the insured vehicle, the claim, the
// adjuster, K/M and fuel out or in when missing). The preview opens the filled form with the corrections.
/** The boxes the form prints (null when the booking has no Blind Spot template). */
export async function blindSpotBoxes(bookingId: string, userId: string) {
  const b = await loadBundle(bookingId, userId).catch(() => null);
  if (!b?.bs.template) return null;
  const l = layout(blindSpotFacts(b));
  const valueOf = (box: string) => l.texts.find((t) => t.box === box)?.text ?? l.texts.find((t) => t.box === `${box}-na`)?.text ?? '';
  const overrides = (b.bs as { overrides?: Record<string, string> | null }).overrides ?? {};
  const boxes = EDITABLE_BOXES.map(([box, label]) => ({ box, label, value: valueOf(box), typed: box in overrides }));
  return boxes;
}

export async function BlindSpotBoxes({ bookingId, userId, refresh }: { bookingId: string; userId: string; refresh: string[] }) {
  const boxes = await blindSpotBoxes(bookingId, userId);
  return boxes ? <BlindSpotBoxesForm booking={bookingId} boxes={boxes} refresh={refresh} /> : null;
}
