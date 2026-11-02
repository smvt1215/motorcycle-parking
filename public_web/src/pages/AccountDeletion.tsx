import { Link } from 'react-router';
import * as c from '../content';
import { Site } from '../ui/Site';
import './AccountDeletion.css';

/**
 * /account-deletion, the page Google Play links to (canvas boards Main,
 * Tablet and PhoneSignedOut). The actions come once: right of the
 * explanation on a desktop, under the introduction below 1040px. Signing in
 * arrives with the request flow; the buttons are wired there.
 */
export function AccountDeletion() {
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
            {/* Official Google / Apple button styles; wired with the request flow. */}
            <div className="deletion-signin-buttons">
              <button type="button" className="signin-button signin-button--google">
                使用 Google 登入
              </button>
              <button type="button" className="signin-button signin-button--apple">
                使用 Apple 登入
              </button>
            </div>
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
            <ol className="lane">
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
