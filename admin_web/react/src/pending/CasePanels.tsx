import { useEffect, useId, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import type { ContentReport, TimedCase } from '../api/v1/admin_v1.generated';
import { Button } from '../ui/controls';
import {
  keepButtonLabel,
  NEEDS_NEW_NAME,
  RESTORE_REASONS,
  type CaseDraft,
  type RestoreReason,
} from './caseCopy';
import { reportFieldLabel } from './ReportCase';

/** The placeholder the server rejects as a real name (private.content_hold_placeholder). */
const NAME_PLACEHOLDER = '名稱審核中';

/**
 * A handling panel: a bottom sheet below 680px, in the case above that (t7).
 * Focus goes to the title on opening and back to the opener on closing.
 */
function Panel({
  title,
  sheet,
  onClose,
  children,
}: {
  title: string;
  sheet: boolean;
  onClose: () => void;
  children: ReactNode;
}) {
  const id = useId();
  const titleRef = useRef<HTMLHeadingElement>(null);
  const root = useRef<HTMLElement>(null);

  useEffect(() => {
    const opener = document.activeElement as HTMLElement | null;
    titleRef.current?.focus();
    return () => opener?.focus?.();
  }, []);

  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (event.key === 'Escape') {
      event.stopPropagation();
      onClose();
      return;
    }
    if (event.key !== 'Tab' || !sheet || !root.current) return;
    const focusable = [
      ...root.current.querySelectorAll<HTMLElement>('button, input, textarea, select, a[href]'),
    ].filter((el) => !el.hasAttribute('disabled'));
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (!first || !last) return;
    const active = document.activeElement;
    if (event.shiftKey && (active === first || active === titleRef.current)) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && active === last) {
      event.preventDefault();
      first.focus();
    }
  };

  const body = (
    <section
      ref={root}
      aria-labelledby={`${id}-title`}
      role={sheet ? 'dialog' : 'region'}
      aria-modal={sheet || undefined}
      className={sheet ? 'case-panel case-panel--sheet' : 'case-panel'}
      onClick={(event) => event.stopPropagation()}
      onKeyDown={onKeyDown}
    >
      <h2 id={`${id}-title`} ref={titleRef} tabIndex={-1} className="t-title case-panel__title">
        {title}
      </h2>
      {children}
    </section>
  );
  return sheet ? (
    <div className="case-scrim" onClick={onClose}>
      {body}
    </div>
  ) : (
    body
  );
}

function Actions({ children }: { children: ReactNode }) {
  return <div className="case-panel__actions">{children}</div>;
}

interface PanelContext {
  sheet: boolean;
  draft: CaseDraft;
  onDraft: (patch: Partial<CaseDraft>) => void;
  busy: boolean;
  onClose: () => void;
}

export function ConfirmResolvePanel({
  sheet,
  onClose,
  onContinue,
}: {
  sheet: boolean;
  onClose: () => void;
  onContinue: () => void;
}) {
  return (
    <Panel title="回覆還沒寄出" sheet={sheet} onClose={onClose}>
      <p>結案不會寄出這段回覆。切換案件或返回時，內容會保留在這個案件。</p>
      <Actions>
        <Button variant="primary" onClick={onClose}>
          回去寫完
        </Button>
        <Button onClick={onContinue}>不寄出，直接結案</Button>
      </Actions>
    </Panel>
  );
}

export function ResolvePanel({
  sheet,
  draft,
  onDraft,
  busy,
  onClose,
  onSubmit,
}: PanelContext & { onSubmit: (status: 'done' | 'rejected', note: string) => void }) {
  const id = useId();
  const [showError, setShowError] = useState(false);
  const status = draft.resolveStatus;
  const submit = () => {
    if (!status) {
      setShowError(true);
      return;
    }
    onSubmit(status, (draft.resolveNote ?? '').trim());
  };
  return (
    <Panel title="結案" sheet={sheet} onClose={onClose}>
      <fieldset className="case-reasons">
        <legend className="visually-hidden">結案結果</legend>
        {[
          { value: 'done', label: '已處理', note: '' },
          { value: 'rejected', label: '無法處理', note: '例如無法確認身分' },
        ].map((option) => (
          <label key={option.value} className="case-reason">
            <input
              type="radio"
              name={`${id}-status`}
              checked={status === option.value}
              onChange={() => onDraft({ resolveStatus: option.value as 'done' | 'rejected' })}
            />
            <span>
              <span className="case-reason__label">{option.label}</span>
              {option.note && <span className="t-caption case-reason__note">{option.note}</span>}
            </span>
          </label>
        ))}
      </fieldset>
      {showError && !status && <p className="case-field-error">請先選一個結果。</p>}
      <div className="case-field">
        <label htmlFor={`${id}-note`} className="t-label">
          內部備註（選填）
        </label>
        <input
          id={`${id}-note`}
          type="text"
          maxLength={500}
          value={draft.resolveNote ?? ''}
          onChange={(event) => onDraft({ resolveNote: event.target.value })}
        />
        <span className="t-caption">對方看不到。30 天內對方補充或回信，案件會重新打開。</span>
      </div>
      <Actions>
        <Button variant="primary" disabled={busy} onClick={submit}>
          確定結案
        </Button>
        <Button variant="quiet" onClick={onClose}>
          返回
        </Button>
      </Actions>
      <span className="t-caption">按下後有 5 秒可以取消。</span>
    </Panel>
  );
}

export function RestorePanel({
  sheet,
  draft,
  onDraft,
  busy,
  onClose,
  onSubmit,
  hidden,
  count,
  changed,
}: PanelContext & {
  hidden: boolean;
  count: number;
  changed: boolean;
  onSubmit: (reason: RestoreReason, note: string) => void;
}) {
  const id = useId();
  const [showError, setShowError] = useState(false);
  const reason = draft.restoreReason;
  const note = draft.restoreNote ?? '';
  const noteRequired = reason === 'other';
  const noteMissing = noteRequired && note.trim() === '';
  const submit = () => {
    if (!reason || noteMissing) {
      setShowError(true);
      return;
    }
    onSubmit(reason, note.trim());
  };
  return (
    <Panel title="檢舉不成立" sheet={sheet} onClose={onClose}>
      <p>
        {hidden
          ? changed
            ? '放回 App 的是目前原文，也就是回報者在檢舉後改過的版本。'
            : '放回 App 的是目前原文。'
          : '內容會繼續顯示在 App。'}
        這 <span className="num">{count}</span> 則檢舉一起結案。
      </p>
      <fieldset className="case-reasons">
        <legend className="visually-hidden">不成立的原因</legend>
        {RESTORE_REASONS.map((option) => (
          <label key={option.value} className="case-reason">
            <input
              type="radio"
              name={`${id}-reason`}
              checked={reason === option.value}
              onChange={() => onDraft({ restoreReason: option.value })}
            />
            <span>
              <span className="case-reason__label">{option.label}</span>
              <span className="t-caption case-reason__note">{option.description}</span>
            </span>
          </label>
        ))}
      </fieldset>
      {showError && !reason && <p className="case-field-error">請先選一個原因。</p>}
      <div className="case-field">
        <label htmlFor={`${id}-note`} className="t-label">
          處理說明（選其他原因時必填）
        </label>
        <textarea
          id={`${id}-note`}
          rows={2}
          maxLength={500}
          value={note}
          aria-invalid={(showError && noteMissing) || undefined}
          onChange={(event) => onDraft({ restoreNote: event.target.value })}
        />
        {showError && noteMissing && <p className="case-field-error">選了其他原因，要寫下原因才能送出。</p>}
      </div>
      <Actions>
        <Button variant="primary" disabled={busy} onClick={submit}>
          {hidden ? '放回 App' : '結案'}
        </Button>
        <Button variant="quiet" onClick={onClose}>
          返回
        </Button>
      </Actions>
      <span className="t-caption">按下後有 5 秒可以取消。</span>
    </Panel>
  );
}

export function KeepPanel({
  sheet,
  draft,
  onDraft,
  busy,
  onClose,
  onSubmit,
  item,
  count,
}: PanelContext & { item: TimedCase; count: number; onSubmit: (newName: string | null) => void }) {
  const id = useId();
  const [showError, setShowError] = useState(false);
  const needsName = NEEDS_NEW_NAME.has(item.kind);
  const name = draft.keepName ?? '';
  const nameMissing = needsName && (name.trim() === '' || name.trim() === NAME_PLACEHOLDER);
  const submit = () => {
    if (nameMissing) {
      setShowError(true);
      return;
    }
    onSubmit(needsName ? name.trim() : null);
  };
  return (
    <Panel title="檢舉成立" sheet={sheet} onClose={onClose}>
      <p>
        目前原文和檢舉當下的內容都不會再顯示。這 <span className="num">{count}</span> 則檢舉一起結案。
      </p>
      {needsName && (
        <div className="case-field">
          <label htmlFor={`${id}-name`} className="t-label">
            新的停車點名稱
          </label>
          <input
            id={`${id}-name`}
            type="text"
            maxLength={100}
            value={name}
            aria-invalid={(showError && nameMissing) || undefined}
            onChange={(event) => onDraft({ keepName: event.target.value })}
          />
          <span className="t-caption">必填。App 會改顯示這個名稱。</span>
          {showError && nameMissing && (
            <p className="case-field-error">請填新的名稱，不能用「{NAME_PLACEHOLDER}」。</p>
          )}
        </div>
      )}
      <Actions>
        <Button variant="destructive" disabled={busy} onClick={submit}>
          {keepButtonLabel(item.kind)}
        </Button>
        <Button variant="quiet" onClick={onClose}>
          返回
        </Button>
      </Actions>
      <span className="t-caption">按下後有 10 秒可以取消，之後不能復原。</span>
    </Panel>
  );
}

export function EditPanel({
  sheet,
  draft,
  onDraft,
  busy,
  onClose,
  onSubmit,
  report,
  hidden,
}: PanelContext & {
  report: ContentReport;
  hidden: boolean;
  onSubmit: (patch: Record<string, string>) => void;
}) {
  const id = useId();
  const edits = draft.edits ?? {};
  const original = report.current as Record<string, string | null | undefined>;
  const valueOf = (field: string) => edits[field] ?? original[field] ?? '';
  const changed = report.editable_fields.filter(
    (field) => valueOf(field).trim() !== (original[field] ?? '').trim(),
  );
  const blanked = changed.filter((field) => valueOf(field).trim() === '');
  const ready = changed.length > 0 && blanked.length === 0;
  return (
    <Panel title="改內容" sheet={sheet} onClose={onClose}>
      <p>從目前原文開始改，改好的內容會放回 App。</p>
      {report.editable_fields.map((field) => {
        const isChanged = changed.includes(field);
        return (
          <div key={field} className="case-field">
            <label htmlFor={`${id}-${field}`} className="t-label">
              {reportFieldLabel(field)}
            </label>
            <input
              id={`${id}-${field}`}
              type="text"
              maxLength={field === 'name' ? 100 : 500}
              value={valueOf(field)}
              className={isChanged ? 'is-changed' : undefined}
              onChange={(event) => onDraft({ edits: { ...edits, [field]: event.target.value } })}
            />
            {isChanged && <span className="modified-tag case-field__tag">已修改</span>}
          </div>
        );
      })}
      {blanked.length > 0 && <p className="case-field-error">不能留空；要移除文字請用檢舉成立。</p>}
      <Actions>
        <Button
          variant="primary"
          disabled={busy || !ready}
          onClick={() => onSubmit(Object.fromEntries(changed.map((f) => [f, valueOf(f).trim()])))}
        >
          {hidden ? '儲存並放回' : '儲存並結案'}
        </Button>
        <Button variant="quiet" onClick={onClose}>
          返回
        </Button>
      </Actions>
      <span className="t-caption">按下後有 5 秒可以取消。</span>
    </Panel>
  );
}
