import { useEffect, useId, useRef, useState } from 'react';
import { Button, ModifiedTag } from '../ui/controls';
import { STATUS_LABEL, VEHICLE_LABEL, VEHICLES } from '../ui/eligibility';
import { PlateStack } from '../ui/PlateStack';
import {
  allowsKey,
  DIFF_FIELDS,
  differs,
  EDIT_FIELDS,
  hasStructuredFee,
  plateOf,
  type EditInput,
  type ReviewReport,
  type ReviewSpot,
} from './model';

interface EditPanelProps {
  report: ReviewReport;
  spot: ReviewSpot;
  values: Record<string, unknown>;
  onChange: (key: string, value: unknown) => void;
  errors: Record<string, string>;
  /** Set after a save attempt, so errors show even on untouched fields. */
  showErrors: boolean;
}

/** Shows a stored value the way the diff table does. */
function shown(key: string, value: unknown): string {
  return DIFF_FIELDS.find((f) => f.key === key)?.format(value) ?? String(value ?? '沒有');
}

function FieldInput({
  id,
  input,
  value,
  onChange,
  invalid,
  describedBy,
  disabled = false,
}: {
  id: string;
  disabled?: boolean;
  input: EditInput;
  value: unknown;
  onChange: (value: unknown) => void;
  invalid: boolean;
  describedBy: string;
}) {
  const common = { id, disabled, 'aria-invalid': invalid || undefined, 'aria-describedby': describedBy };
  switch (input.type) {
    case 'text':
      return (
        <input
          {...common}
          type="text"
          maxLength={input.maxLength}
          value={typeof value === 'string' ? value : ''}
          onChange={(event) => onChange(event.target.value)}
        />
      );
    case 'choice':
      return (
        <select
          {...common}
          value={typeof value === 'string' ? value : ''}
          onChange={(e) => onChange(e.target.value || null)}
        >
          {!input.required && <option value="">沒有</option>}
          {Object.entries(input.choices).map(([key, label]) => (
            <option key={key} value={key}>
              {label}
            </option>
          ))}
        </select>
      );
    case 'coordinate':
      return (
        <input
          {...common}
          type="number"
          inputMode="decimal"
          step="0.000001"
          min={input.min}
          max={input.max}
          value={typeof value === 'number' && !Number.isNaN(value) ? value : ''}
          onChange={(event) => onChange(event.target.value === '' ? Number.NaN : Number(event.target.value))}
        />
      );
    case 'visibility':
      return null;
  }
}

/**
 * 修改後套用 (ReviewEdit.dc.html): plate tiles for eligibility and an
 * editable 套用值 column. Yellow still means "differs from the spot now";
 * the line under each value says what the rider suggested.
 */
export function EditPanel({ report, spot, values, onChange, errors, showErrors }: EditPanelProps) {
  const id = useId();
  const proposed = report.proposed ?? {};
  const [showAll, setShowAll] = useState(false);
  const firstControl = useRef<HTMLDivElement>(null);

  useEffect(() => {
    firstControl.current?.querySelector<HTMLElement>('input, select')?.focus();
  }, []);

  const vehicles = VEHICLES.filter((v) => {
    const key = `${v}_allowed`;
    return key in proposed || showAll || (key in values && differs(key, values[key], spot.values[key]));
  });
  const fields = EDIT_FIELDS.filter(({ key }) => {
    if (!allowsKey(spot, key) || !(key in values)) return false;
    return showAll || key in proposed || differs(key, values[key], spot.values[key]);
  });
  const hiddenCount =
    EDIT_FIELDS.filter(({ key }) => allowsKey(spot, key) && key in values).length - fields.length;

  const riderLine = (key: string) => {
    if (key in proposed) return `騎士建議：${shown(key, proposed[key])}`;
    return differs(key, values[key], spot.values[key])
      ? '騎士沒有建議這一欄；是你加的'
      : '騎士沒有建議這一欄';
  };

  return (
    <div className="edit-panel" ref={firstControl}>
      {vehicles.length > 0 && (
        <section className="panel edit-panel__plates" aria-label="資格">
          {vehicles.map((vehicle) => {
            const key = `${vehicle}_allowed`;
            const current = plateOf(spot.values[key]);
            const error = errors[key];
            return (
              <fieldset key={vehicle} className="plate-pick" aria-describedby={`${id}-${key}-hint`}>
                <legend className="t-title">
                  {VEHICLE_LABEL[vehicle]} <span className="required-mark">*</span>
                </legend>
                <div className="plate-pick__options">
                  {([true, false] as const).map((allowed) => (
                    <label key={String(allowed)} className="plate-pick__option">
                      <input
                        type="radio"
                        name={`${id}-${key}`}
                        checked={values[key] === allowed}
                        onChange={() => onChange(key, allowed)}
                      />
                      <PlateStack
                        vehicle={vehicle}
                        status={allowed ? 'allowed' : 'denied'}
                        label={VEHICLE_LABEL[vehicle]}
                      />
                      {allowed ? '可停' : '不可停'}
                    </label>
                  ))}
                </div>
                <p id={`${id}-${key}-hint`} className={showErrors && error ? 'field-error' : 't-caption'}>
                  {showErrors && error
                    ? '選可停或不可停才能儲存。'
                    : `目前${STATUS_LABEL[current]}${key in proposed ? `；騎士建議${STATUS_LABEL[plateOf(proposed[key])]}` : ''}。${
                        spot.official ? '' : '社群點只能選可停或不可停。'
                      }`}
                </p>
              </fieldset>
            );
          })}
        </section>
      )}

      <section className="panel edit-fields" aria-label="其他欄位">
        <div className="edit-fields__head" aria-hidden="true">
          <span>欄位</span>
          <span>目前</span>
          <span>套用值</span>
        </div>
        {fields.map(({ key, label, input }) => {
          const fieldId = `${id}-${key}`;
          const changed = differs(key, values[key], spot.values[key]);
          // fee_note is generated from a structured fee; the server refuses other text.
          const locked = key === 'fee_note' && hasStructuredFee(spot);
          const error = errors[key];
          const invalid = Boolean(error) && (showErrors || changed);
          return (
            <div key={key} className="edit-field">
              <label htmlFor={fieldId} className="edit-field__label t-title">
                {label}
              </label>
              <span className="edit-field__current muted">
                <span className="edit-field__phone-only">目前：</span>
                {shown(key, spot.values[key])}
              </span>
              <div
                className={`edit-field__value${changed ? ' is-changed' : ''}${invalid ? ' is-invalid' : ''}`}
              >
                {input.type === 'visibility' ? (
                  <select
                    id={fieldId}
                    value={
                      (key === 'hidden' ? values[key] === true : values[key] === 'hidden') ? 'hide' : 'show'
                    }
                    aria-describedby={`${fieldId}-hint`}
                    onChange={(event) =>
                      onChange(
                        key,
                        key === 'hidden'
                          ? event.target.value === 'hide'
                          : event.target.value === 'hide'
                            ? 'hidden'
                            : ((spot.values[key] === 'hidden' ? 'confirmed' : spot.values[key]) ??
                              'confirmed'),
                      )
                    }
                  >
                    <option value="show">顯示</option>
                    <option value="hide">隱藏</option>
                  </select>
                ) : (
                  <FieldInput
                    id={fieldId}
                    disabled={locked}
                    input={input}
                    value={values[key]}
                    invalid={invalid}
                    describedBy={`${fieldId}-hint`}
                    onChange={(value) => onChange(key, value)}
                  />
                )}
                <p id={`${fieldId}-hint`} className={invalid ? 'field-error' : 't-caption'}>
                  {invalid
                    ? error
                    : locked
                      ? '收費資訊由這個點位的結構化費率產生，不能在這裡改'
                      : riderLine(key)}
                  {changed && !invalid && <ModifiedTag />}
                </p>
              </div>
            </div>
          );
        })}
        {(hiddenCount > 0 || showAll) && (
          <Button variant="quiet" className="diff__toggle" onClick={() => setShowAll(!showAll)}>
            {showAll ? (
              '只顯示騎士建議與改過的欄位'
            ) : (
              <>
                也修改其他 <span className="num">{hiddenCount}</span> 個欄位
              </>
            )}
          </Button>
        )}
      </section>
    </div>
  );
}
