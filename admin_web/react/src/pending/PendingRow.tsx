import { Link } from 'react-router';
import type { TimedCase } from '../api/v1/admin_v1.generated';
import { caseNumber, caseStatus, caseTags, caseTitle, dueDate, dueHint } from './model';

interface PendingRowProps {
  item: TimedCase;
  selected: boolean;
  now: number;
  /** Carries the current filter along, so returning keeps it. */
  search: string;
  onOpen: () => void;
}

/** Type, status and deadline only: a row never shows what a user wrote. */
export function PendingRow({ item, selected, now, search, onOpen }: PendingRowProps) {
  const hint = dueHint(item, now);
  const tags = caseTags(item);
  return (
    <li>
      <Link
        to={`/pending/${encodeURIComponent(item.id)}${search}`}
        className={`pending-row${selected ? ' is-selected' : ''}`}
        aria-current={selected ? 'true' : undefined}
        onClick={onOpen}
      >
        <span className="pending-row__top">
          <span className="pending-row__title">{caseTitle(item)}</span>
          <span className="pending-row__due">
            {hint && <span className="t-caption">{hint}</span>}
            <span className="num pending-row__date">{dueDate(item.due_at, now)}</span>
          </span>
        </span>
        <span className="pending-row__meta t-caption">
          <span className="num">{caseNumber(item)}</span>
          <span>{caseStatus(item)}</span>
        </span>
        {tags.length > 0 && (
          <span className="pending-row__tags">
            {tags.map((tag) => (
              <span key={tag.label} className={`pending-tag pending-tag--${tag.tone}`}>
                {tag.label}
              </span>
            ))}
          </span>
        )}
      </Link>
    </li>
  );
}
