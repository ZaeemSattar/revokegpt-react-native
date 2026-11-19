import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const mockNative = {
  configure: jest.fn(async (_c: unknown) => undefined),
  execute: jest.fn(async (_a: string | null, _c: string | null) => 'dG9rZW4'),
  challengeAccount: jest.fn(async (_t: string, _l: string | null) => 'bWZh'),
};
let mockPresent = true;
const mockLookups: string[] = [];

jest.mock('react-native', () => ({
  TurboModuleRegistry: {
    getEnforcing: (name: string) => {
      mockLookups.push(name);
      if (!mockPresent || name !== 'RevokeGPT') {
        throw new Error(`TurboModuleRegistry.getEnforcing(...): '${name}' could not be found.`);
      }
      return mockNative;
    },
  },
}));

import { fromNativeError } from '../errors';
import {
  API_ERROR_CODES,
  ERROR_CODES,
  forgetNativeModule,
  MISSING_MODULE_MESSAGE,
  OWN_ERROR_CODES,
  RevokeGPT,
  RevokeGPTError,
} from '../index';

/** The shared vectors, in the plan's loading order (`$REVOKEGPT_VECTORS_DIR`, `./vectors`, the monorepo). */
function vectors(name: string): Record<string, unknown> {
  const root = join(__dirname, '..', '..');
  const dirs = [
    process.env.REVOKEGPT_VECTORS_DIR,
    join(root, 'vectors'),
    join(root, '..', '..', 'packages', 'protocol', 'test-vectors'),
  ];
  const dir = dirs.find((d) => d && existsSync(join(d, `${name}.json`)));
  if (!dir) throw new Error(`no ${name}.json`);
  return JSON.parse(readFileSync(join(dir, `${name}.json`), 'utf8'));
}

beforeEach(() => {
  mockPresent = true;
  forgetNativeModule();
  jest.clearAllMocks();
});

const code = async (p: Promise<unknown>) => {
  try {
    await p;
  } catch (e) {
    return e instanceof RevokeGPTError ? e.code : `not a RevokeGPTError: ${String(e)}`;
  }
  return 'resolved';
};

describe('arguments', () => {
  test('configure passes only the given settings', async () => {
    await RevokeGPT.configure({
      siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw',
      timeoutMs: 5000,
      cloudProjectNumber: '123456789012',
      theme: 'dark',
    });
    expect(mockNative.configure).toHaveBeenCalledWith({
      siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw',
      timeoutMs: 5000,
      cloudProjectNumber: '123456789012',
      theme: 'dark',
    });
  });

  test.each([
    [{ siteKey: 'rgpk_short' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw ' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', timeoutMs: 999 }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', timeoutMs: 1500.5 }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', timeoutMs: 60001 }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', cloudProjectNumber: '0' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', cloudProjectNumber: '-1' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', cloudProjectNumber: '9223372036854775808' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', cloudProjectNumber: '1e3' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', locale: 'en_US' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', theme: 'Dark' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', endpoint: '' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', widgetOrigin: 'https://x .example' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', keyScope: '' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', keyScope: 'a'.repeat(1025) }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', keyScope: '\u00e9'.repeat(513) }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', keyScope: 'user-\ud800' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', keyScope: '\udc00x' }],
    [{ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', keyScope: 42 }],
    [null],
  ])('configure refuses %j before any native call', async (c) => {
    expect(await code(RevokeGPT.configure(c as never))).toBe('invalid-argument');
    expect(mockNative.configure).not.toHaveBeenCalled();
  });

  test('keyScope (iOS only) is passed through at 1 to 1024 bytes of UTF-8', async () => {
    for (const keyScope of ['u', 'a'.repeat(1024), '\u00e9'.repeat(512), '\u{1F600}'.repeat(256)]) {
      await RevokeGPT.configure({ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw', keyScope });
      expect(mockNative.configure).toHaveBeenLastCalledWith({
        siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw',
        keyScope,
      });
    }
  });

  test('the largest Long project number is accepted', async () => {
    await RevokeGPT.configure({
      siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw',
      cloudProjectNumber: '9223372036854775807',
    });
    expect(mockNative.configure).toHaveBeenCalledTimes(1);
  });

  test('execute passes null for what is absent', async () => {
    expect(await RevokeGPT.execute()).toBe('dG9rZW4');
    expect(mockNative.execute).toHaveBeenLastCalledWith(null, null);
    await RevokeGPT.execute({ action: 'checkout/pay', cdata: '' });
    expect(mockNative.execute).toHaveBeenLastCalledWith('checkout/pay', '');
  });

  test.each([
    { action: '' },
    { action: 'log in' },
    { action: 'a'.repeat(101) },
    { cdata: 'a b' },
    { cdata: 'x'.repeat(256) },
  ])('execute refuses %j before any native call', async (o) => {
    expect(await code(RevokeGPT.execute(o))).toBe('invalid-argument');
    expect(mockNative.execute).not.toHaveBeenCalled();
  });

  test('challengeAccount', async () => {
    expect(await RevokeGPT.challengeAccount('cmVxdWVzdA', { languageCode: 'pt-BR' })).toBe('bWZh');
    expect(mockNative.challengeAccount).toHaveBeenLastCalledWith('cmVxdWVzdA', 'pt-BR');
    for (const [t, l] of [
      ['', undefined],
      ['a b', undefined],
      ['cmVxdWVzdA', 'x'],
    ] as const) {
      expect(
        await code(RevokeGPT.challengeAccount(t, l === undefined ? {} : { languageCode: l })),
      ).toBe('invalid-argument');
    }
    expect(mockNative.challengeAccount).toHaveBeenCalledTimes(1);
  });
});

describe('errors', () => {
  test('the code lists equal mobile-client.json', () => {
    const v = vectors('mobile-client') as { sdkErrorCodes: string[]; apiErrorCodes: string[] };
    expect([...API_ERROR_CODES]).toEqual(v.apiErrorCodes);
    expect([...ERROR_CODES]).toEqual(v.sdkErrorCodes);
    expect(OWN_ERROR_CODES).toHaveLength(11);
  });

  test('a native rejection maps code and userInfo, never the message', async () => {
    mockNative.execute.mockRejectedValueOnce(
      Object.assign(new Error('lower layer: rgpk_7Hq2LmZ9xK4aRb3Nf8Tw token'), {
        code: 'rate-limited',
        userInfo: { status: 429, requestId: 'req-7', retryAfterSeconds: 7 },
      }),
    );
    const e = await RevokeGPT.execute().catch((x: unknown) => x);
    expect(e).toBeInstanceOf(RevokeGPTError);
    const r = e as RevokeGPTError;
    expect([r.code, r.status, r.requestId, r.retryAfterSeconds]).toEqual([
      'rate-limited',
      429,
      'req-7',
      7,
    ]);
    expect(r.message).toBe('RevokeGPT error: rate-limited');
    expect(String(r)).not.toContain('rgpk_');
  });

  test.each([
    [{ code: 'frobnicated' }, 'internal'],
    [{ code: 42 }, 'internal'],
    [{}, 'internal'],
    ['string error', 'internal'],
    [null, 'internal'],
    [{ code: 'cancelled' }, 'cancelled'],
    [{ code: 'challenge-required' }, 'challenge-required'],
    [{ code: 'app-not-allowed' }, 'app-not-allowed'],
  ])('rejection %j is %s', (raw, want) => {
    expect(fromNativeError(raw).code).toBe(want);
  });

  test('odd userInfo values are dropped', () => {
    for (const info of [
      { status: '429', requestId: 'has space', retryAfterSeconds: 3601 },
      { status: 99, requestId: 'x'.repeat(129), retryAfterSeconds: -1 },
      { status: 200.5, requestId: 7, retryAfterSeconds: 1.5 },
    ]) {
      const e = fromNativeError({ code: 'rate-limited', userInfo: info });
      expect([e.status, e.requestId, e.retryAfterSeconds]).toEqual([0, undefined, undefined]);
    }
  });
});

describe('the TurboModule', () => {
  test('missing (the old architecture): one clear error, from every call', async () => {
    mockPresent = false;
    forgetNativeModule();
    jest.resetModules();
    const fresh = (await import('../index')) as typeof import('../index');
    for (const p of [
      fresh.RevokeGPT.execute(),
      fresh.RevokeGPT.configure({ siteKey: 'rgpk_7Hq2LmZ9xK4aRb3Nf8Tw' }),
    ]) {
      const e = await p.catch((x: unknown) => x);
      // A RevokeGPTError (code internal) whose message says why.
      expect(e).toBeInstanceOf(fresh.RevokeGPTError);
      expect((e as InstanceType<typeof fresh.RevokeGPTError>).code).toBe('internal');
      expect((e as Error).message).toBe(MISSING_MODULE_MESSAGE);
    }
    expect(MISSING_MODULE_MESSAGE).toContain('New Architecture');
  });

  test('loaded once, by the name the native modules register', async () => {
    forgetNativeModule();
    mockLookups.length = 0;
    await RevokeGPT.execute();
    await RevokeGPT.execute();
    expect(mockNative.execute).toHaveBeenCalledTimes(2);
    // index.ts looks the module up once, by that name; NativeRevokeGPT.ts (codegen's input) names
    // the same module.
    expect(mockLookups).toEqual(['RevokeGPT']);
    const spec = readFileSync(join(__dirname, '..', 'NativeRevokeGPT.ts'), 'utf8');
    expect(spec).toContain("TurboModuleRegistry.getEnforcing<Spec>('RevokeGPT')");
  });
});
