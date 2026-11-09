import { useState, type FormEvent } from 'react';
import { Button } from '../ui/controls';
import { useAuthState } from './AuthContext';
import { activeFactor, unfinishedFactors, verifiedFactors, type AuthController } from './controller';
import type { AdminFactor, FactorKind } from './gateway';

const factorName = (factor: AdminFactor) =>
  factor.name ?? (factor.type === 'phone' ? '手機簡訊' : '驗證器 App');

/** Keyed by factor: a code typed for one must not carry over to another. */
function CodeForm({ controller }: { controller: AuthController }) {
  const state = useAuthState(controller);
  const active = activeFactor(state);
  const [code, setCode] = useState('');
  const [invalid, setInvalid] = useState(false);

  const phone = active?.type === 'phone';
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (state.busy) return;
    if (!/^\d{6}$/.test(code)) {
      setInvalid(true);
      return;
    }
    setInvalid(false);
    void controller.verify(code).then(() => setCode(''));
  };

  return (
    <form className="auth-form" onSubmit={submit} noValidate>
      {phone ? (
        <>
          <Button disabled={state.busy} onClick={() => void controller.sendChallenge()}>
            {state.challenge ? '重新傳送簡訊' : '傳送簡訊驗證碼'}
          </Button>
          {state.challenge && <p role="status">驗證碼已傳送，請查看手機簡訊。</p>}
        </>
      ) : (
        <p>輸入驗證器 App 顯示的 6 位數驗證碼。</p>
      )}
      <label className="auth-field">
        <span className="t-label">6 位數驗證碼</span>
        <input
          className="auth-code"
          value={code}
          inputMode="numeric"
          autoComplete="one-time-code"
          maxLength={6}
          disabled={state.busy}
          aria-invalid={invalid}
          onChange={(event) => setCode(event.target.value.replace(/\D/g, '').slice(0, 6))}
        />
        {invalid && <span className="auth-error">請輸入完整的 6 位數驗證碼</span>}
      </label>
      <Button type="submit" variant="primary" disabled={state.busy || (phone && !state.challenge)}>
        {state.busy ? '驗證中…' : '確認驗證碼'}
      </Button>
    </form>
  );
}

function EnrollForm({ controller }: { controller: AuthController }) {
  const state = useAuthState(controller);
  const [type, setType] = useState<FactorKind>('totp');
  const [name, setName] = useState('');
  const [phone, setPhone] = useState('');
  const [problem, setProblem] = useState<string | null>(null);

  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!name.trim()) {
      setProblem('請輸入驗證方式的名稱');
      return;
    }
    if (type === 'phone' && !/^\+[1-9]\d{6,14}$/.test(phone.trim())) {
      setProblem('請輸入含國碼的完整手機號碼，例如 +886912345678');
      return;
    }
    setProblem(null);
    void controller.enroll(type, name.trim(), type === 'phone' ? phone.trim() : null);
  };

  return (
    <form className="auth-form" onSubmit={submit} noValidate>
      <h2 className="t-title">登記驗證方式</h2>
      <label className="auth-field">
        <span className="t-label">驗證方式</span>
        <select value={type} disabled={state.busy} onChange={(e) => setType(e.target.value as FactorKind)}>
          <option value="totp">驗證器 App（建議）</option>
          <option value="phone">手機簡訊（選用）</option>
        </select>
      </label>
      <label className="auth-field">
        <span className="t-label">方便辨識的名稱</span>
        <input
          value={name}
          maxLength={64}
          disabled={state.busy}
          placeholder="例如：手機驗證器"
          onChange={(event) => setName(event.target.value)}
        />
      </label>
      {type === 'phone' && (
        <>
          <label className="auth-field">
            <span className="t-label">手機號碼（含國碼）</span>
            <input
              value={phone}
              type="tel"
              disabled={state.busy}
              placeholder="+886912345678"
              onChange={(event) => setPhone(event.target.value)}
            />
          </label>
          <p className="t-caption">簡訊需由專案擁有者先啟用，可能產生電信費用。</p>
        </>
      )}
      {problem && <p className="auth-error">{problem}</p>}
      <Button type="submit" variant="primary" disabled={state.busy || state.refreshing}>
        {state.busy ? '登記中…' : '開始登記'}
      </Button>
    </form>
  );
}

function EnrollmentSteps({ controller }: { controller: AuthController }) {
  const state = useAuthState(controller);
  const [showSecret, setShowSecret] = useState(false);
  const enrollment = state.enrollment;
  if (!enrollment) return null;
  return (
    <div className="auth-form">
      <h2 className="t-title">驗證新登記的方式</h2>
      {enrollment.qrCode && (
        <>
          <p>使用驗證器 App 掃描 QR code，或手動輸入設定密鑰。</p>
          <img
            className="auth-qr"
            src={enrollment.qrCode}
            width={200}
            height={200}
            alt="新驗證器的登記 QR code"
          />
          <label className="auth-field">
            <span className="t-label">設定密鑰</span>
            <input
              readOnly
              type={showSecret ? 'text' : 'password'}
              autoComplete="off"
              value={enrollment.secret}
            />
          </label>
          <Button variant="quiet" onClick={() => setShowSecret((shown) => !shown)}>
            {showSecret ? '隱藏密鑰' : '顯示密鑰'}
          </Button>
        </>
      )}
      {enrollment.phone && <p>傳送驗證碼至 {enrollment.phone}，完成手機登記。</p>}
      <CodeForm key={enrollment.id} controller={controller} />
      <Button variant="quiet" disabled={state.busy} onClick={() => void controller.cancelEnrollment()}>
        取消這次登記
      </Button>
    </div>
  );
}

/** 第二步驗證: pick or enrol a factor (lib/admin/admin_mfa_page.dart). */
export function MfaPanel({ controller }: { controller: AuthController }) {
  const state = useAuthState(controller);
  const verified = verifiedFactors(state);
  const unfinished = unfinishedFactors(state);
  const authenticators = verified.filter((factor) => factor.type === 'totp').length;

  let body;
  if (state.refreshing) {
    body = (
      <p role="status" className="muted">
        讀取驗證方式…
      </p>
    );
  } else if (state.enrollment) {
    body = <EnrollmentSteps controller={controller} />;
  } else if (verified.length > 0) {
    body = (
      <>
        <label className="auth-field">
          <span className="t-label">選擇驗證方式</span>
          <select
            value={state.selectedFactorId ?? ''}
            disabled={state.busy}
            onChange={(event) => controller.selectFactor(event.target.value)}
          >
            {verified.map((factor) => (
              <option key={factor.id} value={factor.id}>
                {factorName(factor)}
              </option>
            ))}
          </select>
        </label>
        <CodeForm key={state.selectedFactorId} controller={controller} />
      </>
    );
  } else {
    body = <EnrollForm controller={controller} />;
  }

  return (
    <>
      <h1 className="t-headline">請先完成第二步驗證</h1>
      <p className="muted">{state.access.email ?? '管理者帳號'}</p>
      {authenticators < 2 && (
        <p className="auth-note">
          請至少登記兩個驗證器 App，例如手機與密碼管理器，互為備援。每個驗證器請分別登記。
        </p>
      )}
      {!state.refreshing && !state.enrollment && unfinished.length > 0 && (
        <div className="auth-form">
          <h2 className="t-title">未完成的登記</h2>
          <p>若曾中斷設定，可先取消尚未驗證的登記，再使用相同名稱重新登記。</p>
          {unfinished.map((factor) => (
            <div key={factor.id} className="auth-unfinished">
              <span>{factorName(factor)}</span>
              <Button
                variant="quiet"
                disabled={state.busy}
                onClick={() => void controller.discardUnfinished(factor.id)}
              >
                取消登記
              </Button>
            </div>
          ))}
        </div>
      )}
      {body}
      {state.error && <p className="auth-error">{state.error}</p>}
      <p className="t-caption">若所有驗證方式都已遺失，請聯絡專案擁有者協助重設。</p>
      <Button variant="quiet" disabled={state.busy} onClick={() => void controller.signOut()}>
        登出
      </Button>
    </>
  );
}
