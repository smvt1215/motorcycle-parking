import { Children, isValidElement, type ReactNode } from 'react';
import Markdown, { type Components } from 'react-markdown';
import { Link } from 'react-router';
import remarkGfm from 'remark-gfm';
import { dateLabel, sectionId, sections, type Policy } from '../legal/policies';
import { Site } from '../ui/Site';
import './Policy.css';

function textOf(node: ReactNode): string {
  return Children.toArray(node)
    .map((child) =>
      typeof child === 'string' || typeof child === 'number'
        ? String(child)
        : isValidElement<{ children?: ReactNode }>(child)
          ? textOf(child.props.children)
          : '',
    )
    .join('');
}

/**
 * A published policy (canvas boards Privacy / PhonePrivacy, approved v23):
 * version and dates on top, the review notice, a table of contents (sticky
 * beside the text from 1040px, collapsible above it below), then the text.
 */
export function PolicyPage({ policy }: { policy: Policy }) {
  const toc = sections(policy.markdown);
  const components: Components = {
    h2({ children }) {
      const index = toc.indexOf(textOf(children).trim());
      return <h2 id={index >= 0 ? sectionId(index) : undefined}>{children}</h2>;
    },
    // Contact goes through the support form; an address in the text stays
    // text, never a mail link (#295).
    a({ href, children }) {
      if (!href || href.startsWith('mailto:')) return <>{children}</>;
      if (href.startsWith('/')) return <Link to={href}>{children}</Link>;
      if (href.startsWith('https://motoparking.smvtstudio.com/')) {
        return <Link to={new URL(href).pathname}>{children}</Link>;
      }
      return (
        <a href={href} rel="noreferrer">
          {children}
        </a>
      );
    },
    table({ children }) {
      return (
        <div className="policy-table">
          <table>{children}</table>
        </div>
      );
    },
  };

  const contents = (
    <ol className="policy-toc-list">
      {toc.map((title, index) => (
        <li key={title}>
          <a href={`#${sectionId(index)}`}>{title}</a>
        </li>
      ))}
    </ol>
  );

  return (
    <Site current={policy.title}>
      <div className="policy">
        <nav className="policy-toc policy-toc--side" aria-label="目錄">
          <span className="policy-toc-title">目錄</span>
          {contents}
        </nav>
        <article className="policy-body">
          <div className="policy-head">
            <h1>{policy.title}</h1>
            <p className="policy-subject">機車停車指南 App 與相關網站</p>
            <dl className="policy-meta">
              <div>
                <dt>版本</dt>
                <dd>{policy.version}</dd>
              </div>
              <div>
                <dt>生效日期</dt>
                <dd>
                  <time dateTime={policy.effective}>{dateLabel(policy.effective)}</time>
                </dd>
              </div>
              <div>
                <dt>最後更新</dt>
                <dd>
                  <time dateTime={policy.updated}>{dateLabel(policy.updated)}</time>
                </dd>
              </div>
            </dl>
            <p className="policy-notice" role="note">
              {policy.notice}
            </p>
          </div>
          <details className="policy-toc policy-toc--top" open>
            <summary>目錄（{toc.length} 節）</summary>
            <nav aria-label="目錄">{contents}</nav>
          </details>
          <div className="policy-text">
            <Markdown remarkPlugins={[remarkGfm]} components={components}>
              {policy.markdown}
            </Markdown>
          </div>
        </article>
      </div>
    </Site>
  );
}
