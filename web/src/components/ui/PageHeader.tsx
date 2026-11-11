import type { ReactNode } from 'react';

// The style guide's page head (r35 UX; docs/style-guide.md): the Bookings head for every page. A big display title, one line
// of lead under it, the page's actions on the right (a phone stacks them), then the page's tabs. Styles: styles/ui-kit.css.
export function PageHeader({ title, lead, actions, tabs, testId }: { title: ReactNode; lead?: ReactNode; actions?: ReactNode; tabs?: ReactNode; testId?: string }) {
  return (
    <header className="ui-head" data-testid={testId}>
      <div className="ui-head__top">
        <div><h1 className="ui-head__title">{title}</h1>{lead && <p className="ui-head__lead">{lead}</p>}</div>
        {actions && <div className="ui-head__acts">{actions}</div>}
      </div>
      {tabs}
    </header>
  );
}
