export const SECTIONS: Record<string, string>;
export const NOTES_DIR: string;
export const OUT: string;
export function plain(s: string): string;
export function parseRelease(text: string, file?: string): { release: string; date: string; seq: number; summary: string; sections: Record<string, string[]> } | null;
export function buildData(dir?: string): { releases: Record<string, { date: string; seq: number; summary: string; sections: Record<string, string[]> }> };
export function build(dir?: string): string;
