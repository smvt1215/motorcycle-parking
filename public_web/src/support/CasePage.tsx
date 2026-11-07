import { useState, type FormEvent } from 'react';
import { Link } from 'react-router';
import { deletionDateLabel } from '../deletion/format';
import { FlowPanel } from '../deletion/FlowPanel';
import type { CaseAnswer, CaseMessage, CaseReplyResult, CaseView, SupportPort } from './client';
import { submittedLabel, supportCode } from './format';
import { Failed, Loading, useLink, useLinkKey, useLinkToken } from './LinkPages';
import { useSupport } from './SupportContext';
import { Field } from './SupportFields';
import * as t from './text';
import './Support.css';

/** /support/case (every case mail's link). */
export function CasePage() {
  return <CaseLink key={useLinkKey()} />;
}

/**
 * /support/case#token=… (canvas board PhoneCase): the thread, and the reply box
 * while the case takes one. Opening it only sends `view`; the token stays in
 * memory for the 送出回覆 button.
 */
function CaseLink() {
  const support = useSupport();
  const link = useLinkToken();
  const { phase, busy, run } = useLink<CaseAnswer, 'view'>(
    support?.caseView ?? null,
    link?.token ?? null,
    'view',
  );
  if (phase.kind === 'loading') return <Loading />;
  if (phase.kind === 'invalid') return <CaseInvalid />;
  if (phase.kind === 'failed') {
    return <Failed network={phase.network} busy={busy} onRetry={() => void run('view')} />;
  }
  return <CaseThread view={phase.answer.view} id={link!.id} token={link!.token} reply={support!.caseReply} />;
}

function CaseInvalid() {
  return (
    <FlowPanel title={t.caseInvalidTitle}>
      <p>
        {t.caseInvalidBody.before}
        <Link to="/support">{t.caseRefill}</Link>
        {t.caseInvalidBody.after}
      </p>
    </FlowPanel>
  );
}

type ReplyFailure = Extract<CaseReplyResult, { kind: 'network' | 'unavailable' | 'rateLimited' }>['kind'];

const replyFailureCopy: Record<ReplyFailure, { title: string; body: string }> = {
  rateLimited: { title: t.replyLimitTitle, body: t.replyLimitBody },
  network: { title: t.networkTitle, body: t.replyNetworkBody },
  unavailable: { title: t.unavailableTitle, body: t.replyUnavailableBody },
};

function CaseThread({
  view,
  id,
  token,
  reply,
}: {
  view: CaseView;
  id: string;
  token: string;
  reply: SupportPort['caseReply'];
}) {
  const [status, setStatus] = useState(view.status);
  // A sent reply joins the thread here: only opening the page sends `view`.
  const [messages, setMessages] = useState(view.messages);
  const [draft, setDraft] = useState('');
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState<{ reopened: boolean } | null>(null);
  const [failure, setFailure] = useState<ReplyFailure | null>(null);
  const [closed, setClosed] = useState(false);
  const [invalid, setInvalid] = useState(false);

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (busy) return;
    const message = draft.trim();
    setTried(true);
    setSent(null);
    setFailure(null);
    if (!message) return;
    setBusy(true);
    const result = await reply(token, message);
    setBusy(false);
    switch (result.kind) {
      case 'received':
        setMessages((list) => [
          ...list,
          { direction: 'in', body: message, createdAt: new Date().toISOString() },
        ]);
        if (result.reopened) setStatus('open');
        setDraft('');
        setTried(false);
        setSent({ reopened: result.reopened });
        break;
      case 'closed':
        setClosed(true);
        break;
      case 'invalid':
        setInvalid(true);
        break;
      default:
        setFailure(result.kind);
    }
  }

  if (invalid) return <CaseInvalid />;
  const canReply = view.canReply && !closed;
  const missing = tried && !draft.trim() ? t.replyMissing : null;
  const facts = [
    `${t.caseCodeLabel} ${supportCode(id)}`,
    t.caseStatuses[status],
    view.submittedAt ? t.caseSubmittedOn(deletionDateLabel(view.submittedAt)) : null,
  ];
  return (
    <FlowPanel title={t.kindNames[view.kind] ?? t.caseFallbackTitle}>
      <p className="support-case-facts">{facts.filter(Boolean).join('　')}</p>
      <div className="support-thread" role="log" aria-label={t.threadLabel}>
        {messages
          .filter((message) => message.body.trim())
          .map((message, index) => (
            <Entry key={index} message={message} />
          ))}
      </div>
      {sent ? (
        <div className="support-box support-box--done" role="status">
          <h2>{t.replySentTitle}</h2>
          <p>{t.replySentBody}</p>
          {sent.reopened ? <p>{t.replyReopened}</p> : null}
        </div>
      ) : null}
      {canReply ? (
        <form className="support-form" noValidate onSubmit={onSubmit} aria-busy={busy}>
          <Field label={t.replyLabel} note={t.replyNote} help={t.replyHelp} helpAbove error={missing}>
            {(described) => (
              <textarea
                {...described}
                rows={5}
                maxLength={t.replyMax}
                value={draft}
                onChange={(event) => setDraft(event.target.value)}
              />
            )}
          </Field>
          {failure ? (
            <div className="support-box support-box--error" role="alert">
              <h2>{replyFailureCopy[failure].title}</h2>
              <p>{replyFailureCopy[failure].body}</p>
            </div>
          ) : null}
          <button
            type="submit"
            className="flow-button flow-button--primary"
            aria-disabled={busy || undefined}
          >
            {t.replySubmit}
          </button>
        </form>
      ) : status === 'open' && !closed ? (
        <div className="support-box support-box--muted">
          <h2>{t.linkUsedTitle}</h2>
          <p>{t.linkUsedBody}</p>
        </div>
      ) : (
        <div className="support-box support-box--muted">
          <h2>{t.caseClosedTitle}</h2>
          <p>
            {t.caseClosedBody.before}
            <Link to="/support">{t.caseRefill}</Link>
            {t.caseClosedBody.after}
          </p>
        </div>
      )}
    </FlowPanel>
  );
}

/** One message. The body is someone's text: shown as text, line breaks kept. */
function Entry({ message }: { message: CaseMessage }) {
  const mine = message.direction === 'in';
  const who = mine ? t.fromRider : t.fromSupport;
  const when = submittedLabel(message.createdAt);
  return (
    <div className={`support-message ${mine ? 'support-message--mine' : 'support-message--theirs'}`}>
      <span className="support-message-when">{when ? `${who}｜${when}` : who}</span>
      <p className="support-message-body">{message.body}</p>
    </div>
  );
}
