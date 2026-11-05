import { useEffect, useId, useState } from 'react';
import {
  useApiV1AccountDeletionStatusQuery,
  useApiV1CancelAccountDeletionMutation,
  useApiV1RequestAccountDeletionMutation,
} from '../api/api_v1.generated';
import type { V1Error } from '../api/base';
import type { AuthPort, SignedInUser } from '../auth/port';
import { accountLine, deletionDateLabel, maskEmail } from './format';
import { FlowActions, FlowPanel } from './FlowPanel';
import type { Outcome } from './Outcome';
import * as t from './text';

/** The step the signed-in rider is on, beyond what the status alone says. */
type Step =
  | { kind: 'status' }
  | { kind: 'reauth' }
  | { kind: 'reauthIncomplete' }
  | { kind: 'wrongAccount'; maskedEmail: string | null }
  | { kind: 'requested'; scheduledAt: string | null }
  | { kind: 'cancelled' }
  | { kind: 'inProgress' }
  | { kind: 'admin' }
  | { kind: 'network'; retry: () => void }
  | { kind: 'generic' };

function maskOrNull(email: string | null): string | null {
  return email ? maskEmail(email) : null;
}

function v1Error(failure: unknown): V1Error | null {
  if (failure && typeof failure === 'object' && 'message' in failure && 'status' in failure) {
    return failure as V1Error;
  }
  return null;
}

/** Network trouble: no answer, or one that never arrived whole. */
function isNetwork(error: V1Error | null): boolean {
  // A build without a backend is not a connection that a retry could fix.
  if (error === null || error.message === 'client.not_connected') return false;
  return error.status === 0 || error.message === 'client.network';
}

/**
 * The deletion flow once signed in (canvas PhoneConfirm, PhoneRequested,
 * PhonePending, PhoneStates; DesktopFlow at wider sizes). Signing in again
 * does not cancel a pending request: the rider chooses (PM_ANS_20261101_127).
 * Steps that end signed out hand their message up through `onOutcome`.
 */
export function DeletionFlow({
  user,
  auth,
  onOutcome,
}: {
  user: SignedInUser;
  auth: AuthPort;
  onOutcome: (outcome: Outcome | null) => void;
}) {
  const status = useApiV1AccountDeletionStatusQuery(undefined, { refetchOnMountOrArgChange: true });
  const [request, requestState] = useApiV1RequestAccountDeletionMutation();
  const [cancel, cancelState] = useApiV1CancelAccountDeletionMutation();
  const [step, setStep] = useState<Step>({ kind: 'status' });

  async function signOut(outcome: Outcome | null = null) {
    onOutcome(outcome);
    try {
      await auth.signOut();
    } catch {
      // Still signed in here: drop the outcome and say something went wrong.
      onOutcome(null);
      setStep({ kind: 'generic' });
    }
  }

  async function submit() {
    try {
      const state = await request({ body: { p_source: 'web' } }).unwrap();
      setStep({ kind: 'requested', scheduledAt: state.scheduled_at });
    } catch (failure) {
      const error = v1Error(failure);
      if (error?.message === 'auth.recent_sign_in_required') setStep({ kind: 'reauth' });
      else if (error?.message === 'account.admin_cannot_self_delete') setStep({ kind: 'admin' });
      else if (error?.message === 'auth.sign_in_required') await signOut();
      else if (isNetwork(error)) setStep({ kind: 'network', retry: () => void submit() });
      else setStep({ kind: 'generic' });
    }
  }

  async function cancelDeletion() {
    try {
      await cancel().unwrap();
      setStep({ kind: 'cancelled' });
    } catch (failure) {
      const error = v1Error(failure);
      if (error?.message === 'account.deletion_in_progress') setStep({ kind: 'inProgress' });
      else if (error?.message === 'auth.sign_in_required') await signOut();
      else if (isNetwork(error)) setStep({ kind: 'network', retry: () => void cancelDeletion() });
      else setStep({ kind: 'generic' });
    }
  }

  /**
   * Signing in again proves it is the rider: the same account sends the
   * request straight away (reauthFootnote); another one changes nothing.
   */
  async function reauthenticate() {
    let result;
    try {
      result = await auth.signIn(user.provider, { reauthFor: user });
    } catch {
      result = { kind: 'cancelled' } as const;
    }
    switch (result.kind) {
      case 'signedIn':
        if (result.user.id === user.id) {
          setStep({ kind: 'status' });
          await submit();
        } else await signOut({ kind: 'wrongAccount', maskedEmail: maskOrNull(result.user.email) });
        return;
      case 'wrongAccount':
      case 'noAccount':
        setStep({ kind: 'wrongAccount', maskedEmail: maskOrNull(result.email) });
        return;
      case 'cancelled':
        setStep({ kind: 'reauthIncomplete' });
        return;
    }
  }

  // The session ended elsewhere (a request signs every device out, and the
  // token outlives it by up to an hour): back to signed out.
  const signedOutElsewhere = status.isError && v1Error(status.error)?.message === 'auth.sign_in_required';
  useEffect(() => {
    if (signedOutElsewhere) auth.signOut().catch(() => setStep({ kind: 'generic' }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [signedOutElsewhere]);

  if (step.kind === 'requested') {
    return (
      <FlowPanel title={t.requestedTitle}>
        <p>{t.scheduledLine(deletionDateLabel(step.scheduledAt))}</p>
        <ul className="flow-rows">
          {t.requestedRows.map((row) => (
            <li key={row}>{row}</li>
          ))}
        </ul>
        <FlowActions>
          <button type="button" className="flow-button flow-button--primary" onClick={() => void signOut()}>
            {t.requestedDone}
          </button>
          <button
            type="button"
            className="flow-button"
            onClick={() => {
              // The App signs out and asks for a sign-in here. On the web the
              // rider is still signed in on this page (the token outlives the
              // request by up to an hour), so the cooling-off choice follows
              // directly; once the token has ended the status says so and the
              // page signs out.
              setStep({ kind: 'status' });
              void status.refetch();
            }}
          >
            {t.requestedSignIn}
          </button>
        </FlowActions>
      </FlowPanel>
    );
  }
  if (step.kind === 'reauth') {
    return (
      <FlowPanel title={t.reauthTitle}>
        <p>{t.reauthBody}</p>
        <p className="flow-account">{accountLine(user.provider, user.email)}</p>
        <FlowActions>
          <button
            type="button"
            className={`signin-button signin-button--${user.provider}`}
            onClick={() => void reauthenticate()}
          >
            {t.signInButton(user.provider)}
          </button>
          <button type="button" className="flow-button" onClick={() => setStep({ kind: 'status' })}>
            {t.reauthCancel}
          </button>
        </FlowActions>
        <p className="flow-note">{t.reauthFootnote}</p>
      </FlowPanel>
    );
  }
  if (step.kind === 'reauthIncomplete') {
    return (
      <FlowPanel title={t.signInIncompleteTitle}>
        <p>{t.signInIncompleteBody}</p>
        <FlowActions>
          <button
            type="button"
            className="flow-button flow-button--primary"
            onClick={() => setStep({ kind: 'reauth' })}
          >
            {t.signInRetry}
          </button>
        </FlowActions>
      </FlowPanel>
    );
  }
  if (step.kind === 'wrongAccount') {
    return (
      <Notice
        title={t.wrongAccountTitle}
        body={t.wrongAccountBody(step.maskedEmail)}
        onOk={() => setStep({ kind: 'status' })}
      />
    );
  }
  if (step.kind === 'cancelled') {
    return (
      <FlowPanel title={t.cancelledTitle}>
        <p>{t.cancelledBody}</p>
        <FlowActions>
          <button type="button" className="flow-button flow-button--primary" onClick={() => void signOut()}>
            {t.dismiss}
          </button>
        </FlowActions>
      </FlowPanel>
    );
  }
  if (step.kind === 'inProgress') {
    return (
      <FlowPanel title={t.inProgressTitle}>
        <p>{t.inProgressBody}</p>
        <FlowActions>
          <button type="button" className="flow-button flow-button--primary" onClick={() => void signOut()}>
            {t.dismiss}
          </button>
        </FlowActions>
      </FlowPanel>
    );
  }
  if (step.kind === 'network') {
    return (
      <FlowPanel title={t.networkFailedTitle}>
        <p>{t.networkFailedBody}</p>
        <FlowActions>
          <button
            type="button"
            className="flow-button flow-button--primary"
            onClick={() => {
              setStep({ kind: 'status' });
              step.retry();
            }}
          >
            {t.networkRetry}
          </button>
          <button type="button" className="flow-button" onClick={() => void signOut()}>
            {t.signOut}
          </button>
        </FlowActions>
      </FlowPanel>
    );
  }
  if (step.kind === 'generic') {
    return <Notice title={t.genericErrorTitle} body={t.genericErrorBody} onOk={() => void signOut()} />;
  }

  // The status decides the rest.
  if (status.isError) {
    const error = v1Error(status.error);
    if (error?.message === 'auth.sign_in_required') return <Checking label={t.checking} />;
    if (isNetwork(error)) {
      return (
        <FlowPanel title={t.networkFailedTitle}>
          <p>{t.networkFailedBody}</p>
          <FlowActions>
            <button
              type="button"
              className="flow-button flow-button--primary"
              onClick={() => void status.refetch()}
            >
              {t.networkRetry}
            </button>
            <button type="button" className="flow-button" onClick={() => void signOut()}>
              {t.signOut}
            </button>
          </FlowActions>
        </FlowPanel>
      );
    }
    return <Notice title={t.genericErrorTitle} body={t.genericErrorBody} onOk={() => void signOut()} />;
  }
  // isFetching: a refetch must not show the last answer (e.g. 'none' before the request).
  if (!status.data || status.isFetching || requestState.isLoading) {
    return <Checking label={requestState.isLoading ? t.sending : t.checking} />;
  }
  if (step.kind === 'admin' || !status.data.can_self_delete) {
    return (
      <Notice title={t.adminCannotDeleteTitle} body={t.adminCannotDeleteBody} onOk={() => void signOut()} />
    );
  }
  if (status.data.status === 'pending') {
    return (
      <Pending
        scheduledAt={status.data.scheduled_at}
        busy={cancelState.isLoading}
        onCancel={() => void cancelDeletion()}
        onContinue={() => void signOut({ kind: 'continued', scheduledAt: status.data?.scheduled_at ?? null })}
      />
    );
  }
  return <Confirm user={user} onConfirm={() => void submit()} onCancel={() => void signOut()} />;
}

function Checking({ label }: { label: string }) {
  return (
    <FlowPanel title={label}>
      <p className="flow-note" role="status">
        {label}
      </p>
    </FlowPanel>
  );
}

function Notice({ title, body, onOk }: { title: string; body: string; onOk: () => void }) {
  return (
    <FlowPanel title={title}>
      <p>{body}</p>
      <FlowActions>
        <button type="button" className="flow-button flow-button--primary" onClick={onOk}>
          {t.ok}
        </button>
      </FlowActions>
    </FlowPanel>
  );
}

/** PhoneConfirm: the last look before the request, behind one checkbox. */
function Confirm({
  user,
  onConfirm,
  onCancel,
}: {
  user: SignedInUser;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const [checked, setChecked] = useState(false);
  const hintId = useId();
  return (
    <FlowPanel
      title={t.confirmTitle}
      tone="danger"
      aside={
        <button type="button" className="site-header-action" onClick={onCancel}>
          {t.signOut}
        </button>
      }
    >
      <p className="flow-account">{accountLine(user.provider, user.email)}</p>
      <p>{t.confirmBody}</p>
      <ul className="flow-rows">
        {t.confirmPoints.map((point) => (
          <li key={point}>{point}</li>
        ))}
      </ul>
      <label className="flow-check">
        <input type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} />
        <span>{t.confirmCheck}</span>
      </label>
      <FlowActions>
        {/* Stays focusable while unchecked, so the reason can be read out. */}
        <button
          type="button"
          className="flow-button flow-button--danger"
          aria-disabled={!checked}
          aria-describedby={checked ? undefined : hintId}
          onClick={() => {
            if (checked) onConfirm();
          }}
        >
          {t.confirmAction}
        </button>
        <button type="button" className="flow-button" onClick={onCancel}>
          {t.confirmCancel}
        </button>
      </FlowActions>
      {checked ? null : (
        <p id={hintId} className="flow-note">
          {t.confirmCheckHint}
        </p>
      )}
      <p className="flow-note">{t.reauthNote}</p>
    </FlowPanel>
  );
}

/**
 * PhonePending: signed in during the cooling-off. The rider picks one of
 * the two; there is no way out of the choice but making it.
 */
function Pending({
  scheduledAt,
  busy,
  onCancel,
  onContinue,
}: {
  scheduledAt: string | null;
  busy: boolean;
  onCancel: () => void;
  onContinue: () => void;
}) {
  return (
    <FlowPanel title={t.pendingTitle}>
      <p>{t.pendingBody}</p>
      <div className="flow-choices">
        <button
          type="button"
          className="flow-choice"
          aria-disabled={busy}
          onClick={() => !busy && onCancel()}
        >
          <span className="flow-choice-title">{busy ? t.sending : t.pendingCancel}</span>
          <span className="flow-choice-detail">{t.pendingCancelDetail}</span>
        </button>
        <button
          type="button"
          className="flow-choice"
          aria-disabled={busy}
          onClick={() => !busy && onContinue()}
        >
          <span className="flow-choice-title">{t.pendingContinue}</span>
          <span className="flow-choice-detail">
            {t.pendingContinueDetail(deletionDateLabel(scheduledAt))}
          </span>
        </button>
      </div>
      <p className="flow-note">{t.pendingFootnote}</p>
    </FlowPanel>
  );
}
