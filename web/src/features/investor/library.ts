// The investor Documents library (r50, migration 4300): what the investor portal and Admin > Investors > Documents read.
// Sections are the database's investor_library_kinds (business plan, financial forecast, pitch deck, feature decks, and
// any an Admin adds); each item is shown at its latest version with its date. Pure: the pages, the upload action and the
// unit tests share it.

export interface LibraryVersion { id: string; version: number; file_kind: 'pdf' | 'link'; link_url: string | null; size_bytes: number | null; note: string | null; created_at: string; uploaded_by: string | null }
export interface LibraryItem { id: string; title: string; kind: string; version: number; file_kind: 'pdf' | 'link'; updated_at: string; updated_on: string; link_url: string | null; archived?: boolean; history?: LibraryVersion[] }
export interface LibraryKind { key: string; label: string; items: LibraryItem[] }
export interface Library { kinds: LibraryKind[] }

export const LIBRARY_MAX_BYTES = 50 * 1024 * 1024;

/** The sections with something to show (archived items are left out unless `admin`), in the database's order */
export function shownKinds(lib: Library | null | undefined, admin = false): LibraryKind[] {
  return (lib?.kinds ?? []).map((k) => ({ ...k, items: k.items.filter((i) => admin || !i.archived) })).filter((k) => admin || k.items.length > 0);
}

/** Where an investor's row opens: the server route that signs a short link for a PDF, or the deck's own https link */
export function itemHref(i: Pick<LibraryItem, 'id' | 'file_kind' | 'link_url'>): string {
  return i.file_kind === 'link' && i.link_url && /^https:\/\//.test(i.link_url) ? i.link_url : `/investor/documents/library/${i.id}`;
}

/** "Version 2, updated November 24, 2026" from an item's version and its Toronto date (YYYY-MM-DD) */
export function versionLine(i: Pick<LibraryItem, 'version' | 'updated_on'>): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(i.updated_on);
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const d = m ? `${months[Number(m[2]) - 1]} ${Number(m[3])}, ${m[1]}` : i.updated_on;
  return `Version ${i.version}, updated ${d}`;
}

/** A PDF starts with %PDF- */
export const isPdf = (b: Uint8Array): boolean => b.length > 5 && b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46 && b[4] === 0x2d;

/** The file name a download gets: the title in plain characters, with its version */
export const downloadName = (title: string, version: number): string => `${(title.replace(/[^\w.-]+/g, '-').replace(/^-+|-+$/g, '') || 'document').slice(0, 80)}-v${version}.pdf`;

/** The deck link an Admin gives: https only, at most 500 characters */
export const validLink = (s: string): boolean => /^https:\/\/[^\s<>"]{3,}$/.test(s) && s.length <= 500;
