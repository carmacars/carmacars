// What the Google Drive import pages read (app.drive_import_get, drive_import_list, drive_import_cars; migration 0760).
export interface CarOption { id: string; year: number | null; make: string; model: string; trim?: string | null; colour?: string | null; plate?: string | null; partner?: string | null; label: string }
export interface Totals { imported?: number; skipped?: number; failed?: number; pending?: number; found?: number; cars?: number; bytes?: number; submitted?: number; not_submitted?: Array<{ vehicle: string; reason: string }> }
export interface FolderRow {
  id: string; name: string; path: string; depth: number; state: 'pending' | 'done' | 'failed'; error: string | null; note: string | null;
  images: number; other: number; vehicle_id: string | null; vehicle: string | null; score: number | null; match_note: string | null; ambiguous: boolean; include: boolean;
  candidates: Array<{ vehicle_id: string; score: number; why: string[] }>; counts: { pending: number; done: number; skipped: number; failed: number };
}
export interface ImportView {
  import: { id: string; kind: 'car' | 'bulk'; status: 'scanning' | 'review' | 'importing' | 'done' | 'failed' | 'cancelled'; error: string | null; vehicle_id: string | null; vehicle: string | null;
    options: { submit?: boolean }; created_at: string; finished_at: string | null; scanned: boolean; due: boolean; started_by: string | null; totals: Totals };
  folders: FolderRow[];
  problems: Array<{ name: string; path: string; state: 'failed' | 'skipped'; reason: string | null }>;
}
export interface RunRow { id: string; kind: 'car' | 'bulk'; status: ImportView['import']['status']; created_at: string; error: string | null; vehicle: string | null; totals: Totals; started_by: string | null }
