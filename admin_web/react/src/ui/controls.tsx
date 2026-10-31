import type { ButtonHTMLAttributes, ReactNode } from 'react';
import { LineIcon } from './icons';
import './controls.css';

type ButtonVariant = 'primary' | 'secondary' | 'destructive' | 'quiet';

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  /** Keyboard shortcut drawn as a key cap (A 套用、E 修改後套用…). */
  shortcut?: string;
}

/** 48px tool buttons (DESIGN.md Buttons). */
export function Button({ variant = 'secondary', shortcut, className, children, type, ...rest }: ButtonProps) {
  return (
    <button
      type={type ?? 'button'}
      className={['btn', `btn--${variant}`, className].filter(Boolean).join(' ')}
      aria-keyshortcuts={shortcut}
      {...rest}
    >
      {children}
      {shortcut && <kbd aria-hidden="true">{shortcut}</kbd>}
    </button>
  );
}

interface ChipProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'onChange'> {
  selected: boolean;
  /** `toggle`: multi-select layer switch (black frame, colour unchanged). */
  kind?: 'filter' | 'toggle';
  count?: number;
}

/** 44px pill filters. Single-select filters invert; layer toggles get a frame. */
export function Chip({ selected, kind = 'filter', count, className, children, ...rest }: ChipProps) {
  return (
    <button
      type="button"
      aria-pressed={selected}
      className={['chip', `chip--${kind}`, selected && 'chip--selected', className].filter(Boolean).join(' ')}
      {...rest}
    >
      {children}
      {count !== undefined && <span className="num">{count}</span>}
    </button>
  );
}

interface SegmentedOption<T extends string> {
  value: T;
  label: string;
  leading?: ReactNode;
}

interface SegmentedProps<T extends string> {
  label: string;
  options: readonly SegmentedOption<T>[];
  value: T;
  onChange: (value: T) => void;
}

/** One-of-n switch; the selected option is black with white text. */
export function Segmented<T extends string>({ label, options, value, onChange }: SegmentedProps<T>) {
  return (
    <div role="group" aria-label={label} className="segmented">
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          aria-pressed={option.value === value}
          className="segmented__option"
          onClick={() => onChange(option.value)}
        >
          {option.leading}
          {option.label}
        </button>
      ))}
    </div>
  );
}

type StatusKind = 'open' | 'closed' | 'deleted';

/** 20px status tags: 正常開放 (check), 施工中／暫時封閉 (inverted), 已刪除 (red). */
export function StatusTag({ kind, children }: { kind: StatusKind; children: ReactNode }) {
  return (
    <span className={`status-tag status-tag--${kind}`}>
      {kind === 'open' && <LineIcon name="check" size={12} strokeWidth={3.5} />}
      {children}
    </span>
  );
}

/** Reflective-yellow 「已修改」: only ever means "differs from the current value". */
export function ModifiedTag() {
  return <span className="modified-tag">已修改</span>;
}

/** 3px black-and-white source plate: 社群點／官方點. */
export function SourceTag({ source }: { source: 'community' | 'official' }) {
  return <span className="source-tag">{source === 'community' ? '社群點' : '官方點'}</span>;
}
