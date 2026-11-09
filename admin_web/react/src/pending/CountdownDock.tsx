import { useCallback, useEffect, useState } from 'react';
import { useLocation, useNavigate } from 'react-router';
import { useAppDispatch, useAppSelector } from '../app/hooks';
import { Button } from '../ui/controls';
import { cancelAction, dismissed, newestCounting, type TrackedAction } from './actionsSlice';
import { useOnline, useTick } from './useCaseEffects';

/** Two lines at most; the rest fold behind 「還有 N 筆等待中」 (t8). */
const VISIBLE = 2;

function Bar({
  tone = 'plain',
  digit,
  title,
  body,
  children,
}: {
  tone?: 'plain' | 'alert';
  digit?: number;
  title: string;
  body: string;
  children?: React.ReactNode;
}) {
  return (
    <div className={`dock-bar${tone === 'alert' ? ' dock-bar--alert' : ''}`}>
      {digit !== undefined && (
        <span aria-hidden="true" className="dock-bar__digit">
          {digit}
        </span>
      )}
      <span className="dock-bar__text">
        <span className="dock-bar__title">{title}</span>
        <span className="t-caption dock-bar__body">{body}</span>
      </span>
      {children}
    </div>
  );
}

function Counting({
  action,
  now,
  newest,
  canCancel,
  onCancel,
}: {
  action: TrackedAction;
  now: number;
  newest: boolean;
  canCancel: boolean;
  onCancel: () => void;
}) {
  const seconds = Math.max(0, Math.ceil((action.deadline - now) / 1000));
  return (
    <Bar digit={seconds} title={`${seconds} 秒後${action.labels.verb}`} body={action.labels.subject}>
      {canCancel && (
        <Button
          className="dock-bar__cancel"
          disabled={action.cancelling}
          shortcut={newest ? 'Z' : undefined}
          onClick={onCancel}
        >
          {action.labels.cancel}
        </Button>
      )}
    </Bar>
  );
}

function Result({ action, onOpen }: { action: TrackedAction; onOpen: () => void }) {
  const { labels, phase, late } = action;
  if (phase === 'sending') {
    return late ? (
      <Bar tone="alert" title="來不及取消" body={labels.lateBody} />
    ) : (
      <Bar title={labels.sendingTitle} body={labels.sendingBody} />
    );
  }
  if (phase === 'done') return <Bar title={labels.doneTitle} body={labels.doneBody} />;
  if (phase === 'slow') {
    return <Bar title={labels.sendingTitle} body="伺服器比平常慢，結果會顯示在清單" />;
  }
  const open = (
    <Button className="dock-bar__cancel" onClick={onOpen}>
      打開案件
    </Button>
  );
  if (phase === 'cancelled') {
    return (
      <Bar title={labels.cancelledTitle} body={labels.cancelledBody}>
        {open}
      </Bar>
    );
  }
  if (phase === 'stale') {
    return (
      <Bar tone="alert" title={labels.staleTitle} body={labels.staleBody}>
        {open}
      </Bar>
    );
  }
  return (
    <Bar tone="alert" title={labels.failedTitle} body={labels.failedBody}>
      {open}
    </Bar>
  );
}

/**
 * 倒數列 (TimedCountdown*): every action has its own line, nothing pauses,
 * and Z cancels the newest. The live region is separate and static, so a
 * screen reader hears each action once rather than every second.
 */
export function CountdownDock() {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const { search } = useLocation();
  const online = useOnline();
  const actions = useAppSelector((state) => state.pendingActions.actions);
  const announcement = useAppSelector((state) => state.pendingActions.announcement);
  const [expanded, setExpanded] = useState(false);

  const counting = actions.filter((a) => a.phase === 'counting').sort((a, b) => a.seq - b.seq);
  const others = actions.filter((a) => a.phase !== 'counting').sort((a, b) => a.seq - b.seq);
  const now = useTick(counting.length > 0);
  const anyCounting = counting.length > 0;

  const newest = newestCounting(actions);
  const newestId = newest?.id;
  const cancelNewest = useCallback(() => {
    if (newestId) void dispatch(cancelAction(newestId));
  }, [dispatch, newestId]);

  useEffect(() => {
    if (!anyCounting || !online) return undefined;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'z' && event.key !== 'Z') return;
      if (event.repeat || event.ctrlKey || event.metaKey || event.altKey || event.isComposing) return;
      const target = event.target as HTMLElement | null;
      if (target?.closest('input, textarea, select, [contenteditable="true"]')) return;
      event.preventDefault();
      cancelNewest();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [anyCounting, online, cancelNewest]);

  // Oldest first, the newest last and nearest the buttons: its Z key is shown.
  const shown = expanded ? counting : counting.slice(-VISIBLE);
  const folded = counting.length - shown.length;
  const results = others.slice(-VISIBLE);

  return (
    <>
      {/* Plain text: changes here are the only ones read out. */}
      <div role="status" aria-live="polite" aria-atomic="true" className="visually-hidden">
        {announcement}
      </div>
      {actions.length > 0 && (
        <div className="case-dock" aria-label="等待中的處理" role="group">
          {results.map((action) => (
            <Result
              key={action.id}
              action={action}
              onOpen={() => {
                dispatch(dismissed(action.id));
                void navigate(`/pending/${encodeURIComponent(action.caseId)}${search}`);
              }}
            />
          ))}
          {!online && counting.length > 0 && (
            <Bar
              tone="alert"
              title="連線中斷，現在無法取消"
              body={`等待中的 ${counting.length} 筆仍會在伺服器完成`}
            />
          )}
          {online && counting.some((a) => a.cancelError) && (
            <Bar tone="alert" title="連線中斷，現在無法取消" body="已排定的處理仍會在伺服器完成" />
          )}
          {folded > 0 && (
            <button type="button" className="dock-more" onClick={() => setExpanded(true)}>
              還有 {folded} 筆等待中
            </button>
          )}
          {shown.map((action) => (
            <Counting
              key={action.id}
              action={action}
              now={now}
              newest={action.id === newestId}
              canCancel={online}
              onCancel={() => void dispatch(cancelAction(action.id))}
            />
          ))}
        </div>
      )}
    </>
  );
}
