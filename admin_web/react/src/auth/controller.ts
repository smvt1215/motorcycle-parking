import {
  SIGNED_OUT,
  type AdminAccess,
  type AdminAuthGateway,
  type AdminFactor,
  type Enrollment,
  type FactorKind,
  type MfaChallenge,
} from './gateway';

export type AdminStage = 'loading' | 'signedOut' | 'denied' | 'mfa' | 'ready' | 'unavailable';

export interface AuthState {
  stage: AdminStage;
  access: AdminAccess;
  factors: AdminFactor[];
  enrollment: Enrollment | null;
  selectedFactorId: string | null;
  challenge: MfaChallenge | null;
  error: string | null;
  busy: boolean;
  refreshing: boolean;
}

const stageOf = (access: AdminAccess): AdminStage =>
  !access.signedIn ? 'signedOut' : !access.isAdmin ? 'denied' : !access.aal2 ? 'mfa' : 'ready';

const INITIAL: AuthState = {
  stage: 'loading',
  access: SIGNED_OUT,
  factors: [],
  enrollment: null,
  selectedFactorId: null,
  challenge: null,
  error: null,
  busy: false,
  refreshing: false,
};

const PRIVATE: Pick<AuthState, 'factors' | 'enrollment' | 'selectedFactorId' | 'challenge'> = {
  factors: [],
  enrollment: null,
  selectedFactorId: null,
  challenge: null,
};

export const verifiedFactors = (state: AuthState) => state.factors.filter((factor) => factor.verified);
export const unfinishedFactors = (state: AuthState) => state.factors.filter((factor) => !factor.verified);

export function activeFactor(state: AuthState): { id: string; type: FactorKind } | null {
  if (state.enrollment) return { id: state.enrollment.id, type: state.enrollment.type };
  const factor = verifiedFactors(state).find((f) => f.id === state.selectedFactorId);
  return factor ? { id: factor.id, type: factor.type } : null;
}

/**
 * The sign-in state machine, following lib/admin/admin_controller.dart: the
 * page is only shown at `ready` (an admin with aal2), and it fails closed
 * whenever the check cannot finish.
 */
export class AuthController {
  private state: AuthState = INITIAL;
  private readonly listeners = new Set<() => void>();
  private unsubscribe: (() => void) | null = null;
  /** Raised when the signed-in identity is replaced; older work is dropped. */
  private generation = 0;
  private stopped = false;

  constructor(private readonly gateway: AdminAuthGateway | null) {}

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  readonly getState = () => this.state;

  get connected() {
    return this.gateway !== null;
  }

  private set(patch: Partial<AuthState>) {
    if (this.stopped) return;
    this.state = { ...this.state, ...patch };
    this.listeners.forEach((listener) => listener());
  }

  start() {
    this.stopped = false;
    if (!this.gateway) {
      this.set({ stage: 'unavailable' });
      return;
    }
    this.unsubscribe ??= this.gateway.onChange(() => void this.authChanged());
    void this.refresh();
  }

  stop() {
    this.stopped = true;
    this.generation += 1;
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  private async authChanged() {
    const gateway = this.gateway;
    if (!gateway || this.stopped) return;
    let current: AdminAccess;
    try {
      current = await gateway.access();
    } catch {
      this.set({ error: '登入狀態更新失敗，請重試；若仍無法登入，請登出後再試。' });
      return;
    }
    const known = this.state.access;
    // Token refreshes also notify; act only when who or what level changed.
    if (current.userId === known.userId && current.isAdmin === known.isAdmin && current.aal2 === known.aal2) {
      return;
    }
    if (current.userId !== known.userId || !current.isAdmin || !current.aal2) {
      // Revoke at once, even while another request is in flight.
      if (current.userId !== known.userId || !current.isAdmin) {
        this.generation += 1;
        this.set(PRIVATE);
      }
      this.set({ access: current, stage: stageOf(current) });
    }
    if (!this.state.refreshing && !this.state.busy) void this.refresh();
  }

  readonly refresh = async () => {
    const gateway = this.gateway;
    if (this.stopped || this.state.refreshing || !gateway) return;
    this.set({ refreshing: true, error: null });
    const generation = this.generation;
    try {
      const access = await gateway.access();
      if (generation !== this.generation) return;
      const signInFailed = gateway.takeSignInError();
      this.set({
        access,
        stage: stageOf(access),
        error: signInFailed ? 'Google 登入沒有完成，請再試一次。' : null,
      });
      if (!access.signedIn || !access.isAdmin) {
        this.set(PRIVATE);
        return;
      }
      const factors = await gateway.listFactors();
      if (generation !== this.generation) return;
      const latest = await gateway.access();
      if (generation !== this.generation) return;
      if (!latest.isAdmin) {
        this.set({ ...PRIVATE, access: latest, stage: stageOf(latest) });
        return;
      }
      const verified = factors.filter((factor) => factor.verified);
      const keep = verified.some((factor) => factor.id === this.state.selectedFactorId);
      this.set({
        factors,
        access: latest,
        stage: stageOf(latest),
        ...(keep ? {} : { selectedFactorId: verified[0]?.id ?? null, challenge: null }),
      });
    } catch {
      if (generation === this.generation) {
        // Never show the page before its access check has finished.
        this.set({ stage: 'unavailable', error: '無法讀取驗證方式，請檢查連線後重試。' });
      }
    } finally {
      this.set({ refreshing: false });
    }
  };

  private async run(action: (gateway: AdminAuthGateway) => Promise<void>, failure: string) {
    const gateway = this.gateway;
    if (this.state.busy || this.stopped || !gateway) return;
    this.set({ busy: true, error: null });
    try {
      await action(gateway);
    } catch {
      this.set({ error: failure });
    } finally {
      this.set({ busy: false });
    }
  }

  readonly signIn = () => this.run((gateway) => gateway.signIn(), '無法開啟 Google 登入，請重試。');

  readonly signOut = () =>
    this.run(async (gateway) => {
      await gateway.signOut();
      this.generation += 1;
      this.set({ ...PRIVATE, access: SIGNED_OUT, stage: 'signedOut' });
    }, '登出失敗，請檢查連線後重試。');

  readonly selectFactor = (id: string) => {
    if (this.state.busy || this.state.enrollment) return;
    this.set({ selectedFactorId: id, challenge: null, error: null });
  };

  readonly enroll = (type: FactorKind, name: string, phone: string | null) =>
    this.run(async (gateway) => {
      const { access, enrollment } = this.state;
      // A factor can be added here only before the first one exists.
      if (!access.isAdmin || enrollment || verifiedFactors(this.state).length > 0) return;
      const generation = this.generation;
      const result = await gateway.enroll(type, name, phone);
      if (generation === this.generation) this.set({ enrollment: result, challenge: null });
    }, '無法登記此驗證方式。請確認名稱未重複、未達數量上限；簡訊需先啟用供應商。');

  readonly sendChallenge = () =>
    this.run(async (gateway) => {
      const active = activeFactor(this.state);
      if (!active) return;
      const generation = this.generation;
      const challenge = await gateway.challenge(active.id);
      if (generation === this.generation && activeFactor(this.state)?.id === active.id) {
        this.set({ challenge });
      }
    }, '無法傳送驗證碼，請稍後重試或選擇另一個驗證方式。');

  readonly verify = (code: string) =>
    this.run(async (gateway) => {
      const active = activeFactor(this.state);
      if (!active) return;
      const generation = this.generation;
      let challenge = this.state.challenge;
      if (active.type === 'totp' || !challenge || challenge.expiresAt <= Date.now()) {
        if (active.type === 'phone') {
          this.set({ error: '請先傳送簡訊驗證碼；若已過期，請重新傳送。' });
          return;
        }
        challenge = await gateway.challenge(active.id);
        if (generation !== this.generation) return;
        this.set({ challenge });
      }
      await gateway.verify(active.id, challenge.id, code);
      if (generation !== this.generation) return;
      this.set({ enrollment: null, challenge: null });
      await this.refresh();
    }, '驗證碼不正確或已過期，請輸入最新的驗證碼後重試。');

  readonly cancelEnrollment = () =>
    this.run(async (gateway) => {
      const id = this.state.enrollment?.id;
      if (!id) return;
      await gateway.unenroll(id);
      this.set({ enrollment: null, challenge: null });
      await this.refresh();
    }, '無法取消登記，請重試。');

  readonly discardUnfinished = (id: string) =>
    this.run(async (gateway) => {
      if (!this.state.access.isAdmin || this.state.enrollment) return;
      if (!unfinishedFactors(this.state).some((factor) => factor.id === id)) return;
      const generation = this.generation;
      // Another tab may have completed the factor since this page loaded.
      const current = await gateway.listFactors();
      if (generation !== this.generation) return;
      if (!current.some((factor) => factor.id === id && !factor.verified)) {
        await this.refresh();
        this.set({ error: '這筆登記已完成或已移除，請確認目前的驗證方式。' });
        return;
      }
      await gateway.unenroll(id);
      if (generation === this.generation) await this.refresh();
    }, '無法取消這筆未完成的登記，請檢查連線後重試。');
}
