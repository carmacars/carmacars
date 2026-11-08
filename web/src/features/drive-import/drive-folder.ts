// Import photos from a Google Drive link (release 33, migration 0760). Pure: reading a public Drive folder without an
// API key (the folder page's embedded data, the embedded folder view as a second source), the Drive v3 API's answers,
// the download links, and what a listed file is. The server side (src/server/drive-import.ts) fetches; this decides.
// Tests: drive-folder.test.ts, on small synthetic pages (no real ids).

export const FOLDER_MIME = 'application/vnd.google-apps.folder';
export const ID_RE = /^[A-Za-z0-9_-]{10,100}$/;

export interface DriveEntry { id: string; name: string; mime: string; folder: boolean; size?: number | null }

/** The id in a pasted Drive link (a folder, or a file), or null when it is not a Drive link. */
export function parseDriveLink(input: string): { kind: 'folder' | 'file'; id: string } | null {
  const raw = String(input ?? '').trim();
  if (!raw) return null;
  let u: URL;
  try { u = new URL(/^https?:\/\//i.test(raw) ? raw : `https://${raw}`); } catch { return null; }
  if (!/^(drive|docs)\.google\.com$/i.test(u.hostname)) return null;
  const path = u.pathname;
  const folder = path.match(/\/folders\/([A-Za-z0-9_-]+)/);
  if (folder && ID_RE.test(folder[1]!)) return { kind: 'folder', id: folder[1]! };
  const file = path.match(/\/file\/d\/([A-Za-z0-9_-]+)/);
  if (file && ID_RE.test(file[1]!)) return { kind: 'file', id: file[1]! };
  const q = u.searchParams.get('id');
  if (q && ID_RE.test(q)) return { kind: /folderview|embeddedfolderview/.test(path) ? 'folder' : 'file', id: q };
  return null;
}

/** The address of a folder's page (the listing reads its embedded data). */
export const folderPageUrl = (id: string) => `https://drive.google.com/drive/folders/${encodeURIComponent(id)}`;
/** The embedded folder view: every entry of the folder in plain HTML (the folder page itself carries the first 50). */
export const embeddedViewUrl = (id: string) => `https://drive.google.com/embeddedfolderview?id=${encodeURIComponent(id)}#list`;
/** A public file's download (no key). `confirm=t` skips the virus-scan page of large files. */
export const publicDownloadUrl = (id: string) => `https://drive.usercontent.google.com/download?id=${encodeURIComponent(id)}&export=download&confirm=t`;

// ---------------------------------------------------------------- the folder page's embedded data
/** Undoes the page's JavaScript string escapes (\xNN, \uNNNN, \\, \', \", \/, \n). */
export function unescapeJsString(s: string): string {
  return s.replace(/\\(x([0-9a-fA-F]{2})|u([0-9a-fA-F]{4})|[\s\S])/g, (_m, all: string, x?: string, u?: string) => {
    if (x) return String.fromCharCode(parseInt(x, 16));
    if (u) return String.fromCharCode(parseInt(u, 16));
    return all === 'n' ? '\n' : all === 't' ? '\t' : all === 'r' ? '\r' : all;
  });
}

export interface FolderRead { entries: DriveEntry[]; /** the page may hold only its first page of entries (50) */ maybeMore: boolean; found: boolean; /** the folder's own name, from the page title */ title?: string }

/** The entries of a folder page: window['_DRIVE_ivd'] = '<escaped JSON>' holds [[ [id, [parents], name, mime, ...], ... ], ...]. */
export function parseFolderPage(html: string): FolderRead {
  const m = String(html ?? '').match(/_DRIVE_ivd'?\]?\s*=\s*'((?:[^'\\]|\\[\s\S])*)'/);
  if (!m) return { entries: [], maybeMore: false, found: false };
  const t = String(html).match(/<title>([^<]{1,200}?)\s+-\s+Google Drive<\/title>/i);
  const title = t ? decodeHtml(t[1]!).trim() || undefined : undefined;
  let data: unknown;
  try { data = JSON.parse(unescapeJsString(m[1]!)); } catch { return { entries: [], maybeMore: false, found: false }; }
  const list = Array.isArray(data) && Array.isArray(data[0]) ? (data[0] as unknown[]) : [];
  const entries: DriveEntry[] = [];
  for (const c of list) {
    if (!Array.isArray(c)) continue;
    const id = c[0], name = c[2], mime = c[3];
    if (typeof id !== 'string' || !ID_RE.test(id) || typeof name !== 'string' || typeof mime !== 'string') continue;
    entries.push({ id, name, mime, folder: mime === FOLDER_MIME });
  }
  return { entries, maybeMore: list.length >= 50, found: true, title };
}

const decodeHtml = (s: string) => s.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|#39);/gi, (_m, e: string) => {
  const t = e.toLowerCase();
  if (t === 'amp') return '&'; if (t === 'lt') return '<'; if (t === 'gt') return '>'; if (t === 'quot') return '"'; if (t === 'apos' || t === '#39') return "'";
  const n = t.startsWith('#x') ? parseInt(t.slice(2), 16) : parseInt(t.slice(1), 10);
  return Number.isFinite(n) ? String.fromCodePoint(n) : _m;
});

/** The embedded folder view: <div class="flip-entry" id="entry-<id>"> ... <a href=".../drive/folders/<id>" or ".../file/d/<id>/view"> ... <div class="flip-entry-title">name</div>. */
export function parseEmbeddedView(html: string): FolderRead {
  const text = String(html ?? '');
  const parts = text.split(/(?=<div[^>]*\bclass="(?:[^"]*\s)?flip-entry(?:\s[^"]*)?")/i).slice(1);
  const entries: DriveEntry[] = [];
  for (const p of parts) {
    const idm = p.match(/\bid="entry-([A-Za-z0-9_-]+)"/) ?? p.match(/\/(?:folders|file\/d)\/([A-Za-z0-9_-]+)/);
    const title = p.match(/<div[^>]*\bclass="[^"]*\bflip-entry-title\b[^"]*"[^>]*>([\s\S]*?)<\/div>/i);
    if (!idm || !title) continue;
    const id = idm[1]!;
    if (!ID_RE.test(id) || entries.some((e) => e.id === id)) continue;
    const name = decodeHtml(title[1]!.replace(/<[^>]*>/g, '')).trim();
    if (!name) continue;
    const folder = new RegExp(`/folders/${id}`).test(p) && !/\/file\/d\//.test(p);
    entries.push({ id, name, mime: folder ? FOLDER_MIME : mimeFromName(name), folder });
  }
  return { entries, maybeMore: false, found: parts.length > 0 };
}

/** Both sources merged (by id; the page's mime type wins). */
export function mergeEntries(...lists: DriveEntry[][]): DriveEntry[] {
  const seen = new Map<string, DriveEntry>();
  for (const l of lists) for (const e of l) if (!seen.has(e.id)) seen.set(e.id, e);
  return [...seen.values()];
}

// ---------------------------------------------------------------- the Drive v3 API (with a key)
export function apiListUrl(folderId: string, key: string, pageToken?: string | null): string {
  const q = `'${folderId}' in parents and trashed = false`;
  const u = new URL('https://www.googleapis.com/drive/v3/files');
  u.searchParams.set('q', q);
  u.searchParams.set('fields', 'nextPageToken,files(id,name,mimeType,size)');
  u.searchParams.set('pageSize', '1000');
  u.searchParams.set('supportsAllDrives', 'true');
  u.searchParams.set('includeItemsFromAllDrives', 'true');
  if (pageToken) u.searchParams.set('pageToken', pageToken);
  u.searchParams.set('key', key);
  return u.toString();
}
export const apiDownloadUrl = (id: string, key: string) => `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(id)}?alt=media&supportsAllDrives=true&key=${encodeURIComponent(key)}`;

export function parseApiList(json: unknown): { entries: DriveEntry[]; next: string | null } {
  const j = (json ?? {}) as { files?: unknown; nextPageToken?: unknown };
  const entries: DriveEntry[] = [];
  for (const f of Array.isArray(j.files) ? j.files : []) {
    const o = (f ?? {}) as Record<string, unknown>;
    if (typeof o.id !== 'string' || !ID_RE.test(o.id) || typeof o.name !== 'string') continue;
    const mime = typeof o.mimeType === 'string' ? o.mimeType : '';
    const size = o.size === undefined ? null : Number(o.size);
    entries.push({ id: o.id, name: o.name, mime, folder: mime === FOLDER_MIME, size: Number.isFinite(size) ? size : null });
  }
  return { entries, next: typeof j.nextPageToken === 'string' && j.nextPageToken ? j.nextPageToken : null };
}

// ---------------------------------------------------------------- what a file is
export type ImageKind = 'jpeg' | 'png' | 'webp' | 'heic';
const EXT: Record<string, ImageKind> = { jpg: 'jpeg', jpeg: 'jpeg', jpe: 'jpeg', png: 'png', webp: 'webp', heic: 'heic', heif: 'heic' };
const MIMES: Record<string, ImageKind> = { 'image/jpeg': 'jpeg', 'image/jpg': 'jpeg', 'image/pjpeg': 'jpeg', 'image/png': 'png', 'image/webp': 'webp', 'image/heic': 'heic', 'image/heif': 'heic' };

export function mimeFromName(name: string): string {
  const k = EXT[(name.split('.').pop() ?? '').toLowerCase()];
  return k === 'jpeg' ? 'image/jpeg' : k === 'png' ? 'image/png' : k === 'webp' ? 'image/webp' : k === 'heic' ? 'image/heic' : 'application/octet-stream';
}

/** Names that are never photos: the Mac's folder notes, thumbnail caches, resource forks and hidden files. */
export function isJunkName(name: string): boolean {
  const n = name.trim().toLowerCase();
  return !n || n === '.ds_store' || n === 'thumbs.db' || n === 'desktop.ini' || n === 'icon\r' || n.startsWith('._') || n.startsWith('.') || n === '__macosx' || n.endsWith('.tmp') || n.endsWith('~');
}

/** The kind of image a listed file is (by its mime type, else its extension), or null (a video, a document, junk). */
export function imageKindOf(e: { name: string; mime?: string | null }): ImageKind | null {
  if (isJunkName(e.name)) return null;
  const byMime = MIMES[(e.mime ?? '').toLowerCase()];
  if (byMime) return byMime;
  if ((e.mime ?? '') && !/^(application\/octet-stream|binary\/octet-stream)$/i.test(e.mime ?? '')) return null;
  return EXT[(e.name.split('.').pop() ?? '').toLowerCase()] ?? null;
}

/** What the bytes are, whatever the name says: an image of one of the kinds, an HTML page (Drive's warning or sign-in page),
 *  or something else. */
export function sniffBytes(b: Uint8Array): ImageKind | 'html' | 'other' {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'jpeg';
  if (b.length >= 4 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return 'png';
  if (b.length >= 12 && b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return 'webp';
  if (b.length >= 12 && b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
    const brand = String.fromCharCode(b[8]!, b[9]!, b[10]!, b[11]!).toLowerCase();
    if (['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1', 'heif'].includes(brand)) return 'heic';
  }
  const head = new TextDecoder().decode(b.subarray(0, 300)).trimStart().toLowerCase();
  if (head.startsWith('<!doctype html') || head.startsWith('<html') || head.includes('<title>google drive')) return 'html';
  return 'other';
}

/** Why a download came back as a page and not a photo, in a sentence for the summary. */
export function htmlReason(b: Uint8Array): string {
  const t = new TextDecoder().decode(b.subarray(0, 4000)).toLowerCase();
  if (t.includes('quota') || t.includes('too many users') || t.includes('download quota')) return 'Drive refused the download for now (too many downloads of this file)';
  if (t.includes('sign in') || t.includes('accounts.google.com') || t.includes('request access') || t.includes('you need access')) return 'The file is not shared with anyone who has the link';
  return 'Drive sent a web page, not the photo';
}

// ---------------------------------------------------------------- limits and ordering
export const LIMITS = {
  /** the largest photo taken (the listing pipeline's own limit for an upload) */
  maxFileBytes: 15 * 1024 * 1024,
  /** photos in one import */
  maxFiles: 5000,
  /** folders in one import's walk */
  maxFolders: 2000,
  /** how deep the walk goes below the link */
  maxDepth: 4,
  /** the bytes in one import */
  maxTotalBytes: 40 * 1024 * 1024 * 1024,
  /** the pause between two requests to Drive, milliseconds */
  pauseMs: 400
} as const;

/** File names in the order a person reads them (IMG_2 before IMG_10). */
export const byFileName = (a: { name: string }, b: { name: string }) => a.name.localeCompare(b.name, 'en', { numeric: true, sensitivity: 'base' });
