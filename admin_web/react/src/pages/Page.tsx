import type { ReactNode } from 'react';
import './Page.css';

interface PageProps {
  title: string;
  /** Caption beside the headline, e.g. 「最舊的在最上面」. */
  caption?: string;
  children: ReactNode;
}

export function Page({ title, caption, children }: PageProps) {
  return (
    <div className="page">
      <header className="page__header">
        <h1 className="t-headline page-headline">{title}</h1>
        {caption && <p className="t-caption">{caption}</p>}
      </header>
      {children}
    </div>
  );
}
