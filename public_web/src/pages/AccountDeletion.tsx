import { useState } from 'react';
import { Link } from 'react-router';
import { useAppSelector } from '../app/store';
import { useAuth } from '../auth/AuthContext';
import type { AuthPort, Provider, SignInResult } from '../auth/port';
import { AppleButton, GoogleButton } from '../auth/SignInButtons';
import * as c from '../content';
import { DeletionFlow } from '../deletion/DeletionFlow';
import { FlowPanel } from '../deletion/FlowPanel';
import { OutcomePanel, type Outcome } from '../deletion/Outcome';
import { checking } from '../deletion/text';
import { Site } from '../ui/Site';
import './AccountDeletion.css';

/** What a sign-in from the explanation leaves to say; signed in, the flow takes over. */
function outcomeOf(provider: Provider, result: SignInResult): Outcome | null {
  switch (result.kind) {
    case 'signedIn':
      return null;
    case 'noAccount':
      return { kind: 'noAccount', provider, email: result.email };
    case 'rateLimited':
      return { kind: 'rateLimited' };
    case 'unavailable':
      return { kind: result.network ? 'network' : 'unavailable' };
    case 'wrongAccount':
    case 'cancelled':
      return { kind: 'signInIncomplete' };
  }
}

/**
 * /account-deletion, the page Google Play links to. Signed out it explains
 * (canvas boards Main, Tablet and PhoneSignedOut) and offers sign-in once:
 * right of the explanation on a desktop, under the introduction below
 * 1040px. Signed in it runs the deletion flow (DeletionFlow).
 */
export function AccountDeletion() {
  const auth = useAuth();
  const session = useAppSelector((state) => state.session);
  const [outcome, setOutcome] = useState<Outcome | null>(null);

  if (outcome && session.phase !== 'signedIn') {
    return <OutcomePanel outcome={outcome} onDismiss={() => setOutcome(null)} />;
  }
  if (session.phase === 'signedIn' && session.user && auth) {
    // Keyed by account: another account starts the flow afresh.
    return <DeletionFlow key={session.user.id} user={session.user} auth={auth} onOutcome={setOutcome} />;
  }
  if (session.phase === 'loading' && auth) {
    return (
      <FlowPanel title={checking}>
        <p className="flow-note" role="status">
          {checking}
        </p>
      </FlowPanel>
    );
  }
  return (
    <Explanation
      signIn={
        auth
          ? {
              auth,
              onResult: (provider, result) => setOutcome(outcomeOf(provider, result)),
            }
          : null
      }
    />
  );
}

/** The sign-in buttons' port, and where each finished sign-in goes. */
interface ExplanationSignIn {
  auth: AuthPort;
  onResult: (provider: Provider, result: SignInResult) => void;
}

function Explanation({ signIn }: { signIn: ExplanationSignIn | null }) {
  return (
    <Site aside={<Link to="/support">沒辦法登入？</Link>}>
      <div className="deletion">
        <div className="deletion-intro">
          <h1>刪除你的帳號</h1>
          <p>{c.intro}</p>
        </div>

        <aside className="deletion-actions" aria-label="申請刪除">
          <section aria-labelledby="signin-h" className="deletion-signin">
            <div className="deletion-signin-text">
              <h2 id="signin-h">{c.signInHeading}</h2>
              <p>{c.signInBody}</p>
            </div>
            {/* Google draws its own button; Apple's follows its shape. Without
                the sign-in settings (a local preview) there is nothing to sign
                in to. */}
            {signIn ? (
              <div className="deletion-signin-buttons">
                <GoogleButton auth={signIn.auth} onResult={(result) => signIn.onResult('google', result)} />
                <AppleButton
                  auth={signIn.auth}
                  onClick={() => {
                    // Synchronously from the click: Apple's popup needs it.
                    signIn.auth
                      .signInWithApple()
                      .then((result) => signIn.onResult('apple', result))
                      .catch(() => signIn.onResult('apple', { kind: 'cancelled' }));
                  }}
                />
              </div>
            ) : null}
          </section>
          <section aria-labelledby="cannot-h" className="deletion-cannot">
            <h2 id="cannot-h">{c.cannotSignInHeading}</h2>
            <p>{c.cannotSignInBody}</p>
            <Link to="/support">{c.supportFormLink}</Link>
          </section>
        </aside>

        <div className="deletion-details">
          <section aria-labelledby="cooling-h" className="deletion-section">
            <h2 id="cooling-h">{c.coolingOffHeading}</h2>
            {/* role="list": Safari drops the list semantics of a styled list. */}
            <ol className="lane" role="list">
              {c.coolingOffSteps.map((step, i) => (
                <li key={step.when} className={i === c.coolingOffSteps.length - 1 ? 'lane-end' : undefined}>
                  <span className="lane-when">{step.when}</span>
                  <span className="lane-what">{step.what}</span>
                </li>
              ))}
            </ol>
          </section>

          <div className="deletion-pair">
            <section aria-labelledby="deleted-h" className="deletion-section">
              <h2 id="deleted-h">{c.deletedHeading}</h2>
              <ul>
                {c.deleted.map((item) => (
                  <li key={item}>{item}</li>
                ))}
              </ul>
            </section>
            <section aria-labelledby="kept-h" className="deletion-section">
              <h2 id="kept-h">{c.keptHeading}</h2>
              <ul>
                {c.kept.map((item) => (
                  <li key={item}>{item}</li>
                ))}
              </ul>
              <p className="deletion-note">{c.keptNote}</p>
            </section>
          </div>

          <div className="deletion-pair">
            <section aria-labelledby="hash-h" className="deletion-section">
              <h2 id="hash-h">{c.hashHeading}</h2>
              <p>{c.hashBody}</p>
            </section>
            <section aria-labelledby="retention-h" className="deletion-section">
              <h2 id="retention-h">{c.retentionHeading}</h2>
              <ul>
                {c.retention.map((item) => (
                  <li key={item}>{item}</li>
                ))}
              </ul>
            </section>
          </div>
        </div>
      </div>
    </Site>
  );
}
