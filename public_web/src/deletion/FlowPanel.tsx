import { useEffect, useRef, type ReactNode } from 'react';
import { Site } from '../ui/Site';
import './Flow.css';

/**
 * One step of the deletion flow: a single column inside the site (canvas
 * DesktopFlow, 560px at most). Focus starts on the heading so a screen
 * reader announces where the rider landed after each step.
 */
export function FlowPanel({
  title,
  children,
  aside,
  tone = 'plain',
}: {
  title: string;
  children?: ReactNode;
  aside?: ReactNode;
  tone?: 'plain' | 'danger';
}) {
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    heading.current?.focus();
  }, [title]);
  return (
    <Site aside={aside}>
      <section className={`flow flow--${tone}`} aria-labelledby="flow-h">
        <h1 id="flow-h" ref={heading} tabIndex={-1}>
          {title}
        </h1>
        {children}
      </section>
    </Site>
  );
}

/** The buttons under a step: the main action first, stacked on a phone. */
export function FlowActions({ children }: { children: ReactNode }) {
  return <div className="flow-actions">{children}</div>;
}
