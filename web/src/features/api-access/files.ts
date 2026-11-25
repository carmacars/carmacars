// r50 (3870): the files a connector read gives (a call recording, ID images, a signed agreement, photos). The database answers
// {"_file": {"bucket", "key", "name"}}; each is swapped here for {url, expires_in_seconds} with a link the server signs
// (src/server/connector-files.ts) and /api/connector/file serves. Pure, so the unit tests share it (files.test.ts).
export const FILE_TTL_SECONDS = 600;
export const FILE_BUCKETS = ['documents', 'identity', 'condition-photos', 'agreements', 'vehicle-originals'] as const;
export type FileBucket = (typeof FILE_BUCKETS)[number];
export interface FileRef { bucket: FileBucket; key: string; name?: string }

/** A {_file} marker the database gave, checked: a known bucket and a storage key with no way out of it. */
export function fileRef(v: unknown): FileRef | null {
  const f = (v as { _file?: { bucket?: unknown; key?: unknown; name?: unknown } } | null)?._file;
  if (!f || typeof f.bucket !== 'string' || typeof f.key !== 'string') return null;
  if (!(FILE_BUCKETS as readonly string[]).includes(f.bucket)) return null;
  if (!f.key || f.key.length > 512 || f.key.startsWith('/') || f.key.split('/').includes('..')) return null;
  const name = typeof f.name === 'string' ? f.name.replace(/[^\w.-]+/g, '-').slice(0, 120) : undefined;
  return { bucket: f.bucket as FileBucket, key: f.key, ...(name ? { name } : {}) };
}

/** Every {_file} in an answer swapped for a signed link (or null when the marker is not a valid one). */
export async function swapFiles(v: unknown, sign: (f: FileRef) => Promise<string>): Promise<unknown> {
  if (Array.isArray(v)) return Promise.all(v.map((x) => swapFiles(x, sign)));
  if (!v || typeof v !== 'object') return v;
  if ('_file' in (v as Record<string, unknown>)) {
    const f = fileRef(v);
    return f ? { url: await sign(f), name: f.name ?? null, expires_in_seconds: FILE_TTL_SECONDS } : null;
  }
  const out: Record<string, unknown> = {};
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) out[k] = await swapFiles(x, sign);
  return out;
}

/** Whether an answer holds a file to sign (so the others are left untouched). */
export const hasFiles = (v: unknown): boolean => JSON.stringify(v ?? null).includes('"_file":');
