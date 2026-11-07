import { useId, type ReactNode } from 'react';

/** What an input needs to be tied to its label, help and error. */
interface Described {
  id: string;
  'aria-invalid'?: true;
  'aria-describedby'?: string;
}

/**
 * A labelled field. The kinds' boards put the note and the help between the
 * label and the input (`helpAbove`); the deletion form has the note beside the
 * label and the help under the input.
 */
export function Field({
  label,
  note,
  help,
  helpAbove = false,
  error = null,
  children,
}: {
  label: string;
  note: string;
  help?: string;
  helpAbove?: boolean;
  error?: string | null;
  children: (described: Described) => ReactNode;
}) {
  const id = useId();
  const described = [error ? `${id}-err` : null, help || helpAbove ? `${id}-help` : null]
    .filter(Boolean)
    .join(' ');
  return (
    <div className="support-field">
      <label htmlFor={id}>
        {label} {helpAbove ? null : <span className="support-field-note">{note}</span>}
      </label>
      {helpAbove ? (
        <span id={`${id}-help`} className="support-field-help">
          {note}
          {help}
        </span>
      ) : null}
      {children({
        id,
        ...(error ? { 'aria-invalid': true as const } : {}),
        ...(described ? { 'aria-describedby': described } : {}),
      })}
      {error ? (
        <span id={`${id}-err`} className="support-field-error">
          {error}
        </span>
      ) : null}
      {help && !helpAbove ? (
        <span id={`${id}-help`} className="support-field-help">
          {help}
        </span>
      ) : null}
    </div>
  );
}
