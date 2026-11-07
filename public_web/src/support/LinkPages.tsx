import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router';
import { deletionSupportPath } from '../content';
import { deletionDateLabel } from '../deletion/format';
import { FlowPanel } from '../deletion/FlowPanel';
import type {
  CancelAction,
  CancelResult,
  ConfirmAction,
  ConfirmAnswer,
  LinkAnswer,
  LinkOutcome,
  PrivacyDetails,
} from './client';
import { linkToken, submittedLabel, supportCode } from './format';
import { useSupport } from './SupportContext';
import * as t from './text';
import './Support.css';

/**
 * The link's token, read once from the fragment; the fragment is then
 * dropped from the address bar (a replace, so not in the history either)
 * so the token is left in no history entry, bookmark or referrer.
 */
export function useLinkToken() {
  const location = useLocation();
  const navigate = useNavigate();
  const [token] = useState(() => linkToken(location.hash));
  useEffect(() => {
    if (location.hash) navigate({ pathname: location.pathname, search: location.search }, { replace: true });
  }, [location.hash, location.pathname, location.search, navigate]);
  return token;
}

/**
 * A number that changes when another link is opened in a tab already on the
 * page: only the fragment changes then, with no reload. Used as a key, the
 * page starts over with that token instead of acting on the previous
 * request. Dropping the fragment from the address changes nothing.
 */
export function useLinkKey() {
  const { hash } = useLocation();
  const [seen, setSeen] = useState({ hash, key: 0 });
  if (hash !== seen.hash) setSeen({ hash, key: hash ? seen.key + 1 : seen.key });
  return hash && hash !== seen.hash ? seen.key + 1 : seen.key;
}

/** /support/verify (the confirmation mail's link). */
export function VerifyPage() {
  return <VerifyLink key={useLinkKey()} />;
}

/** /support/cancel (the status mail's link). */
export function CancelPage() {
  return <CancelLink key={useLinkKey()} />;
}

type Answered<L> = Extract<L, { kind: 'answer' }>;
type Phase<L, A> =
  | { kind: 'loading' }
  | { kind: 'invalid' }
  | { kind: 'answer'; answer: Answered<L> }
  /** No answer, or a failed one: `action` is what 重試 sends again. */
  | { kind: 'failed'; network: boolean; action: A };

/**
 * One link page's calls: `view` on opening (it changes nothing, so mail
 * scanners that open links do no harm), every other action only from a
 * button.
 */
export function useLink<L extends LinkOutcome, A extends string>(
  call: ((token: string, action: A) => Promise<L>) | null,
  token: string | null,
  view: A,
) {
  const [phase, setPhase] = useState<Phase<L, A>>(() =>
    !token
      ? { kind: 'invalid' }
      : !call
        ? { kind: 'failed', network: false, action: view }
        : { kind: 'loading' },
  );
  const [busy, setBusy] = useState(false);
  const run = useCallback(
    async (action: A) => {
      if (!call || !token) return;
      setBusy(true);
      const answer = await call(token, action);
      setBusy(false);
      if (answer.kind === 'answer') {
        setPhase({ kind: 'answer', answer: answer as Answered<L> });
      } else if (answer.kind === 'invalid') {
        setPhase({ kind: 'invalid' });
      } else {
        setPhase({ kind: 'failed', network: answer.kind === 'network', action });
      }
    },
    [call, token],
  );
  // Once per page, also under StrictMode's second effect run.
  const viewed = useRef(false);
  useEffect(() => {
    if (viewed.current || !call || !token) return;
    viewed.current = true;
    void run(view);
  }, [call, token, run, view]);
  return { phase, busy, run };
}

function Rows({ rows }: { rows: [string, string][] }) {
  return (
    <dl className="support-rows">
      {rows.map(([term, value]) => (
        <div key={term}>
          <dt>{term}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}

export function Loading() {
  return (
    <FlowPanel title={t.loading}>
      <p className="flow-note" role="status">
        {t.loading}
      </p>
    </FlowPanel>
  );
}

export function Failed({ network, onRetry, busy }: { network: boolean; onRetry: () => void; busy: boolean }) {
  return (
    <FlowPanel title={network ? t.linkNetworkTitle : t.linkErrorTitle}>
      <p role="alert">{network ? t.linkNetworkBody : t.linkErrorBody}</p>
      <div className="support-actions">
        <button
          type="button"
          className="flow-button flow-button--primary"
          aria-disabled={busy || undefined}
          onClick={() => !busy && onRetry()}
        >
          {t.retry}
        </button>
      </div>
    </FlowPanel>
  );
}

/** `refill`: where 重新填寫客服表單 goes, on the pages that offer it. */
function Message({ title, body, refill }: { title: string; body: string; refill?: string }) {
  return (
    <FlowPanel title={title}>
      <p>{body}</p>
      {refill ? (
        <Link to={refill} className="flow-link">
          {t.refillForm}
        </Link>
      ) : null}
    </FlowPanel>
  );
}

/**
 * /support/verify#token=…, the confirmation mail's link (canvas board
 * PhoneVerify): shows the request, and asks for the deletion only when the
 * owner presses 「是我，申請刪除帳號」. A privacy request has its own words.
 */
function VerifyLink() {
  const support = useSupport();
  const link = useLinkToken();
  const { phase, busy, run } = useLink<ConfirmAnswer, ConfirmAction>(
    support?.confirmLink ?? null,
    link?.token ?? null,
    'view',
  );
  if (phase.kind === 'loading') return <Loading />;
  if (phase.kind === 'invalid')
    return <Message title={t.verifyInvalidTitle} body={t.verifyInvalidBody} refill="/support" />;
  if (phase.kind === 'failed') {
    return <Failed network={phase.network} busy={busy} onRetry={() => void run(phase.action)} />;
  }
  const { answer } = phase;
  if (answer.privacy) {
    return (
      <PrivacyVerify
        answer={answer}
        privacy={answer.privacy}
        code={supportCode(link!.id)}
        busy={busy}
        run={run}
      />
    );
  }
  const date = deletionDateLabel(answer.scheduledAt);
  switch (answer.result) {
    case 'pending':
      return (
        <FlowPanel title={t.verifyTitle}>
          <Rows
            rows={[
              [t.codeLabel, supportCode(link!.id)],
              [t.submittedAtLabel, submittedLabel(answer.submittedAt) ?? '—'],
              [t.contactEmailLabel, answer.contactEmail ?? '—'],
              [t.accountLabel, t.accountValue],
            ]}
          />
          <p>{t.verifyBody}</p>
          <div className="support-actions">
            <button
              type="button"
              className="flow-button flow-button--danger"
              aria-disabled={busy || undefined}
              onClick={() => !busy && void run('confirm')}
            >
              {t.verifyConfirm}
            </button>
            <button
              type="button"
              className="flow-button"
              aria-disabled={busy || undefined}
              onClick={() => !busy && void run('deny')}
            >
              {t.verifyDeny}
            </button>
          </div>
          <p className="flow-note">{t.verifyDenyNote}</p>
        </FlowPanel>
      );
    case 'deletion_requested':
      return (
        <FlowPanel title={t.requestedTitle}>
          <div className="support-stack" role="status">
            <p>{t.requestedBody(date)}</p>
            <p>{t.requestedCancel}</p>
          </div>
          <p className="support-box support-box--muted">{t.requestedApple}</p>
        </FlowPanel>
      );
    case 'denied':
      return <Message title={t.deniedTitle} body={t.deniedBody} />;
    case 'resolved':
      return <Message title={t.resolvedTitle} body={t.resolvedBody} refill={deletionSupportPath} />;
    case 'account_deletion_pending':
      return <Message title={t.alreadyPendingTitle} body={t.alreadyPendingBody(date)} />;
    case 'account_deleting':
      return <Message title={t.deletingTitle} body={t.deletingBody} />;
    case 'unavailable':
      return <Message title={t.adminTitle} body={t.adminBody} />;
  }
}

/**
 * A privacy request's confirmation (PhoneVerify's layout): shows what the
 * owner of the login email is confirming, and records that they asked only
 * when they press the button.
 */
function PrivacyVerify({
  answer,
  privacy,
  code,
  busy,
  run,
}: {
  answer: Extract<ConfirmAnswer, { kind: 'answer'; privacy: PrivacyDetails }>;
  privacy: PrivacyDetails;
  code: string;
  busy: boolean;
  run: (action: ConfirmAction) => Promise<void>;
}) {
  switch (answer.result) {
    case 'pending': {
      const right = t.privacyRightOptions.find((option) => option.value === privacy.right);
      return (
        <FlowPanel title={t.privacyVerifyTitle}>
          <Rows
            rows={[
              [t.codeLabel, code],
              [t.submittedAtLabel, submittedLabel(answer.submittedAt) ?? '—'],
              [t.contactEmailLabel, answer.contactEmail ?? '—'],
              [t.privacyAccountLabel, t.accountValue],
              [t.privacyRightLabel, right?.label ?? '—'],
              [t.privacySubjectLabel, privacy.subject || '—'],
              [t.privacyMessageLabel, privacy.message || '—'],
            ]}
          />
          <p>{t.privacyVerifyBody}</p>
          <div className="support-actions">
            <button
              type="button"
              className="flow-button flow-button--primary"
              aria-disabled={busy || undefined}
              onClick={() => !busy && void run('confirm')}
            >
              {t.privacyVerifyConfirm}
            </button>
            <button
              type="button"
              className="flow-button"
              aria-disabled={busy || undefined}
              onClick={() => !busy && void run('deny')}
            >
              {t.verifyDeny}
            </button>
          </div>
          <p className="flow-note">{t.privacyDenyNote}</p>
        </FlowPanel>
      );
    }
    case 'verified':
      return (
        <FlowPanel title={t.privacyVerifiedTitle}>
          <p role="status">{t.privacyVerifiedBody}</p>
        </FlowPanel>
      );
    case 'denied':
      return <Message title={t.privacyDeniedTitle} body={t.deniedBody} />;
    case 'resolved':
      return (
        <Message title={t.privacyResolvedTitle} body={t.privacyResolvedBody} refill="/support?kind=privacy" />
      );
    case 'account_deleting':
      return <Message title={t.privacyAccountGoneTitle} body={t.privacyAccountGoneBody} />;
  }
}

/**
 * /support/cancel#token=…, the 取消刪除 link of the deletion notice (canvas
 * board PhoneCancel): shows the deletion time, and cancels only when the
 * owner presses 「取消刪除」.
 */
function CancelLink() {
  const support = useSupport();
  const link = useLinkToken();
  const { phase, busy, run } = useLink<LinkAnswer<CancelResult>, CancelAction>(
    support?.cancelLink ?? null,
    link?.token ?? null,
    'view',
  );
  if (phase.kind === 'loading') return <Loading />;
  if (phase.kind === 'invalid') return <Message title={t.cancelInvalidTitle} body={t.cancelInvalidBody} />;
  if (phase.kind === 'failed') {
    return <Failed network={phase.network} busy={busy} onRetry={() => void run(phase.action)} />;
  }
  const { answer } = phase;
  switch (answer.result) {
    case 'pending':
      return (
        <FlowPanel title={t.cancelTitle}>
          <Rows
            rows={[
              [t.codeLabel, supportCode(link!.id)],
              [t.scheduledLabel, t.scheduledValue(deletionDateLabel(answer.scheduledAt))],
            ]}
          />
          <p>{t.cancelBody}</p>
          <div className="support-actions">
            <button
              type="button"
              className="flow-button flow-button--primary"
              aria-disabled={busy || undefined}
              onClick={() => !busy && void run('cancel')}
            >
              {t.cancelButton}
            </button>
          </div>
          <p className="flow-note">{t.cancelKeepNote}</p>
        </FlowPanel>
      );
    case 'cancelled':
      return (
        <FlowPanel title={t.cancelledTitle}>
          <p role="status">{t.cancelledBody}</p>
        </FlowPanel>
      );
    case 'not_pending':
      return <Message title={t.notPendingTitle} body={t.notPendingBody} />;
    case 'account_deleting':
      return <Message title={t.deletingTitle} body={t.deletingBody} />;
  }
}
