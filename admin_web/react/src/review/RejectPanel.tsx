import { useEffect, useId, useRef } from 'react';
import { Button } from '../ui/controls';
import { needsRejectNote, RESOLUTION_KINDS, type ResolutionKind } from './model';

interface RejectPanelProps {
  kind: ResolutionKind | null;
  onKind: (kind: ResolutionKind) => void;
  note: string;
  onNote: (note: string) => void;
  /** Set after a confirm attempt, so a missing reason is pointed out. */
  showErrors: boolean;
  /** Phones get a bottom sheet with its own buttons (ReviewRejectPhone.dc.html). */
  sheet: boolean;
  spotName: string;
  onConfirm: () => void;
  onCancel: () => void;
}

/**
 * 駁回原因 (ReviewReject.dc.html): one of six reasons is required, and
 * 「其他原因」 needs a written reason. Native radios give arrow keys and
 * screen-reader grouping; 1–6, Enter and Esc are handled by the detail.
 */
export function RejectPanel({
  kind,
  onKind,
  note,
  onNote,
  showErrors,
  sheet,
  spotName,
  onConfirm,
  onCancel,
}: RejectPanelProps) {
  const id = useId();
  const firstRadio = useRef<HTMLInputElement>(null);
  const noteMissing = needsRejectNote(kind, note);
  const kindMissing = showErrors && kind === null;

  // Opening the panel puts the keyboard on the reasons.
  useEffect(() => {
    firstRadio.current?.focus();
  }, []);

  const reasons = (
    <fieldset
      className={`reject-reasons${kindMissing ? ' is-invalid' : ''}`}
      aria-describedby={kindMissing ? `${id}-kind-err` : undefined}
    >
      <legend className={sheet ? 'visually-hidden' : 'reject-panel__legend'}>
        <span className="t-title">
          駁回原因 <span className="required-mark">*</span>
        </span>
        {!sheet && (
          <span className="t-caption">
            選一個；會寫入稽核紀錄。按 <kbd>1</kbd>–<kbd>6</kbd> 直接選
          </span>
        )}
      </legend>
      <div className="reject-reasons__grid">
        {RESOLUTION_KINDS.map((reason, index) => (
          <label key={reason.kind} className="reject-reason">
            <input
              ref={index === 0 ? firstRadio : undefined}
              type="radio"
              name={`${id}-kind`}
              value={reason.kind}
              checked={kind === reason.kind}
              onChange={() => onKind(reason.kind)}
              className="reject-reason__input"
            />
            <span className="reject-reason__dot" aria-hidden="true" />
            <span className="reject-reason__text">
              <span className="reject-reason__label">{reason.label}</span>
              {!sheet && <span className="t-caption">{reason.description}</span>}
            </span>
            {!sheet && <kbd aria-hidden="true">{index + 1}</kbd>}
          </label>
        ))}
      </div>
      {kindMissing && (
        <p id={`${id}-kind-err`} className="field-error">
          選一個駁回原因才能送出。
        </p>
      )}
    </fieldset>
  );

  const noteField = (
    <div className="reject-panel__note">
      <label htmlFor={`${id}-note`} className="t-title">
        處理說明{' '}
        {kind === 'other' ? (
          <span className="required-tag">必填</span>
        ) : (
          <span className="muted reject-panel__optional">選填；選「其他原因」時必填</span>
        )}
      </label>
      <textarea
        id={`${id}-note`}
        rows={2}
        maxLength={500}
        value={note}
        placeholder="例如：現場標線是普通機車專用，沒有重機標示"
        aria-invalid={noteMissing || undefined}
        aria-describedby={noteMissing ? `${id}-note-err` : undefined}
        className={noteMissing ? 'is-invalid' : undefined}
        onChange={(event) => onNote(event.target.value)}
      />
      {noteMissing && (
        <p id={`${id}-note-err`} className="field-error">
          選了「其他原因」，寫下為什麼駁回才能送出。
        </p>
      )}
    </div>
  );

  if (!sheet) {
    return (
      <section className="panel reject-panel" aria-label="駁回原因">
        {reasons}
        {noteField}
      </section>
    );
  }

  return (
    <div className="sheet-scrim" onClick={onCancel}>
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby={`${id}-title`}
        className="sheet reject-panel reject-panel--sheet"
        onClick={(event) => event.stopPropagation()}
      >
        <span className="sheet__grip" aria-hidden="true" />
        <div>
          <h2 id={`${id}-title`} className="t-headline">
            駁回這筆回報
          </h2>
          <p className="t-caption">{`${spotName}，點位不會改變`}</p>
        </div>
        {reasons}
        {noteField}
        <div className="sheet__actions">
          <Button onClick={onCancel}>取消</Button>
          <Button variant="danger" onClick={onConfirm}>
            確定駁回
          </Button>
        </div>
      </section>
    </div>
  );
}
