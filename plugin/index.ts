// The Expo config plugin (`plugins: ["@revokegpt/react-native"]`): adds the App Attest entitlement
// to the iOS app. Android needs no change (the SDK's manifest merges in by itself).
import {
  type ConfigPlugin,
  createRunOncePlugin,
  withEntitlementsPlist,
} from '@expo/config-plugins';

export const APP_ATTEST_ENTITLEMENT = 'com.apple.developer.devicecheck.appattest-environment';

export type AppAttestEnvironment = 'development' | 'production';

export interface PluginOptions {
  /** `production` (the default) for TestFlight and the App Store; `development` while you develop. */
  appAttestEnvironment?: AppAttestEnvironment;
}

/**
 * The entitlements with the App Attest key set to `environment`: exactly one key added or
 * replaced, every other entitlement kept. Throws for an environment other than the two.
 */
export function withAppAttestEntitlement(
  entitlements: Record<string, unknown>,
  environment: unknown = 'production',
): Record<string, unknown> {
  if (environment !== 'development' && environment !== 'production') {
    throw new Error(
      `@revokegpt/react-native: appAttestEnvironment must be "development" or "production"`,
    );
  }
  return { ...entitlements, [APP_ATTEST_ENTITLEMENT]: environment };
}

const withRevokeGPT: ConfigPlugin<PluginOptions | undefined> = (config, options) => {
  const environment = options?.appAttestEnvironment ?? 'production';
  // Validated now, so a typo fails `expo prebuild` at once rather than at the mod step.
  withAppAttestEntitlement({}, environment);
  return withEntitlementsPlist(config, (c) => {
    c.modResults = withAppAttestEntitlement(
      c.modResults as Record<string, unknown>,
      environment,
    ) as typeof c.modResults;
    return c;
  });
};

export default createRunOncePlugin(withRevokeGPT, '@revokegpt/react-native', '0.1.1');
