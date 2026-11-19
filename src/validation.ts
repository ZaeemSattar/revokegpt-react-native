// Whole-string charset checks (protocol v1 sections 2, 10 and 23), the same rules the native SDKs
// apply, so a malformed argument fails in JavaScript before any native call.

const SITE_KEY = /^rgpk_[0-9A-Za-z]{20}$/;
const ACTION = /^[A-Za-z0-9/_]{1,100}$/;
const CDATA = /^[A-Za-z0-9_-]{0,255}$/;
const RESPONSE_TOKEN = /^[A-Za-z0-9_-]{1,2048}$/;
const LANGUAGE_CODE = /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}$/;
/** A positive decimal integer that fits a signed 64-bit integer (Android's `Long`). */
const PROJECT_NUMBER = /^[1-9][0-9]{0,18}$/;
const LONG_MAX = 9223372036854775807n;

export const THEMES = Object.freeze(['light', 'dark', 'auto'] as const);
export type Theme = (typeof THEMES)[number];

export const isSiteKey = (s: unknown): s is string => typeof s === 'string' && SITE_KEY.test(s);
export const isAction = (s: unknown): s is string => typeof s === 'string' && ACTION.test(s);
export const isCdata = (s: unknown): s is string => typeof s === 'string' && CDATA.test(s);
export const isResponseToken = (s: unknown): s is string =>
  typeof s === 'string' && RESPONSE_TOKEN.test(s);
export const isLanguageCode = (s: unknown): s is string =>
  typeof s === 'string' && s.length <= 35 && LANGUAGE_CODE.test(s);
export const isTheme = (s: unknown): s is Theme =>
  typeof s === 'string' && (THEMES as readonly string[]).includes(s);
export const isTimeoutMs = (n: unknown): n is number =>
  typeof n === 'number' && Number.isInteger(n) && n >= 1000 && n <= 60000;
export const isProjectNumber = (s: unknown): s is string =>
  typeof s === 'string' && PROJECT_NUMBER.test(s) && BigInt(s) <= LONG_MAX;
/** A URL string; the native SDKs apply the scheme, host and origin rules (plan R9). */
/**
 * UTF-8 byte length of well-formed UTF-16, or -1 for a lone surrogate. Counted by hand: Hermes
 * has neither `String.prototype.isWellFormed` nor, on every version, `TextEncoder`.
 */
function utf8Length(s: string): number {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff) {
      const d = s.charCodeAt(i + 1);
      if (!(d >= 0xdc00 && d <= 0xdfff)) return -1;
      n += 4;
      i++;
    } else if (c >= 0xdc00 && c <= 0xdfff) return -1;
    else n += 3;
  }
  return n;
}

/** iOS `keyScope`: 1 to 1024 bytes of UTF-8 (the iOS SDK's rule); a lone surrogate is refused. */
export const isKeyScope = (s: unknown): s is string => {
  if (typeof s !== 'string') return false;
  const n = utf8Length(s);
  return n >= 1 && n <= 1024;
};
export const isUrlString = (s: unknown): s is string =>
  typeof s === 'string' && s.length > 0 && s.length <= 2048 && !/[\s\\]/.test(s);
