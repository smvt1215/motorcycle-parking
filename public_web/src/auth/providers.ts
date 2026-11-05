// The providers' browser SDKs, loaded on first use: Google Identity
// Services (google.accounts.id) and Sign in with Apple JS (AppleID.auth).
// Only the parts the page calls are typed here.

export const GSI_SCRIPT = 'https://accounts.google.com/gsi/client';
export const APPLE_SCRIPT =
  'https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/en_US/appleid.auth.js';

/** google.accounts.id, as far as the page uses it. */
export interface GoogleIdApi {
  initialize(config: {
    client_id: string;
    callback: (response: { credential?: string }) => void;
    nonce: string;
    auto_select?: boolean;
    cancel_on_tap_outside?: boolean;
    ux_mode?: 'popup' | 'redirect';
    itp_support?: boolean;
  }): void;
  renderButton(
    parent: HTMLElement,
    options: {
      type: 'standard' | 'icon';
      theme?: 'outline' | 'filled_blue' | 'filled_black';
      size?: 'large' | 'medium' | 'small';
      text?: 'signin_with' | 'signup_with' | 'continue_with' | 'signin';
      shape?: 'rectangular' | 'pill' | 'circle' | 'square';
      logo_alignment?: 'left' | 'center';
      width?: number;
      locale?: string;
    },
  ): void;
}

/** What AppleID.auth.signIn() resolves to with usePopup. */
export interface AppleSignInResponse {
  authorization?: { code?: string; id_token?: string; state?: string };
}

/** AppleID.auth, as far as the page uses it. */
export interface AppleIdAuthApi {
  init(config: {
    clientId: string;
    scope: string;
    redirectURI: string;
    state: string;
    nonce: string;
    usePopup: boolean;
  }): void;
  signIn(): Promise<AppleSignInResponse>;
}

declare global {
  interface Window {
    google?: { accounts?: { id?: GoogleIdApi } };
    AppleID?: { auth?: AppleIdAuthApi };
  }
}

const loading = new Map<string, Promise<void>>();

/** Adds the script once; a failed load can be tried again. */
export function loadScript(src: string): Promise<void> {
  let promise = loading.get(src);
  if (!promise) {
    promise = new Promise<void>((resolve, reject) => {
      const script = document.createElement('script');
      script.src = src;
      script.async = true;
      script.onload = () => resolve();
      script.onerror = () => {
        loading.delete(src);
        script.remove();
        reject(new Error(`could not load ${src}`));
      };
      document.head.append(script);
    });
    loading.set(src, promise);
  }
  return promise;
}

export async function loadGoogle(): Promise<GoogleIdApi> {
  await loadScript(GSI_SCRIPT);
  const api = window.google?.accounts?.id;
  if (!api) throw new Error('Google Identity Services did not start');
  return api;
}

export async function loadApple(): Promise<AppleIdAuthApi> {
  await loadScript(APPLE_SCRIPT);
  const api = window.AppleID?.auth;
  if (!api) throw new Error('Sign in with Apple JS did not start');
  return api;
}
