'use client';
import { usePathname } from 'next/navigation';
import { switchFunction } from '@/server/actions/va';
import { LAST_PORTAL_COOKIE, currentRole, mergedNav, type PortalOf, type RoleLink } from './roles';

// The one role switcher of every portal frame (r48 ops; roles.ts): all the person's roles in one row, the one they are
// in marked, and under it the pages of their other roles (the merged navigation). An office function is chosen with the
// staff portal's own action (it sets the function the screens work in), every other role is a link. Choosing a role
// remembers it on this device, so the next sign-in opens it.
/** The role chosen, kept on this device (its key only), so the next sign-in opens it. */
function remember(key: string) { try { document.cookie = `${LAST_PORTAL_COOKIE}=${key};path=/;max-age=31536000;samesite=lax`; } catch { /* cookies off: sign-in opens the first role */ } }

export function RoleSwitcher({ roles, activeFn, portal }: { roles: RoleLink[]; activeFn: string | null; portal: PortalOf }) {
  const path = usePathname() ?? '';
  const cur = currentRole(path, activeFn, roles) ?? roles.find((r) => r.portal === portal)?.key ?? null;
  const others = mergedNav(roles, cur);
  const office = roles.some((r) => r.fn);
  return (
    <div className="rsw" data-testid="role-switch" data-role={cur ?? undefined}>
      <nav className="rsw__roles" aria-label="Your roles">
        <span className="rsw__k" id="rsw-k">Working as</span>
        <ul className="rsw__list" aria-labelledby="rsw-k" data-testid={office ? 'fn-switch' : undefined}>
          {roles.map((r) => (
            <li key={r.key}>{r.fn
              ? <form action={switchFunction.bind(null, r.fn)}><button type="submit" className="rsw__role" aria-pressed={cur === r.key} onClick={() => remember(r.key)} data-testid={`role-${r.key}`}>{r.label}</button></form>
              : <a className="rsw__role" href={r.href} aria-current={cur === r.key ? 'true' : undefined} onClick={() => remember(r.key)} data-testid={`role-${r.key}`}>{r.label}</a>}</li>))}
        </ul>
      </nav>
      {others.length > 0 && (
        <details className="rsw__more" data-testid="role-nav">
          <summary>Pages of your other {others.length === 1 ? 'role' : 'roles'}</summary>
          <div className="rsw__groups">
            {others.map(({ role, links }) => (
              <nav key={role.key} className="rsw__group" aria-label={`${role.label} pages`}>
                <span className="rsw__gk">{role.label}</span>
                <ul>{links.map((l) => <li key={l.href}><a href={l.href} onClick={() => remember(role.key)}>{l.label}</a></li>)}</ul>
              </nav>))}
          </div>
        </details>)}
    </div>
  );
}
