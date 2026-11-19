// The SDK error (protocol v1 section 23.3), mapped from the native reject's `code` and `userInfo`.
// A native error carries the code only: no message from a lower layer reaches JavaScript.

/** The SDK's own codes (`MOBILE_OWN_ERROR_CODES`), in protocol order. */
export const OWN_ERROR_CODES = Object.freeze([
  'invalid-argument',
  'not-configured',
  'network-error',
  'timeout',
  'http-error',
  'invalid-response',
  'challenge-required',
  'challenge-unsupported',
  'cancelled',
  'busy',
  'internal',
] as const);

/** `API_ERROR_CODES`, in protocol order: passed through from an error body. */
export const API_ERROR_CODES = Object.freeze([
  'bad-request',
  'not-found',
  'payload-too-large',
  'invalid-site-key',
  'hostname-not-allowed',
  'site-disabled',
  'challenge-expired',
  'challenge-invalid',
  'pow-invalid',
  'rate-limited',
  'quota-exceeded',
  'internal-error',
  'unsupported-media-type',
  'app-not-allowed',
  'plan-required',
  'plan-restricted',
] as const);

/** Every code a RevokeGPTError carries (`MOBILE_SDK_ERRORS`). */
export const ERROR_CODES: readonly string[] = Object.freeze([
  ...OWN_ERROR_CODES,
  ...API_ERROR_CODES.filter((c) => !(OWN_ERROR_CODES as readonly string[]).includes(c)),
]);

export type RevokeGPTErrorCode =
  | (typeof OWN_ERROR_CODES)[number]
  | (typeof API_ERROR_CODES)[number];

const REQUEST_ID = /^[A-Za-z0-9._:-]{1,128}$/;

/**
 * Why a RevokeGPT call failed. `message` is fixed (`RevokeGPT error: <code>`); `status` is the
 * HTTP status (0 when there was none), `requestId` the server's when it sent a well-formed one,
 * and `retryAfterSeconds` the server's `Retry-After` on a 429 or 503.
 */
export class RevokeGPTError extends Error {
  readonly code: RevokeGPTErrorCode;
  readonly status: number;
  readonly requestId: string | undefined;
  readonly retryAfterSeconds: number | undefined;

  constructor(
    code: RevokeGPTErrorCode,
    status = 0,
    requestId?: string,
    retryAfterSeconds?: number,
  ) {
    super(`RevokeGPT error: ${code}`);
    this.name = 'RevokeGPTError';
    this.code = code;
    this.status = status;
    this.requestId = requestId;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

/**
 * `internal`, with a message that says why: the TurboModule is not in this build (the old
 * architecture, or no native rebuild after installing). Still a `RevokeGPTError`, so an app's
 * `instanceof RevokeGPTError` handling catches it.
 */
export class RevokeGPTModuleMissingError extends RevokeGPTError {
  constructor(message: string) {
    super('internal');
    this.message = message;
  }
}

const isRecord = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

/**
 * The error for a native rejection: its `code` when it is one of the protocol's codes (else
 * `internal`, as section 23.3 asks of a wrapper), and from `userInfo` only well-typed, in-range
 * values. Nothing else is read: the native message is never passed through.
 */
export function fromNativeError(e: unknown): RevokeGPTError {
  if (!isRecord(e)) return new RevokeGPTError('internal');
  const code = typeof e.code === 'string' && ERROR_CODES.includes(e.code) ? e.code : 'internal';
  const info = isRecord(e.userInfo) ? e.userInfo : {};
  const status =
    typeof info.status === 'number' &&
    Number.isInteger(info.status) &&
    info.status >= 100 &&
    info.status <= 599
      ? info.status
      : 0;
  const requestId =
    typeof info.requestId === 'string' && REQUEST_ID.test(info.requestId)
      ? info.requestId
      : undefined;
  const retry =
    typeof info.retryAfterSeconds === 'number' &&
    Number.isInteger(info.retryAfterSeconds) &&
    info.retryAfterSeconds >= 0 &&
    info.retryAfterSeconds <= 3600
      ? info.retryAfterSeconds
      : undefined;
  return new RevokeGPTError(code as RevokeGPTErrorCode, status, requestId, retry);
}
