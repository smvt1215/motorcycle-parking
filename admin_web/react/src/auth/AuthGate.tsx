import { useEffect, type ReactNode } from 'react';
import { useDispatch } from 'react-redux';
import { adminV1Base } from '../api/v1/base';
import { Button } from '../ui/controls';
import { AuthContext, useAuthState } from './AuthContext';
import type { AuthController } from './controller';
import { MfaPanel } from './MfaPanel';
import './Auth.css';

function Brand() {
  return (
    <span className="auth-brand" role="img" aria-label="機車停車指南管理">
      <span aria-hidden="true">P</span>
      <span aria-hidden="true" className="auth-brand__han">
        管
      </span>
    </span>
  );
}

function SignInPanel({ controller }: { controller: AuthController }) {
  const state = useAuthState(controller);
  const { stage, access, busy, refreshing, error } = state;
  if (stage === 'loading') {
    return (
      <>
        <h1 className="t-headline">確認登入狀態</h1>
        <p role="status" className="muted">
          正在確認登入狀態與管理權限。
        </p>
      </>
    );
  }
  if (stage === 'denied') {
    return (
      <>
        <h1 className="t-headline">這個帳號沒有管理權限</h1>
        <p>請切換到已授權的 Google 帳號。若需要管理權限，請聯絡專案擁有者。</p>
        {access.email && <p className="muted">{access.email}</p>}
        <Button disabled={busy} onClick={() => void controller.signOut()}>
          登出並切換帳號
        </Button>
        {error && <p className="auth-error">{error}</p>}
      </>
    );
  }
  if (stage === 'unavailable' && controller.connected) {
    return (
      <>
        <h1 className="t-headline">無法確認管理權限</h1>
        <p className="auth-error">{error ?? '請檢查連線後重試。'}</p>
        <div className="auth-actions">
          <Button variant="primary" disabled={refreshing} onClick={() => void controller.refresh()}>
            重新確認
          </Button>
          {access.signedIn && (
            <Button disabled={busy} onClick={() => void controller.signOut()}>
              登出
            </Button>
          )}
        </div>
      </>
    );
  }
  return (
    <>
      <h1 className="t-headline">登入管理介面</h1>
      <p>使用已授權的 Google 帳號登入，再完成第二步驗證。</p>
      <Button
        variant="primary"
        className="auth-wide"
        disabled={busy || !controller.connected}
        onClick={() => void controller.signIn()}
      >
        {busy ? '開啟 Google 登入中…' : '使用 Google 帳號登入'}
      </Button>
      {!controller.connected && (
        <p className="auth-error">此管理站尚未連接登入服務，請聯絡專案擁有者完成設定。</p>
      )}
      {error && <p className="auth-error">{error}</p>}
      <p className="t-caption">第二步驗證可使用驗證器 App 或已登記的手機簡訊。</p>
    </>
  );
}

/**
 * Nothing below this renders, or asks the server for anything, until the
 * session is an admin with a second factor. Cached case data goes as soon as
 * that stops being true.
 */
export function AuthGate({ controller, children }: { controller: AuthController; children: ReactNode }) {
  const state = useAuthState(controller);
  const dispatch = useDispatch();
  const ready = state.stage === 'ready';

  useEffect(() => {
    controller.start();
    return () => controller.stop();
  }, [controller]);

  useEffect(() => {
    if (!ready) dispatch(adminV1Base.util.resetApiState());
  }, [ready, state.access.userId, dispatch]);

  if (ready) return <AuthContext.Provider value={controller}>{children}</AuthContext.Provider>;

  return (
    <main className="auth-page">
      <Brand />
      <section className="panel auth-panel">
        {state.stage === 'mfa' ? (
          <MfaPanel controller={controller} />
        ) : (
          <SignInPanel controller={controller} />
        )}
      </section>
      <p className="t-caption">台灣機車停車指南 · 管理者專用</p>
    </main>
  );
}
