import type { ReactNode } from 'react';

interface EmptyStateProps {
  title: string;
  children: ReactNode;
  actions?: ReactNode;
}

/** Empty / not-yet-available panel (States.dc.html 「佇列清空」 card). */
export function EmptyState({ title, children, actions }: EmptyStateProps) {
  return (
    <section className="panel empty-state" aria-label={title}>
      <h2 className="t-title">{title}</h2>
      <div className="muted empty-state__body">{children}</div>
      {actions && <div className="empty-state__actions">{actions}</div>}
    </section>
  );
}
