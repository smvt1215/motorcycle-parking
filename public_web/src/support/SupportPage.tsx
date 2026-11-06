import { useId, useRef, useState, type FormEvent, type ReactNode, type RefObject } from 'react';
import { Link } from 'react-router';
import { FlowPanel } from '../deletion/FlowPanel';
import type { AccountHint, SubmitResult, SupportSubmission } from './client';
import { isEmail, supportCode } from './format';
import { useSupport } from './SupportContext';
import * as t from './text';
import './Support.css';

/** The header's way back (the board's back arrow, labelled the same). */
export const backToExplanation = <Link to="/account-deletion">返回刪除帳號說明</Link>;

/**
 * /support, for riders who cannot sign in (canvas board PhoneSupport). The
 * form needs App Check but no sign-in; without App Check settings it is
 * not offered. Every stored request gets the same receipt, whether or not
 * an account matched.
 */
export function SupportPage() {
  const support = useSupport();
  const [receivedId, setReceivedId] = useState<string | null>(null);

  if (receivedId) {
    return (
      <FlowPanel title={t.receivedTitle(supportCode(receivedId))} aside={backToExplanation}>
        <div className="support-box support-box--done" role="status">
          {t.receivedBody.map((line) => (
            <p key={line}>{line}</p>
          ))}
        </div>
      </FlowPanel>
    );
  }
  const submit = support?.submit ?? null;
  return (
    <FlowPanel title={t.formTitle} aside={backToExplanation}>
      <p>
        {t.formIntro.before}
        <b>{t.formIntro.bold}</b>
        {t.formIntro.after}
      </p>
      <p className="support-warning">{t.formWarning}</p>
      {submit ? (
        <SupportForm submit={submit} onReceived={setReceivedId} />
      ) : (
        <p className="support-box support-box--muted" role="status">
          {t.formUnavailable}
        </p>
      )}
    </FlowPanel>
  );
}

type Failure = Exclude<SubmitResult, { kind: 'received' }>['kind'];
type HintChoice = AccountHint | 'unknown';

const failureCopy: Record<Failure, { title: string; body: string }> = {
  appCheck: { title: t.appCheckTitle, body: t.appCheckBody },
  rateLimited: { title: t.rateLimitedTitle, body: t.rateLimitedBody },
  network: { title: t.networkTitle, body: t.networkBody },
  unavailable: { title: t.unavailableTitle, body: t.unavailableBody },
};

function emailError(value: string, missing: string): string | null {
  if (!value.trim()) return missing;
  return isEmail(value) ? null : t.emailIncomplete;
}

function SupportForm({
  submit,
  onReceived,
}: {
  submit: (submission: SupportSubmission) => Promise<SubmitResult>;
  onReceived: (id: string) => void;
}) {
  const [login, setLogin] = useState('');
  const [contact, setContact] = useState('');
  const [hint, setHint] = useState<HintChoice | null>(null);
  const [message, setMessage] = useState('');
  // Errors show once the rider tried to send, then follow each change.
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<Failure | null>(null);
  const loginRef = useRef<HTMLInputElement>(null);
  const contactRef = useRef<HTMLInputElement>(null);

  const loginError = tried ? emailError(login, t.loginMissing) : null;
  const contactError = tried ? emailError(contact, t.contactMissing) : null;

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (busy) return;
    setTried(true);
    const loginWrong = emailError(login, t.loginMissing);
    const contactWrong = emailError(contact, t.contactMissing);
    if (loginWrong || contactWrong) {
      (loginWrong ? loginRef : contactRef).current?.focus();
      return;
    }
    setBusy(true);
    setFailure(null);
    const result = await submit({
      loginEmail: login.trim(),
      contactEmail: contact.trim(),
      hint: hint === 'google' || hint === 'apple' ? hint : null,
      message: message.trim(),
    });
    setBusy(false);
    if (result.kind === 'received') onReceived(result.id);
    else setFailure(result.kind);
  }

  return (
    <form className="support-form" noValidate onSubmit={onSubmit} aria-busy={busy}>
      <EmailField
        inputRef={loginRef}
        label={t.loginLabel}
        note={t.loginRequired}
        help={t.loginHelp}
        value={login}
        onChange={setLogin}
        error={loginError}
      />
      <fieldset className="support-choices">
        <legend>{t.providerLegend}</legend>
        {t.providerOptions.map((option) => (
          <label key={option.value} className="support-choice">
            <input
              type="radio"
              name="provider"
              value={option.value}
              checked={hint === option.value}
              onChange={() => setHint(option.value)}
            />
            {option.label}
          </label>
        ))}
      </fieldset>
      <EmailField
        inputRef={contactRef}
        label={t.contactLabel}
        note={t.contactRequired}
        help={t.contactHelp}
        value={contact}
        onChange={setContact}
        error={contactError}
      />
      <Field label={t.messageLabel} note={t.messageOptional}>
        {(id) => (
          <textarea
            id={id}
            rows={3}
            maxLength={t.messageMax}
            value={message}
            onChange={(event) => setMessage(event.target.value)}
          />
        )}
      </Field>
      {failure ? (
        <div className="support-box support-box--error" role="alert">
          <h2>{failureCopy[failure].title}</h2>
          <p>{failureCopy[failure].body}</p>
        </div>
      ) : null}
      <div className="support-actions">
        <button type="submit" className="flow-button flow-button--primary" aria-disabled={busy || undefined}>
          {t.submit}
        </button>
      </div>
      <p className="support-fine">
        {t.recaptcha.before}
        <a href="https://policies.google.com/privacy">{t.recaptcha.privacy}</a>
        {t.recaptcha.and}
        <a href="https://policies.google.com/terms">{t.recaptcha.terms}</a>
        {t.recaptcha.after}
        <a href="/privacy">{t.recaptcha.sitePrivacy}</a>
        {t.recaptcha.end}
      </p>
    </form>
  );
}

function Field({
  label,
  note,
  children,
}: {
  label: string;
  note: string;
  children: (id: string) => ReactNode;
}) {
  const id = useId();
  return (
    <div className="support-field">
      <label htmlFor={id}>
        {label} <span className="support-field-note">{note}</span>
      </label>
      {children(id)}
    </div>
  );
}

function EmailField({
  inputRef,
  label,
  note,
  help,
  value,
  onChange,
  error,
}: {
  inputRef: RefObject<HTMLInputElement | null>;
  label: string;
  note: string;
  help: string;
  value: string;
  onChange: (value: string) => void;
  error: string | null;
}) {
  const id = useId();
  return (
    <div className="support-field">
      <label htmlFor={id}>
        {label} <span className="support-field-note">{note}</span>
      </label>
      <input
        ref={inputRef}
        id={id}
        type="email"
        autoComplete="email"
        inputMode="email"
        required
        value={value}
        onChange={(event) => onChange(event.target.value)}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? `${id}-err ${id}-help` : `${id}-help`}
      />
      {error ? (
        <span id={`${id}-err`} className="support-field-error">
          {error}
        </span>
      ) : null}
      <span id={`${id}-help`} className="support-field-help">
        {help}
      </span>
    </div>
  );
}
