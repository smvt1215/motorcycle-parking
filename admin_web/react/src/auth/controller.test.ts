import { describe, expect, it, vi } from 'vitest';
import { AuthController } from './controller';
import { SIGNED_OUT, type AdminAccess, type AdminAuthGateway, type AdminFactor } from './gateway';

const ADMIN_AAL1: AdminAccess = { signedIn: true, userId: 'u1', email: null, isAdmin: true, aal2: false };
const ADMIN_AAL2: AdminAccess = { ...ADMIN_AAL1, aal2: true };
const FACTOR: AdminFactor = { id: 'f1', name: '手機', type: 'totp', verified: true };

function fakeGateway(initial: AdminAccess, factors: AdminFactor[] = [FACTOR]) {
  let access = initial;
  let listener: () => void = () => undefined;
  const gateway: AdminAuthGateway = {
    access: vi.fn(async () => access),
    onChange: (next) => {
      listener = next;
      return () => undefined;
    },
    accessToken: async () => 'token',
    takeSignInError: () => false,
    signIn: vi.fn(async () => undefined),
    signOut: vi.fn(async () => {
      access = SIGNED_OUT;
    }),
    listFactors: vi.fn(async () => factors),
    enroll: vi.fn(async () => ({ id: 'new', type: 'totp' as const })),
    challenge: vi.fn(async () => ({ id: 'c1', expiresAt: Date.now() + 60000 })),
    verify: vi.fn(async () => {
      access = ADMIN_AAL2;
    }),
    unenroll: vi.fn(async () => undefined),
  };
  return {
    gateway,
    set: (next: AdminAccess) => {
      access = next;
      listener();
    },
  };
}

const settled = () => new Promise((resolve) => setTimeout(resolve, 0));

async function started(gateway: AdminAuthGateway) {
  const controller = new AuthController(gateway);
  controller.start();
  await settled();
  return controller;
}

describe('AuthController', () => {
  it('fails closed without a backend', () => {
    const controller = new AuthController(null);
    controller.start();
    expect(controller.getState().stage).toBe('unavailable');
    expect(controller.connected).toBe(false);
  });

  it('finishes the check when StrictMode stops and restarts it', async () => {
    const { gateway } = fakeGateway(ADMIN_AAL2);
    const controller = new AuthController(gateway);
    controller.start();
    controller.stop();
    controller.start();
    await settled();
    expect(controller.getState().stage).toBe('ready');
    expect(controller.getState().refreshing).toBe(false);
  });

  it('asks for a second factor before an admin gets in', async () => {
    const { gateway } = fakeGateway(ADMIN_AAL1);
    const controller = await started(gateway);
    expect(controller.getState().stage).toBe('mfa');
    expect(controller.getState().selectedFactorId).toBe('f1');
    await controller.verify('123456');
    expect(gateway.verify).toHaveBeenCalledWith('f1', 'c1', '123456');
    expect(controller.getState().stage).toBe('ready');
  });

  it('turns away a signed-in non-admin even at aal2', async () => {
    const { gateway } = fakeGateway({ ...ADMIN_AAL2, isAdmin: false });
    const controller = await started(gateway);
    expect(controller.getState().stage).toBe('denied');
    expect(gateway.listFactors).not.toHaveBeenCalled();
  });

  it('never opens the page when the factor check fails', async () => {
    const { gateway } = fakeGateway(ADMIN_AAL2);
    vi.mocked(gateway.listFactors).mockRejectedValueOnce(new Error('offline'));
    const controller = await started(gateway);
    expect(controller.getState().stage).toBe('unavailable');
  });

  it('drops to the second factor as soon as the session loses it', async () => {
    const { gateway, set } = fakeGateway(ADMIN_AAL2);
    const controller = await started(gateway);
    expect(controller.getState().stage).toBe('ready');
    set(ADMIN_AAL1);
    await settled();
    expect(controller.getState().stage).toBe('mfa');
  });

  it('clears the factors when the identity changes', async () => {
    const { gateway, set } = fakeGateway(ADMIN_AAL1);
    const controller = await started(gateway);
    set(SIGNED_OUT);
    await settled();
    expect(controller.getState().stage).toBe('signedOut');
    expect(controller.getState().factors).toEqual([]);
  });

  it('ignores token refreshes that change nothing', async () => {
    const { gateway, set } = fakeGateway(ADMIN_AAL2);
    await started(gateway);
    vi.mocked(gateway.listFactors).mockClear();
    set(ADMIN_AAL2);
    await settled();
    expect(gateway.listFactors).not.toHaveBeenCalled();
  });

  it('keeps a wrong code on the second step with a message', async () => {
    const { gateway } = fakeGateway(ADMIN_AAL1);
    vi.mocked(gateway.verify).mockRejectedValueOnce(new Error('invalid'));
    const controller = await started(gateway);
    await controller.verify('000000');
    expect(controller.getState().stage).toBe('mfa');
    expect(controller.getState().error).toContain('驗證碼不正確');
  });

  it('will not enrol another factor from the sign-in step', async () => {
    const { gateway } = fakeGateway(ADMIN_AAL1);
    const controller = await started(gateway);
    await controller.enroll('totp', '第二個', null);
    expect(gateway.enroll).not.toHaveBeenCalled();
  });

  it('requires a sent SMS challenge before verifying', async () => {
    const { gateway } = fakeGateway(ADMIN_AAL1, [{ id: 'p1', name: null, type: 'phone', verified: true }]);
    const controller = await started(gateway);
    await controller.verify('123456');
    expect(gateway.verify).not.toHaveBeenCalled();
    expect(controller.getState().error).toContain('請先傳送簡訊驗證碼');
  });

  it('signs out to the first step', async () => {
    const { gateway } = fakeGateway(ADMIN_AAL2);
    const controller = await started(gateway);
    await controller.signOut();
    expect(controller.getState().stage).toBe('signedOut');
  });
});
