/** Who is signed in, as far as this browser knows. The server still decides. */
export interface AdminAccess {
  signedIn: boolean;
  userId: string | null;
  email: string | null;
  /** JWT app_metadata.role is admin. */
  isAdmin: boolean;
  /** The session passed its second factor. */
  aal2: boolean;
}

export const SIGNED_OUT: AdminAccess = {
  signedIn: false,
  userId: null,
  email: null,
  isAdmin: false,
  aal2: false,
};

export type FactorKind = 'totp' | 'phone';

export interface AdminFactor {
  id: string;
  name: string | null;
  type: FactorKind;
  verified: boolean;
}

export interface Enrollment {
  id: string;
  type: FactorKind;
  /** TOTP only: an image URL for the QR code. */
  qrCode?: string;
  /** TOTP only: the setup key, for typing in by hand. */
  secret?: string;
  /** SMS only. */
  phone?: string;
}

export interface MfaChallenge {
  id: string;
  /** Milliseconds since the epoch. */
  expiresAt: number;
}

/**
 * Supabase Auth, narrowed to what the admin needs (lib/admin/admin_gateway.dart
 * is the Flutter counterpart). Everything here runs in the browser with the
 * public key: RLS and admin_v1 stay the authority.
 */
export interface AdminAuthGateway {
  access(): Promise<AdminAccess>;
  /** The session or its level changed. Listeners run outside auth's own lock. */
  onChange(listener: () => void): () => void;
  accessToken(): Promise<string | null>;
  /** The returning redirect failed; reported once, then forgotten. */
  takeSignInError(): boolean;
  signIn(): Promise<void>;
  signOut(): Promise<void>;
  listFactors(): Promise<AdminFactor[]>;
  enroll(type: FactorKind, name: string, phone: string | null): Promise<Enrollment>;
  challenge(factorId: string): Promise<MfaChallenge>;
  verify(factorId: string, challengeId: string, code: string): Promise<void>;
  unenroll(factorId: string): Promise<void>;
}
