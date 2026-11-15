export type Squish = { kind: string; sel: string; text: string; extra: string };
export function squishScan(): Squish[];
export const PUBLIC: string[];
