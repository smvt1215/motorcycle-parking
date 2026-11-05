import { Link } from 'react-router';
import type { Provider } from '../auth/port';
import { deletionDateLabel } from './format';
import { FlowActions, FlowPanel } from './FlowPanel';
import * as t from './text';

/**
 * What the page says after the flow has signed the rider out, or after a
 * sign-in that did not sign anyone in: kept above the session so it
 * survives the sign-out.
 */
export type Outcome =
  | { kind: 'continued'; scheduledAt: string | null }
  | { kind: 'wrongAccount'; maskedEmail: string | null }
  | { kind: 'noAccount'; provider: Provider; email: string | null }
  | { kind: 'signInIncomplete' }
  /** The sign-in check refused: too many attempts from this network. */
  | { kind: 'rateLimited' }
  /** The sign-in could not reach the backend. */
  | { kind: 'network' }
  /** The backend could not check the sign-in (down, or App Check failed). */
  | { kind: 'unavailable' };

export function OutcomePanel({
  outcome,
  onDismiss,
}: {
  outcome: Outcome;
  /** Back to the explanation and its sign-in buttons. */
  onDismiss: () => void;
}) {
  switch (outcome.kind) {
    case 'continued':
      return (
        <FlowPanel title={t.continuedTitle}>
          <p>{t.scheduledLine(deletionDateLabel(outcome.scheduledAt))}</p>
          <FlowActions>
            <button type="button" className="flow-button flow-button--primary" onClick={onDismiss}>
              {t.dismiss}
            </button>
          </FlowActions>
        </FlowPanel>
      );
    case 'wrongAccount':
      return (
        <FlowPanel title={t.wrongAccountTitle}>
          <p>{t.wrongAccountBody(outcome.maskedEmail)}</p>
          <FlowActions>
            <button type="button" className="flow-button flow-button--primary" onClick={onDismiss}>
              {t.ok}
            </button>
          </FlowActions>
        </FlowPanel>
      );
    case 'noAccount':
      return (
        <FlowPanel title={t.noAccountTitle}>
          <p className="flow-account">{t.noAccountBody(outcome.email)}</p>
          <p>{t.noAccountHint(outcome.provider)}</p>
          <FlowActions>
            <button type="button" className="flow-button flow-button--primary" onClick={onDismiss}>
              {t.noAccountRetry}
            </button>
          </FlowActions>
          <Link to="/support" className="flow-link">
            {t.noAccountSupport}
          </Link>
        </FlowPanel>
      );
    case 'signInIncomplete':
      return (
        <FlowPanel title={t.signInIncompleteTitle}>
          <p>{t.signInIncompleteBody}</p>
          <FlowActions>
            <button type="button" className="flow-button flow-button--primary" onClick={onDismiss}>
              {t.signInRetry}
            </button>
          </FlowActions>
        </FlowPanel>
      );
    case 'rateLimited':
      return (
        <Simple title={t.rateLimitedTitle} body={t.rateLimitedBody} action={t.ok} onDismiss={onDismiss} />
      );
    case 'network':
      return (
        <Simple
          title={t.networkFailedTitle}
          body={t.networkFailedBody}
          action={t.networkRetry}
          onDismiss={onDismiss}
        />
      );
    case 'unavailable':
      return (
        <Simple title={t.genericErrorTitle} body={t.genericErrorBody} action={t.ok} onDismiss={onDismiss} />
      );
  }
}

function Simple({
  title,
  body,
  action,
  onDismiss,
}: {
  title: string;
  body: string;
  action: string;
  onDismiss: () => void;
}) {
  return (
    <FlowPanel title={title}>
      <p>{body}</p>
      <FlowActions>
        <button type="button" className="flow-button flow-button--primary" onClick={onDismiss}>
          {action}
        </button>
      </FlowActions>
    </FlowPanel>
  );
}
