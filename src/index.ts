// RevokeGPT for React Native: a thin layer over the native iOS and Android SDKs (plan R8, R10).
// Arguments are checked here first; every native failure becomes a RevokeGPTError.

import { TurboModuleRegistry } from 'react-native';
import { fromNativeError, RevokeGPTError, RevokeGPTModuleMissingError } from './errors';
import type { Spec } from './NativeRevokeGPT';
import {
  isAction,
  isCdata,
  isKeyScope,
  isLanguageCode,
  isProjectNumber,
  isResponseToken,
  isSiteKey,
  isTheme,
  isTimeoutMs,
  isUrlString,
  type Theme,
} from './validation';

export type { RevokeGPTErrorCode } from './errors';
export {
  API_ERROR_CODES,
  ERROR_CODES,
  OWN_ERROR_CODES,
  RevokeGPTError,
  RevokeGPTModuleMissingError,
} from './errors';
export type { Theme } from './validation';

export interface Configuration {
  /** The site's public key, `rgpk_` and 20 letters and digits. */
  siteKey: string;
  /** The API origin; default `https://api.revokegpt.com`. */
  endpoint?: string;
  /** The hosted challenge page's origin; default `https://js.revokegpt.com`. */
  widgetOrigin?: string;
  /** The total deadline of one call, 1000 to 60000 ms; default 10000. */
  timeoutMs?: number;
  /** Android: your Google Cloud project number, as a decimal string. Without it Play is skipped. */
  cloudProjectNumber?: string;
  /** The hosted page's language; default the device's. */
  locale?: string;
  theme?: Theme;
  /**
   * iOS only: an opaque id of the app's signed-in account (1 to 1024 bytes of UTF-8), for one App
   * Attest key per account on the device (Apple's guidance); omit it for one key per install.
   * Only a keyed hash of it is stored; use an opaque value, not an email. Android ignores it
   * (Play Integrity keeps no per-app key).
   */
  keyScope?: string;
  /** Logs event names (never values) natively. */
  debugLogging?: boolean;
}

/** The message thrown when the TurboModule is missing (the old architecture, or no native build). */
export const MISSING_MODULE_MESSAGE =
  '@revokegpt/react-native: the RevokeGPT TurboModule is not available. This package needs the ' +
  'New Architecture (React Native 0.88 or later with newArchEnabled), and a native rebuild after ' +
  'installing it (pod install, then rebuild the app).';

let native: Spec | undefined;

/**
 * The TurboModule, looked up on first use: `TurboModuleRegistry.getEnforcing` throws when it is
 * absent, and that becomes one clear error instead of a failure at import time. Looked up here
 * rather than through NativeRevokeGPT.ts's default export (which codegen needs), so the lookup
 * is synchronous: a dynamic import() is a separate lazy bundle in Metro's dev server.
 */
function loadNative(): Spec {
  if (native) return native;
  try {
    native = TurboModuleRegistry.getEnforcing<Spec>('RevokeGPT');
  } catch {
    throw new RevokeGPTModuleMissingError(MISSING_MODULE_MESSAGE);
  }
  return native;
}

/** Runs one native call; a rejection becomes a RevokeGPTError (code and userInfo only). */
async function call<T>(f: (m: Spec) => Promise<T>): Promise<T> {
  const m = loadNative();
  try {
    return await f(m);
  } catch (e) {
    throw fromNativeError(e);
  }
}

const invalid = () => new RevokeGPTError('invalid-argument');

export const RevokeGPT = Object.freeze({
  /**
   * Configures the native SDK. A later call replaces the configuration. Rejects with
   * `invalid-argument` for a malformed setting and `busy` while a call is running.
   */
  async configure(c: Configuration): Promise<void> {
    if (typeof c !== 'object' || c === null || !isSiteKey(c.siteKey)) throw invalid();
    if (c.endpoint !== undefined && !isUrlString(c.endpoint)) throw invalid();
    if (c.widgetOrigin !== undefined && !isUrlString(c.widgetOrigin)) throw invalid();
    if (c.timeoutMs !== undefined && !isTimeoutMs(c.timeoutMs)) throw invalid();
    if (c.cloudProjectNumber !== undefined && !isProjectNumber(c.cloudProjectNumber))
      throw invalid();
    if (c.locale !== undefined && !isLanguageCode(c.locale)) throw invalid();
    if (c.theme !== undefined && !isTheme(c.theme)) throw invalid();
    if (c.keyScope !== undefined && !isKeyScope(c.keyScope)) throw invalid();
    if (c.debugLogging !== undefined && typeof c.debugLogging !== 'boolean') throw invalid();
    const config: Parameters<Spec['configure']>[0] = { siteKey: c.siteKey };
    if (c.endpoint !== undefined) config.endpoint = c.endpoint;
    if (c.widgetOrigin !== undefined) config.widgetOrigin = c.widgetOrigin;
    if (c.timeoutMs !== undefined) config.timeoutMs = c.timeoutMs;
    if (c.cloudProjectNumber !== undefined) config.cloudProjectNumber = c.cloudProjectNumber;
    if (c.locale !== undefined) config.locale = c.locale;
    if (c.theme !== undefined) config.theme = c.theme;
    if (c.keyScope !== undefined) config.keyScope = c.keyScope;
    if (c.debugLogging !== undefined) config.debugLogging = c.debugLogging;
    await call((m) => m.configure(config));
  },

  /**
   * A RevokeGPT token for `action` (1 to 100 of `A-Z a-z 0-9 / _`) and `cdata` (0 to 255 of
   * `A-Z a-z 0-9 _ -`). When the site's rules ask for a puzzle, the hosted page is shown over
   * the app. Send the token to your server, which verifies it with siteverify.
   */
  async execute(options: { action?: string; cdata?: string } = {}): Promise<string> {
    const { action, cdata } = options;
    if (action !== undefined && !isAction(action)) throw invalid();
    if (cdata !== undefined && !isCdata(cdata)) throw invalid();
    return call((m) => m.execute(action ?? null, cdata ?? null));
  },

  /** Account verification (protocol v1 section 17) for the request token your server received. */
  async challengeAccount(
    requestToken: string,
    options: { languageCode?: string } = {},
  ): Promise<string> {
    if (!isResponseToken(requestToken)) throw invalid();
    const { languageCode } = options;
    if (languageCode !== undefined && !isLanguageCode(languageCode)) throw invalid();
    return call((m) => m.challengeAccount(requestToken, languageCode ?? null));
  },
});

export default RevokeGPT;

/** Forgets the loaded native module (the tests load it again). */
export function forgetNativeModule(): void {
  native = undefined;
}
