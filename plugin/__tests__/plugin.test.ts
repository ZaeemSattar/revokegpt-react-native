import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import plugin, { APP_ATTEST_ENTITLEMENT, withAppAttestEntitlement } from '../index';

type Mod = (c: {
  modResults: Record<string, unknown>;
}) => { modResults: Record<string, unknown> } | Promise<{ modResults: Record<string, unknown> }>;

/** The entitlements mod the plugin registered, run on [entitlements] (as `expo prebuild` would). */
async function runEntitlements(
  config: Record<string, unknown>,
  entitlements: Record<string, unknown>,
) {
  const mods = (config.mods as { ios?: { entitlements?: Mod } } | undefined)?.ios?.entitlements;
  if (!mods) throw new Error('no entitlements mod');
  const out = await mods({
    modResults: entitlements,
    ...({ modRequest: { platform: 'ios', nextMod: (c: unknown) => c } } as object),
  } as never);
  return out.modResults;
}

const base = () => ({ name: 'app', slug: 'app' });

describe('the App Attest entitlement', () => {
  test('adds exactly one key, production by default, keeping the rest', () => {
    const before = { 'aps-environment': 'production' };
    const after = withAppAttestEntitlement(before);
    expect(after).toEqual({
      'aps-environment': 'production',
      [APP_ATTEST_ENTITLEMENT]: 'production',
    });
    expect(Object.keys(after).filter((k) => !(k in before))).toEqual([APP_ATTEST_ENTITLEMENT]);
    expect(before).toEqual({ 'aps-environment': 'production' });
  });

  test('is idempotent and replaces a previous environment', () => {
    const once = withAppAttestEntitlement({}, 'development');
    expect(withAppAttestEntitlement(once, 'development')).toEqual(once);
    expect(withAppAttestEntitlement(once, 'production')).toEqual({
      [APP_ATTEST_ENTITLEMENT]: 'production',
    });
  });

  test.each(['staging', '', 'Production', 1, null])('refuses the environment %p', (env) => {
    expect(() => withAppAttestEntitlement({}, env)).toThrow('appAttestEnvironment');
  });
});

describe('the config plugin', () => {
  test('registers the entitlements mod, which sets the key', async () => {
    const config = plugin(base() as never, {
      appAttestEnvironment: 'development',
    }) as unknown as Record<string, unknown>;
    expect(await runEntitlements(config, { other: true })).toEqual({
      other: true,
      [APP_ATTEST_ENTITLEMENT]: 'development',
    });
  });

  test('runs once: applying it twice adds one key and one mod', async () => {
    const once = plugin(base() as never, undefined) as never;
    const twice = plugin(once, undefined) as unknown as Record<string, unknown>;
    expect(await runEntitlements(twice, {})).toEqual({ [APP_ATTEST_ENTITLEMENT]: 'production' });
    expect(
      (twice._internal as { pluginHistory?: Record<string, unknown> }).pluginHistory,
    ).toHaveProperty(['@revokegpt/react-native']);
  });

  test('a bad option fails at once', () => {
    expect(() => plugin(base() as never, { appAttestEnvironment: 'staging' as never })).toThrow(
      'appAttestEnvironment',
    );
  });

  test('changes nothing for Android', () => {
    const config = plugin(base() as never, undefined) as unknown as {
      mods?: Record<string, unknown>;
    };
    expect(Object.keys(config.mods ?? {})).toEqual(['ios']);
  });

  test('app.plugin.js points at the built plugin', () => {
    expect(readFileSync(join(__dirname, '..', '..', 'app.plugin.js'), 'utf8')).toContain(
      "require('./plugin/build')",
    );
  });
});
