// The TurboModule spec (codegen reads this file; plan R8: New Architecture only, no legacy bridge).
import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export interface Spec extends TurboModule {
  /** Resolves once the native SDK is configured; rejects with `invalid-argument` or `busy`. */
  configure(config: {
    siteKey: string;
    endpoint?: string;
    widgetOrigin?: string;
    timeoutMs?: number;
    /** A decimal string: a Google Cloud project number can exceed JavaScript's safe integers. */
    cloudProjectNumber?: string;
    locale?: string;
    theme?: string;
    /** iOS only: a per-account scope for the App Attest key. Android ignores it. */
    keyScope?: string;
    debugLogging?: boolean;
  }): Promise<void>;
  execute(action: string | null, cdata: string | null): Promise<string>;
  challengeAccount(requestToken: string, languageCode: string | null): Promise<string>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('RevokeGPT');
