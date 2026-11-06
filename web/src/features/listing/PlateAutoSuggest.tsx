'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { editorPhotoSrc, needsSuggestion } from './plate-cover';

// 0521: the plate box is suggested by itself on every outside photo, the extra "More outside photos" included, as soon as
// the review opens: one photo after another, each answer kept on the photo (the vision route stores it with the image
// size), so "Cover the plate" opens with the box already drawn. Nothing is covered without a person: they check the box
// and press Cover. Off when the vision model is off (Program settings plate_detect_enabled, ai_vision_enabled).
type P = { id: string; vehicle_id: string; shot_type: string; processed_path: string | null; plate_status: string; plate_boxes: unknown[] | null; plate_suggestion?: unknown };

async function frame(id: string): Promise<{ data: string; width: number; height: number } | null> {
  const img = new Image();
  img.crossOrigin = 'anonymous';
  img.src = editorPhotoSrc(id);
  try { await img.decode(); } catch { return null; }
  const k = Math.min(1, 1024 / Math.max(img.naturalWidth || 1024, img.naturalHeight || 683));
  const c = document.createElement('canvas');
  c.width = Math.round((img.naturalWidth || 1024) * k); c.height = Math.round((img.naturalHeight || 683) * k);
  c.getContext('2d')!.drawImage(img, 0, 0, c.width, c.height);
  try { return { data: c.toDataURL('image/jpeg', 0.85), width: c.width, height: c.height }; } catch { return null; }
}

export function PlateAutoSuggest({ photos, exterior, on }: { photos: P[]; exterior: string[]; on: boolean }) {
  const router = useRouter();
  const todo = photos.filter((p) => needsSuggestion(p, exterior));
  const [done, setDone] = useState(0);
  const [stopped, setStopped] = useState<string | null>(null);
  const ran = useRef(false);
  useEffect(() => {
    if (!on || ran.current || !todo.length) return;
    ran.current = true;
    void (async () => {
      const { askVision } = await import('@/features/tolls/pdf');
      for (const p of todo) {
        const f = await frame(p.id);
        if (!f) continue;
        const r = await askVision('plate_detect', f.data, { photo: p.id, vehicle: p.vehicle_id, width: f.width, height: f.height });
        if (!r.ok) { setStopped(r.message); break; }
        setDone((n) => n + 1);
      }
      router.refresh();
    })();
  }, [on, todo, router]);
  if (!on || !todo.length && !done) return null;
  return (
    <p className="small muted" role="status" data-testid="plate-auto">
      {stopped ? `Plate boxes suggested on ${done} photo${done === 1 ? '' : 's'}; the rest: ${stopped} Draw those yourself.`
        : done < todo.length ? `Suggesting the plate box on the outside photos: ${done} of ${todo.length}.` : `Plate box suggested on ${done} outside photo${done === 1 ? '' : 's'}. Open each to check it, then Cover.`}
    </p>
  );
}
