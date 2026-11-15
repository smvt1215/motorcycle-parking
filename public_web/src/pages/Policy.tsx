import { Children, isValidElement, type ReactNode } from 'react';
import Markdown, { type Components } from 'react-markdown';
import { Link } from 'react-router';
import remarkGfm from 'remark-gfm';
import { dateLabel, sectionId, sections, type Policy } from '../legal/policies';
import { beforeEffective, changeId, markChanges, policyDiff } from '../legal/policyDiff';
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
  // Until the new version takes effect (Taiwan's calendar day, in this
  // browser), the version in force is shown with the new one's changes.
  const previous =
    policy.previous && beforeEffective(policy.effective, new Date()) ? policy.previous : undefined;
  const diff = previous ? policyDiff(previous.markdown, policy.markdown) : undefined;
  const markdown = diff ? diff.markdown : policy.markdown;
  const from = dateLabel(policy.effective);
  const rehypePlugins = diff
    ? [
        markChanges({
          ins: `${policy.version} 新增・${from}起生效`,
          del: `${policy.version} 刪除・${from}起不再適用`,
        }),
      ]
    : [];
  const toc = sections(markdown);
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
    <Site>
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
                <dd>{previous ? previous.version : policy.version}</dd>
              </div>
              <div>
                <dt>生效日期</dt>
                <dd>
                  {previous ? (
                    <time dateTime={previous.effective}>{dateLabel(previous.effective)}</time>
                  ) : (
                    <time dateTime={policy.effective}>{from}</time>
                  )}
                </dd>
              </div>
              {previous && (
                <div>
                  <dt>下一版</dt>
                  <dd>
                    {policy.version}，<time dateTime={policy.effective}>{from}</time>生效
                  </dd>
                </div>
              )}
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
            {previous && diff && (
              <section className="policy-notice policy-diff-notice" aria-label={`${policy.version} 版的修改`}>
                <p>
                  以下標示「{policy.version} 新增」與「{policy.version} 刪除」的地方是 {policy.version}{' '}
                  版的修改，自 {from}起生效；在那之前適用 {previous.version}{' '}
                  版，也就是保留標示「刪除」的文字、不含標示「新增」的文字。
                </p>
                <p className="policy-diff-jump">
                  共 {diff.changes} 處修改，跳到：
                  {Array.from({ length: diff.changes }, (_, i) => (
                    <a key={i} href={`#${changeId(i + 1)}`} aria-label={`第 ${i + 1} 處修改`}>
                      {i + 1}
                    </a>
                  ))}
                </p>
              </section>
            )}
          </div>
          <details className="policy-toc policy-toc--top" open>
            <summary>目錄（{toc.length} 節）</summary>
            <nav aria-label="目錄">{contents}</nav>
          </details>
          <div className="policy-text">
            <Markdown remarkPlugins={[remarkGfm]} rehypePlugins={rehypePlugins} components={components}>
              {markdown}
            </Markdown>
          </div>
        </article>
      </div>
    </Site>
  );
}
