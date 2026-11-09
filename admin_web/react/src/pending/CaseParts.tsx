import type { ReactNode } from 'react';
import { Button } from '../ui/controls';
import { useAuthController } from '../auth/AuthContext';
import type { CaseTag } from './model';

export function Alert({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="pending-alert">
      <span className="t-title pending-alert__title">{title}</span>
      <span>{children}</span>
    </div>
  );
}

/** Second factor expired: re-verifying comes back here, and drafts are kept. */
export function SecondFactorNeeded({ onRetry }: { onRetry: () => void }) {
  const auth = useAuthController();
  return (
    <div className="pending-state">
      <Alert title="請重新完成第二步驗證">處理案件需要第二步驗證。驗證後會回到這裡，填的內容還在。</Alert>
      <div className="pending-state__actions">
        <Button variant="primary" onClick={() => void auth?.refresh().then(onRetry)}>
          前往驗證
        </Button>
        <Button onClick={() => void auth?.signOut()}>切換帳號</Button>
      </div>
    </div>
  );
}

export function Notice({
  title,
  tone = 'plain',
  children,
}: {
  title: string;
  tone?: 'plain' | 'alert';
  children: ReactNode;
}) {
  return (
    <div className={`case-notice${tone === 'alert' ? ' case-notice--alert' : ''}`}>
      <span className="t-title">{title}</span>
      <span>{children}</span>
    </div>
  );
}

export function Tag({ tag }: { tag: CaseTag }) {
  return <span className={`pending-tag pending-tag--${tag.tone}`}>{tag.label}</span>;
}

export function DefinitionList({ rows }: { rows: [string, ReactNode][] }) {
  return (
    <dl className="case-facts">
      {rows.map(([label, value]) => (
        <div key={label} className="case-facts__row">
          <dt className="t-label">{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}
