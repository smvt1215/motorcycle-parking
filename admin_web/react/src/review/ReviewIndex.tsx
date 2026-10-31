import { Navigate } from 'react-router';
import { useAppSelector } from '../app/hooks';
import { useIsPhone, useKindFilter, useReviewQueue } from './hooks';
import { UndoNotice } from './UndoNotice';

/**
 * /review with no report chosen. Wide screens open the oldest report; when
 * the queue is empty they show 「全部處理完了」 (States.dc.html). Phones show
 * only the list, which QueuePane draws.
 */
export function ReviewIndex() {
  const isPhone = useIsPhone();
  const [, , search] = useKindFilter();
  const { query, visible, open } = useReviewQueue();
  const resolved = useAppSelector((state) => state.review.resolvedCount);

  if (!query.isSuccess) return null;
  const first = visible[0];
  if (first && !isPhone) return <Navigate to={`/review/${first.id}${search}`} replace />;
  if (first) return null;

  return (
    <section className="review-done" aria-label={open.length ? '這個類型沒有待審' : '審核佇列沒有待審'}>
      {open.length ? (
        <>
          <h2 className="t-headline">這個類型沒有待審</h2>
          <p className="muted">
            其他類型還有 <span className="num">{open.length}</span> 筆。
          </p>
        </>
      ) : (
        <>
          <h2 className="t-headline">全部處理完了</h2>
          <p className="muted">
            這次處理了 <span className="num">{resolved}</span>{' '}
            筆。新的回報進來會出現在這裡，審核分頁的待審數也會更新。
          </p>
        </>
      )}
      <UndoNotice />
    </section>
  );
}
