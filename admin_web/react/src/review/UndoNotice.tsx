import { useNavigate } from 'react-router';
import { useAppDispatch, useAppSelector } from '../app/hooks';
import { Button } from '../ui/controls';
import { useKindFilter } from './hooks';
import { decisionUndone, UNDO_MS } from './reviewSlice';

/**
 * 「5 秒內可復原」: while the last decision waits out its window, offer to
 * take it back and return to that report. Renders nothing otherwise.
 */
export function UndoNotice() {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const [, , search] = useKindFilter();
  const last = useAppSelector((state) =>
    state.review.lastQueued ? state.review.pending[state.review.lastQueued] : undefined,
  );
  if (!last) return null;
  const id = last.request.reportId;
  return (
    <p className="undo-notice" role="status">
      <span>
        已套用「{last.name}」，<span className="num">{UNDO_MS / 1000}</span> 秒內可復原
      </span>
      <Button
        variant="quiet"
        onClick={() => {
          dispatch(decisionUndone(id));
          navigate(`/review/${id}${search}`);
        }}
      >
        復原
      </Button>
    </p>
  );
}
