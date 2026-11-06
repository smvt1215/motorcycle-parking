import { useEffect, useId, useRef, useState } from 'react';
import {
  useApiV1AccountDeletionStatusQuery,
  useApiV1CancelAccountDeletionMutation,
  useApiV1RequestAccountDeletionMutation,
} from '../api/api_v1.generated';
import type { V1Error } from '../api/base';
import type { AuthPort, SignedInUser, SignInResult } from '../auth/port';
import { AppleButton, GoogleButton, SignInChecking } from '../auth/SignInButtons';
import { useSignInChecking } from '../auth/useSignInChecking';
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
  | { kind: 'requested'; scheduledAt: string | null; appleRevokeFailed: boolean }
  | { kind: 'rateLimited' }
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
  const progress = useSignInChecking(() => setStep({ kind: 'reauthIncomplete' }));
  // Apple's grant is revoked once per Apple sign-in, right before the
  // request; a retry after a failed request does not revoke again (as the
  // App's DeletionAttempt).
  const appleRevoke = useRef({ attempted: false, failed: false });
  const [revoking, setRevoking] = useState(false);
  const continuing = useRef(false);
  // The same, for the screen: both choices stay disabled until it is done.
  const [continuingNow, setContinuingNow] = useState(false);

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

  /** Revokes Apple's grant first; false when the flow went elsewhere. */
  async function revokeAppleFirst(): Promise<boolean> {
    if (user.provider !== 'apple' || appleRevoke.current.attempted) return true;
    setRevoking(true);
    let result;
    try {
      result = await auth.revokeApple();
    } catch {
      result = { kind: 'notRevoked' } as const;
    } finally {
      setRevoking(false);
    }
    switch (result.kind) {
      case 'revoked':
      case 'notRevoked':
        appleRevoke.current = { attempted: true, failed: result.kind === 'notRevoked' };
        return true;
      case 'signInNeeded':
        // A fresh authorization code comes only with a new Apple sign-in.
        setStep({ kind: 'reauth' });
        return false;
      case 'refused':
        if (result.error === 'auth.recent_sign_in_required') setStep({ kind: 'reauth' });
        else if (result.error === 'account.admin_cannot_self_delete') setStep({ kind: 'admin' });
        else if (result.error === 'auth.sign_in_required') await signOut();
        else {
          // Anything else did not revoke; the request still goes (the App's way).
          appleRevoke.current = { attempted: true, failed: true };
          return true;
        }
        return false;
    }
  }

  async function submit() {
    if (!(await revokeAppleFirst())) return;
    try {
      const state = await request({ body: { p_source: 'web' } }).unwrap();
      setStep({
        kind: 'requested',
        scheduledAt: state.scheduled_at,
        appleRevokeFailed: user.provider === 'apple' && appleRevoke.current.failed,
      });
    } catch (failure) {
      const error = v1Error(failure);
      if (error?.message === 'auth.recent_sign_in_required') setStep({ kind: 'reauth' });
      else if (error?.message === 'account.admin_cannot_self_delete') setStep({ kind: 'admin' });
      else if (error?.message === 'auth.sign_in_required') await signOut();
      else if (isNetwork(error)) setStep({ kind: 'network', retry: () => void submit() });
      else setStep({ kind: 'generic' });
    }
  }

  /**
   * 繼續刪除: the request stays. A sign-in with Apple during the cooling-off
   * is a new grant, so it is revoked first, best effort: whatever the
   * answer, the rider is signed out (the App's continuePending).
   */
  async function continuePending(scheduledAt: string | null) {
    // One choice at a time: a cancel in flight, or this already running.
    if (continuing.current || cancelState.isLoading) return;
    continuing.current = true;
    setContinuingNow(true);
    if (user.provider === 'apple') {
      try {
        await auth.revokeApple();
      } catch {
        // Nothing stops signing out here.
      }
    }
    await signOut({ kind: 'continued', scheduledAt });
    continuing.current = false;
    setContinuingNow(false);
  }

  async function cancelDeletion() {
    // While 繼續刪除 is revoking and signing out, cancelling would contradict it.
    if (continuing.current) return;
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
  async function reauthenticated(result: SignInResult) {
    switch (result.kind) {
      case 'signedIn':
        if (result.user.id === user.id) {
          // A new Apple sign-in brings a new code: revoke with that one.
          appleRevoke.current = { attempted: false, failed: false };
          setStep({ kind: 'status' });
          await submit();
        } else await signOut({ kind: 'wrongAccount', maskedEmail: maskOrNull(result.user.email) });
        return;
      case 'wrongAccount':
      case 'noAccount':
        setStep({ kind: 'wrongAccount', maskedEmail: maskOrNull(result.email) });
        return;
      case 'rateLimited':
        setStep({ kind: 'rateLimited' });
        return;
      case 'unavailable':
        if (result.network) setStep({ kind: 'network', retry: () => setStep({ kind: 'reauth' }) });
        else setStep({ kind: 'reauthIncomplete' });
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
        {step.appleRevokeFailed ? (
          <section className="flow-notice" aria-labelledby="apple-revoke-h">
            <h2 id="apple-revoke-h">{t.appleRevokeFailedTitle}</h2>
            <p>{t.appleRevokeFailedBody}</p>
          </section>
        ) : null}
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
        <p>{user.provider === 'apple' ? t.reauthBodyApple : t.reauthBody}</p>
        <p className="flow-account">{accountLine(user.provider, user.email)}</p>
        {progress.checking ? <SignInChecking /> : null}
        {/* Hidden, not removed: removing Google's button would drop the sign-in under way. */}
        <FlowActions hidden={progress.checking}>
          {user.provider === 'apple' ? (
            <AppleButton
              auth={auth}
              onClick={() => {
                // Synchronously from the click: Apple's popup needs it.
                auth
                  .signInWithApple({ reauthFor: user, onChecking: progress.start })
                  .catch(() => ({ kind: 'cancelled' }) as const)
                  .then((result) => {
                    if (progress.settle()) void reauthenticated(result);
                  });
              }}
            />
          ) : (
            <GoogleButton
              auth={auth}
              reauthFor={user}
              onChecking={progress.start}
              onResult={(result) => {
                if (progress.settle()) void reauthenticated(result);
              }}
            />
          )}
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
  if (step.kind === 'rateLimited') {
    return (
      <Notice title={t.rateLimitedTitle} body={t.rateLimitedBody} onOk={() => setStep({ kind: 'reauth' })} />
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
  if (!status.data || status.isFetching || requestState.isLoading || revoking) {
    return <Checking label={requestState.isLoading || revoking ? t.sending : t.checking} />;
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
        working={cancelState.isLoading ? 'cancel' : continuingNow ? 'continue' : null}
        onCancel={() => void cancelDeletion()}
        onContinue={() => void continuePending(status.data?.scheduled_at ?? null)}
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
  working,
  onCancel,
  onContinue,
}: {
  scheduledAt: string | null;
  /** The choice being carried out: both are disabled until it is done. */
  working: 'cancel' | 'continue' | null;
  onCancel: () => void;
  onContinue: () => void;
}) {
  const busy = working !== null;
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
          <span className="flow-choice-title">{working === 'cancel' ? t.sending : t.pendingCancel}</span>
          <span className="flow-choice-detail">{t.pendingCancelDetail}</span>
        </button>
        <button
          type="button"
          className="flow-choice"
          aria-disabled={busy}
          onClick={() => !busy && onContinue()}
        >
          <span className="flow-choice-title">{working === 'continue' ? t.sending : t.pendingContinue}</span>
          <span className="flow-choice-detail">
            {t.pendingContinueDetail(deletionDateLabel(scheduledAt))}
          </span>
        </button>
      </div>
      <p className="flow-note">{t.pendingFootnote}</p>
    </FlowPanel>
  );
}
