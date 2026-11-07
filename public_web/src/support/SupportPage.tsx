import { useEffect, useRef, useState, type FormEvent, type RefObject } from 'react';
import { Link, useLocation } from 'react-router';
import { FlowPanel } from '../deletion/FlowPanel';
import { Site } from '../ui/Site';
import type { AccountHint, PrivacyRight, SubmitResult, SupportKind, SupportSubmission } from './client';
import { isEmail, supportCode } from './format';
import { useSupport } from './SupportContext';
import { Field } from './SupportFields';
import * as t from './text';
import './Support.css';

/** The header's way back (the board's back arrow, labelled the same), for the deletion kind. */
const backToExplanation = <Link to="/account-deletion">返回刪除帳號說明</Link>;

const defaultKind: SupportKind = 'general';

/** The kind `?kind=` names; an unknown value is ignored. */
function kindOf(search: string): SupportKind {
  const wanted = new URLSearchParams(search).get('kind');
  return t.kindOptions.find((option) => option.value === wanted)?.value ?? defaultKind;
}

const verified = (kind: SupportKind) => kind === 'account_deletion' || kind === 'privacy';

/** What the page says after a request is stored, the same whether or not an account matched. */
function receipt(kind: SupportKind, id: string): { title: string; body: readonly string[] } {
  const code = supportCode(id);
  if (kind === 'account_deletion') return { title: t.receivedTitle(code), body: t.receivedBody };
  if (kind === 'privacy') return { title: t.privacyReceivedTitle(code), body: t.privacyReceivedBody };
  return { title: t.caseReceivedTitle(t.kindNames[kind]!, code), body: t.caseReceivedBody };
}

/**
 * /support (canvas boards SupportKinds and PhoneSupportKinds): the kinds, and
 * the selected kind's form. It needs App Check but no sign-in; without App
 * Check settings it is not offered.
 */
export function SupportPage() {
  const support = useSupport();
  const location = useLocation();
  const [received, setReceived] = useState<{ kind: SupportKind; id: string } | null>(null);
  // A link to this page (the footer's 聯絡我們) starts over from the receipt.
  const [seen, setSeen] = useState(location.key);
  if (location.key !== seen) {
    setSeen(location.key);
    setReceived(null);
  }

  if (received) {
    const { title, body } = receipt(received.kind, received.id);
    return (
      <FlowPanel title={title} aside={received.kind === 'account_deletion' ? backToExplanation : undefined}>
        <div className="support-box support-box--done" role="status">
          {body.map((line) => (
            <p key={line}>{line}</p>
          ))}
        </div>
      </FlowPanel>
    );
  }
  const submit = support?.submit ?? null;
  if (!submit) {
    return (
      <FlowPanel title={t.supportTitle}>
        <p className="support-box support-box--muted" role="status">
          {t.formUnavailable}
        </p>
      </FlowPanel>
    );
  }
  return <SupportDesk submit={submit} onReceived={(kind, id) => setReceived({ kind, id })} />;
}

type Failure = Exclude<SubmitResult, { kind: 'received' }>['kind'];
type HintChoice = AccountHint | 'unknown';

function failureCopy(kind: SupportKind, failure: Failure): { title: string; body: string } {
  switch (failure) {
    case 'appCheck':
      return { title: t.appCheckTitle, body: t.appCheckBody };
    case 'rateLimited':
      return {
        title: t.rateLimitedTitle,
        body: verified(kind) ? t.rateLimitedBody : t.caseRateLimitedBody,
      };
    case 'network':
      return { title: t.networkTitle, body: t.networkBody };
    case 'unavailable':
      return { title: t.unavailableTitle, body: t.unavailableBody };
  }
}

/** Everything typed so far: a field keeps its text across the kinds that have it. */
interface Draft {
  login: string;
  contact: string;
  subject: string;
  message: string;
  hint: HintChoice | null;
  right: PrivacyRight | null;
}

type FieldName = 'login' | 'contact' | 'subject' | 'right' | 'message';

/** Each kind's checked fields, in the order the form shows them. */
const fieldsOf = (kind: SupportKind): FieldName[] => {
  if (kind === 'account_deletion') return ['login', 'contact', 'message'];
  if (kind === 'privacy') return ['contact', 'subject', 'login', 'right', 'message'];
  return ['contact', 'subject', 'message'];
};

function emailError(value: string, missing: string): string | null {
  if (!value.trim()) return missing;
  return isEmail(value) ? null : t.emailIncomplete;
}

function fieldError(field: FieldName, kind: SupportKind, draft: Draft): string | null {
  switch (field) {
    case 'login':
      return emailError(draft.login, t.loginMissing);
    case 'contact':
      return emailError(draft.contact, t.contactMissing);
    case 'subject':
      return draft.subject.trim() ? null : t.subjectMissing;
    case 'right':
      return draft.right ? null : t.privacyRightMissing;
    case 'message':
      // The deletion form's text is optional, but shorter than the other
      // kinds' (counted as the backend counts it).
      if (kind === 'account_deletion') {
        return [...draft.message.trim()].length > t.messageMax ? t.messageTooLong : null;
      }
      return draft.message.trim() ? null : t.contentMissing;
  }
}

function submission(kind: SupportKind, draft: Draft): SupportSubmission {
  const contactEmail = draft.contact.trim();
  const loginEmail = draft.login.trim();
  const subject = draft.subject.trim();
  const message = draft.message.trim();
  if (kind === 'account_deletion') {
    const hint = draft.hint === 'google' || draft.hint === 'apple' ? draft.hint : null;
    return { kind, loginEmail, contactEmail, hint, message };
  }
  if (kind === 'privacy') return { kind, loginEmail, contactEmail, right: draft.right!, subject, message };
  return { kind, contactEmail, subject, message };
}

function SupportDesk({
  submit,
  onReceived,
}: {
  submit: (submission: SupportSubmission) => Promise<SubmitResult>;
  onReceived: (kind: SupportKind, id: string) => void;
}) {
  const { search } = useLocation();
  const [kind, setKind] = useState(() => kindOf(search));
  const [draft, setDraft] = useState<Draft>({
    login: '',
    contact: '',
    subject: '',
    message: '',
    hint: null,
    right: null,
  });
  // Errors show once the rider tried to send, then follow each change.
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<Failure | null>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const refs = {
    login: useRef<HTMLInputElement>(null),
    contact: useRef<HTMLInputElement>(null),
    subject: useRef<HTMLInputElement>(null),
    right: useRef<HTMLInputElement>(null),
    message: useRef<HTMLTextAreaElement>(null),
  };

  useEffect(() => {
    heading.current?.focus();
  }, []);

  function choose(next: SupportKind) {
    setKind(next);
    // The new kind starts clean: its empty fields are not mistakes yet, and a
    // failure's words may be another kind's.
    setTried(false);
    setFailure(null);
  }

  // A link to this page with another ?kind= (the footer's 聯絡我們).
  const [seenSearch, setSeenSearch] = useState(search);
  if (search !== seenSearch) {
    setSeenSearch(search);
    choose(kindOf(search));
  }

  const change = (patch: Partial<Draft>) => setDraft((current) => ({ ...current, ...patch }));
  const error = (field: FieldName) => (tried ? fieldError(field, kind, draft) : null);

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (busy) return;
    setTried(true);
    const wrong = fieldsOf(kind).find((field) => fieldError(field, kind, draft));
    if (wrong) {
      refs[wrong].current?.focus();
      return;
    }
    setBusy(true);
    setFailure(null);
    const result = await submit(submission(kind, draft));
    setBusy(false);
    if (result.kind === 'received') onReceived(kind, result.id);
    else setFailure(result.kind);
  }

  const deletion = kind === 'account_deletion';
  const fields = { draft, change, error, refs };
  return (
    <Site aside={deletion ? backToExplanation : undefined}>
      <div className="support-desk">
        <div className="support-desk-kinds">
          <div className="support-desk-intro">
            <h1 ref={heading} tabIndex={-1}>
              {t.supportTitle}
            </h1>
            <p>{t.supportIntro}</p>
          </div>
          <fieldset className="support-kinds">
            <legend>{t.kindLegend}</legend>
            {t.kindOptions.map((option) => (
              <KindChoice
                key={option.value}
                option={option}
                checked={kind === option.value}
                onChoose={() => choose(option.value)}
              />
            ))}
          </fieldset>
        </div>
        <form className="support-desk-form" noValidate onSubmit={onSubmit} aria-busy={busy}>
          {deletion ? (
            <>
              <h2>{t.formTitle}</h2>
              <p>
                {t.formIntro.before}
                <b>{t.formIntro.bold}</b>
                {t.formIntro.after}
              </p>
              <p className="support-warning">{t.formWarning}</p>
              <DeletionFields {...fields} />
            </>
          ) : (
            <>
              {/* The phone board has no heading here: the choice sits right above. */}
              <h2 className="support-desk-title">{t.kindNames[kind]}</h2>
              <CaseFields {...fields} privacy={kind === 'privacy'} />
            </>
          )}
          {failure ? (
            <div className="support-box support-box--error" role="alert">
              <h2>{failureCopy(kind, failure).title}</h2>
              <p>{failureCopy(kind, failure).body}</p>
            </div>
          ) : null}
          <div className="support-actions">
            <button
              type="submit"
              className="flow-button flow-button--primary"
              aria-disabled={busy || undefined}
            >
              {deletion ? t.submit : t.caseSubmit}
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
      </div>
    </Site>
  );
}

/** A real radio, drawn as the board's card; the description is not part of its name. */
function KindChoice({
  option,
  checked,
  onChoose,
}: {
  option: (typeof t.kindOptions)[number];
  checked: boolean;
  onChoose: () => void;
}) {
  const id = `support-kind-${option.value}`;
  return (
    <label className={`support-kind${checked ? ' support-kind--on' : ''}`}>
      <input
        type="radio"
        name="kind"
        value={option.value}
        checked={checked}
        onChange={onChoose}
        aria-labelledby={`${id}-name`}
        aria-describedby={`${id}-text`}
      />
      <span>
        <b id={`${id}-name`}>{option.label}</b>
        <span id={`${id}-text`}>{option.description}</span>
      </span>
    </label>
  );
}

interface FieldProps {
  draft: Draft;
  change: (patch: Partial<Draft>) => void;
  error: (field: FieldName) => string | null;
  refs: {
    login: RefObject<HTMLInputElement | null>;
    contact: RefObject<HTMLInputElement | null>;
    subject: RefObject<HTMLInputElement | null>;
    right: RefObject<HTMLInputElement | null>;
    message: RefObject<HTMLTextAreaElement | null>;
  };
}

/** The approved deletion form (canvas version 20). */
function DeletionFields({ draft, change, error, refs }: FieldProps) {
  return (
    <>
      <EmailField
        inputRef={refs.login}
        label={t.loginLabel}
        note={t.loginRequired}
        help={t.loginHelp}
        value={draft.login}
        onChange={(login) => change({ login })}
        error={error('login')}
      />
      <fieldset className="support-choices">
        <legend>{t.providerLegend}</legend>
        {t.providerOptions.map((option) => (
          <label key={option.value} className="support-choice">
            <input
              type="radio"
              name="provider"
              value={option.value}
              checked={draft.hint === option.value}
              onChange={() => change({ hint: option.value })}
            />
            {option.label}
          </label>
        ))}
      </fieldset>
      <EmailField
        inputRef={refs.contact}
        label={t.contactLabel}
        note={t.contactRequired}
        help={t.contactHelp}
        value={draft.contact}
        onChange={(contact) => change({ contact })}
        error={error('contact')}
      />
      <Field label={t.messageLabel} note={t.messageOptional} error={error('message')}>
        {(described) => (
          <textarea
            {...described}
            ref={refs.message}
            rows={3}
            maxLength={t.messageMax}
            value={draft.message}
            onChange={(event) => change({ message: event.target.value })}
          />
        )}
      </Field>
    </>
  );
}

/**
 * The form of the other kinds. A privacy request also takes the login email
 * and the right, above the text (PhoneSupportKinds). Its contact email only
 * gets the fixed receipt, so it has the deletion form's words: the answer goes
 * to the login email.
 */
function CaseFields({ draft, change, error, refs, privacy }: FieldProps & { privacy: boolean }) {
  const rightError = error('right');
  return (
    <>
      <EmailField
        inputRef={refs.contact}
        label={t.contactLabel}
        note={privacy ? t.contactRequired : t.caseContactNote}
        help={privacy ? t.contactHelp : t.caseContactHelp}
        helpAbove
        value={draft.contact}
        onChange={(contact) => change({ contact })}
        error={error('contact')}
      />
      <Field label={t.subjectLabel} note={t.subjectNote} helpAbove error={error('subject')}>
        {(described) => (
          <input
            {...described}
            ref={refs.subject}
            type="text"
            required
            maxLength={t.subjectMax}
            value={draft.subject}
            onChange={(event) => change({ subject: event.target.value })}
          />
        )}
      </Field>
      {privacy ? (
        <>
          <EmailField
            inputRef={refs.login}
            label={t.loginLabel}
            note={t.privacyLoginNote}
            help={t.privacyLoginHelp}
            helpAbove
            value={draft.login}
            onChange={(login) => change({ login })}
            error={error('login')}
          />
          <fieldset
            className="support-choices support-choices--cards"
            aria-describedby={rightError ? 'support-right-error' : undefined}
          >
            <legend>{t.privacyRightLegend}</legend>
            {t.privacyRightOptions.map((option, index) => (
              <label
                key={option.value}
                className={`support-kind${draft.right === option.value ? ' support-kind--on' : ''}`}
              >
                <input
                  ref={index === 0 ? refs.right : undefined}
                  type="radio"
                  name="right"
                  value={option.value}
                  checked={draft.right === option.value}
                  onChange={() => change({ right: option.value })}
                />
                <b>{option.label}</b>
              </label>
            ))}
            {rightError ? (
              <span id="support-right-error" className="support-field-error">
                {rightError}
              </span>
            ) : null}
          </fieldset>
        </>
      ) : null}
      <Field
        label={t.contentLabel}
        note={t.contentNote}
        help={t.contentHelp}
        helpAbove
        error={error('message')}
      >
        {(described) => (
          <textarea
            {...described}
            ref={refs.message}
            rows={6}
            required
            maxLength={t.contentMax}
            value={draft.message}
            onChange={(event) => change({ message: event.target.value })}
          />
        )}
      </Field>
    </>
  );
}

function EmailField({
  inputRef,
  label,
  note,
  help,
  helpAbove,
  value,
  onChange,
  error,
}: {
  inputRef: RefObject<HTMLInputElement | null>;
  label: string;
  note: string;
  help: string;
  helpAbove?: boolean;
  value: string;
  onChange: (value: string) => void;
  error: string | null;
}) {
  return (
    <Field label={label} note={note} help={help} helpAbove={helpAbove} error={error}>
      {(described) => (
        <input
          {...described}
          ref={inputRef}
          type="email"
          autoComplete="email"
          inputMode="email"
          required
          value={value}
          onChange={(event) => onChange(event.target.value)}
        />
      )}
    </Field>
  );
}
