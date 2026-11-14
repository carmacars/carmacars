'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { staffRead } from '@/server/actions/staff-tools';
import { editorPhotoSrc, exportCovered, forSave, type NBox, type PlateStyle } from './plate-cover';
import { plateEnd } from './plate-photo';

// Release 33 (0700): an outside photo made again from the cut-out editor with the car where it was keeps its plate cover:
// the database carries the boxes and the style (vehicle_photos.plate_carry); here, when the review is open, the cover is
// drawn on the new file the way PlateEditor draws it and saved (photo_plate_record "covered"), so the plate check carries
// over and, on a published listing, the photo goes back on the site (0661). A photo it cannot cover is left to staff.
type Photo = { id: string; status: string; shot_type?: string; processed_path: string | null; plate_status: string; plate_carry?: { boxes?: NBox[]; style?: PlateStyle } | null; variants: Array<{ width: number }> | null };

export function PlateCarry({ photos }: { photos: Photo[] }) {
  const router = useRouter();
  const done = useRef(new Set<string>());
  const [note, setNote] = useState<string | null>(null);
  const todo = photos.filter((p) => p.plate_status === 'unchecked' && p.processed_path && ['processed', 'approved'].includes(p.status) && (p.plate_carry?.boxes?.length ?? 0) > 0);
  const key = todo.map((p) => `${p.id}:${p.processed_path}`).join(',');
  useEffect(() => {
    const list = todo.filter((p) => !done.current.has(`${p.id}:${p.processed_path}`));
    if (!list.length) return;
    let gone = false;
    void (async () => {
      let n = 0;
      for (const p of list) {
        done.current.add(`${p.id}:${p.processed_path}`);
        try {
          const c = await staffRead<{ cover_text: string }>('photo_plate_context', { photo: p.id });
          if (!c.ok || gone) continue;
          const img = await new Promise<HTMLImageElement>((res, rej) => { const i = new Image(); i.crossOrigin = 'anonymous'; i.onload = () => res(i); i.onerror = rej; i.src = editorPhotoSrc(p.id); });
          const boxes = p.plate_carry!.boxes!, style = 'blur' as const;
          const out = await exportCovered(img, boxes, style, c.data.cover_text, (p.variants ?? []).map((v) => v.width), undefined, plateEnd(p.shot_type));
          const fd = new FormData();
          fd.set('photo', p.id); fd.set('style', style); fd.set('boxes', JSON.stringify(forSave(boxes)));
          fd.set('width', String(out.width)); fd.set('height', String(out.height));
          fd.set('file', new File([out.main], 'covered.jpg', { type: 'image/jpeg' }));
          for (const v of out.variants) fd.set(`variant:${v.width}`, new File([v.blob], `covered-${v.width}.jpg`, { type: 'image/jpeg' }));
          const r = await fetch('/api/listing/plate', { method: 'POST', body: fd });
          if (((await r.json().catch(() => ({ ok: false }))) as { ok: boolean }).ok) n++;
        } catch { /* left to staff: "Cover the plate" */ }
      }
      if (!gone && n) { setNote(`The plate cover was put back on ${n} edited photo${n === 1 ? '' : 's'}.`); router.refresh(); }
    })();
    return () => { gone = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- runs once per photo file
  }, [key]);
  return note ? <p className="small" role="status" data-testid="plate-carry-note">{note}</p> : null;
}
