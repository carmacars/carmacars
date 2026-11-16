import 'server-only';
import { createHash } from 'node:crypto';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { storage, type Bucket } from '@/integrations/storage';
import { CUTOUT_MAX_WIDTH, cutoutKey, largestBlobBox, type CutoutDue } from '@/features/home/cutout';

// Release 48 O (3080): the cutouts of the decorative sections and the home hero, made once and kept in Storage.
// app.site_cutouts_due gives the cars whose cutout is missing or was made from another photo than the chain now gives (the
// R48 studio set, the listing photos, the check-in and check-out photos, the stock model photo). Each photo goes to the local
// background remover (rembg's server, REMBG_URL, a container next to the site on the company server), then sharp crops it
// to the car (its transparent edges), keeps it at most 1600 pixels wide and writes a WebP with transparency to
// vehicle-public/site/cutouts/. No Cloudflare image transformation: the site is leaving Cloudflare. Unset REMBG_URL: nothing
// is made and the sections keep their photos. Called by the listing worker's door every few minutes, a few cars a run.
const SR = { role: 'service_role' as const };

export interface CutoutRun { made: number; failed: number; skipped?: string; errors: string[] }

type Sharp = typeof import('sharp');
let sharpMod: Sharp | null | undefined;
async function loadSharp(): Promise<Sharp | null> {
  if (sharpMod !== undefined) return sharpMod;
  try { const name = 'sharp'; sharpMod = ((await import(/* webpackIgnore: true */ name)) as { default: Sharp }).default; } catch { sharpMod = null; }
  return sharpMod;
}

async function removeBackground(url: string, bytes: Uint8Array): Promise<Uint8Array> {
  const form = new FormData();
  form.append('file', new Blob([bytes as BlobPart]), 'photo');
  // isnet-general-use: a 180 MB model that keeps a whole car (rembg's default model is 1 GB)
  form.append('model', 'isnet-general-use');
  const r = await fetch(`${url.replace(/\/$/, '')}/api/remove`, { method: 'POST', body: form, signal: AbortSignal.timeout(90_000) });
  if (!r.ok) throw new Error(`the background remover answered ${r.status}`);
  return new Uint8Array(await r.arrayBuffer());
}

export async function runSiteCutoutsNow({ max = 2, deadlineMs = 20_000 }: { max?: number; deadlineMs?: number } = {}): Promise<CutoutRun> {
  const url = env().REMBG_URL;
  if (!url) return { made: 0, failed: 0, skipped: 'REMBG_URL is not set', errors: [] };
  const sharp = await loadSharp();
  if (!sharp) return { made: 0, failed: 0, skipped: 'sharp is not installed', errors: [] };
  const due = ((await rpc('site_cutouts_due', { p_limit: max, p_shot: 'left' }, SR)) ?? []) as unknown as CutoutDue[];
  const out: CutoutRun = { made: 0, failed: 0, errors: [] };
  const end = Date.now() + deadlineMs;
  const s = await storage();
  for (const d of due) {
    if (Date.now() > end) break;
    try {
      const src = await s.get(d.source.bucket as Bucket, d.source.path);
      if (!src) throw new Error('the source photo is not in storage');
      const cut = Buffer.from(await removeBackground(url, src));
      // the car is the largest shape: a sign or lettering on the wall behind it, kept apart from it, is cropped off
      const meta = await sharp(cut).metadata();
      const W = meta.width ?? 0, H = meta.height ?? 0, k = Math.min(1, 400 / Math.max(W, 1));
      const mask = await sharp(cut).ensureAlpha().extractChannel(3).resize({ width: Math.max(1, Math.round(W * k)) }).raw().toBuffer({ resolveWithObject: true });
      const blob = largestBlobBox(new Uint8Array(mask.data), mask.info.width, mask.info.height);
      if (!blob) throw new Error('no car found');
      const pad = 2 / k;
      const box = { left: Math.max(0, Math.floor(blob.left / k - pad)), top: Math.max(0, Math.floor(blob.top / k - pad)) };
      const area = { ...box, width: Math.min(W - box.left, Math.ceil(blob.width / k + 2 * pad)), height: Math.min(H - box.top, Math.ceil(blob.height / k + 2 * pad)) };
      const img = sharp(await sharp(cut).extract(area).png().toBuffer()).trim({ threshold: 8 });
      const { data, info } = await img.resize({ width: CUTOUT_MAX_WIDTH, withoutEnlargement: true })
        .webp({ quality: 82, alphaQuality: 90, effort: 5 }).toBuffer({ resolveWithObject: true });
      // a cutout with almost nothing left (the remover found no car) is a failure, never shown
      if (info.width < 200 || info.height < 60 || info.width / info.height < 1.2) throw new Error(`no car found (${info.width}x${info.height})`);
      const key = cutoutKey(d.vehicle_id, d.shot, createHash('sha1').update(data).digest('hex'));
      await s.put('vehicle-public', key, new Uint8Array(data), 'image/webp');
      await rpc('site_cutout_save', { p_vehicle: d.vehicle_id, p_shot: d.shot, p: { source: d.source, path: key, width: info.width, height: info.height } as unknown as Json }, SR);
      out.made++;
    } catch (e) {
      out.failed++;
      const msg = e instanceof Error ? e.message.slice(0, 200) : 'failed';
      out.errors.push(msg);
      await rpc('site_cutout_save', { p_vehicle: d.vehicle_id, p_shot: d.shot, p: { source: d.source, error: msg } as unknown as Json }, SR).catch(() => undefined);
    }
  }
  return out;
}
