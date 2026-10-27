import type { RolePublic } from './model';

// The title and description of a role's page (migration 0173), within the site's limits (title up to 70 characters,
// description 70 to 170: tests/lint/seo-audit.mjs).
export function roleTitle(title: string): string {
  const long = `${title} | Careers at CarmaCars`;
  if (long.length <= 70) return long;
  const short = `${title} | CarmaCars`;
  return short.length <= 70 ? short : `${title.slice(0, 57).replace(/\s+\S*$/, '')} | CarmaCars`;
}
export function roleDescription(r: Pick<RolePublic, 'summary' | 'location' | 'pay_text'>): string {
  let s = r.summary.trim();
  if (s.length < 70) s = `${s} ${r.location}. ${r.pay_text}.`;
  if (s.length > 170) s = s.slice(0, 166).replace(/\s+\S*$/, '').replace(/[,;:.]$/, '') + '...';
  return s;
}
