#import "RNRevokeGPT.h"

#import <React/RCTUtils.h>

#if __has_include(<RevokeGPTReactNative/RevokeGPTReactNative-Swift.h>)
#import <RevokeGPTReactNative/RevokeGPTReactNative-Swift.h>
#else
#import "RevokeGPTReactNative-Swift.h"
#endif

/// The domain of the NSError a rejection carries; its userInfo holds only the status, the request
/// id and the retry-after seconds (RNRevokeGPTImpl.rejection), which React Native passes to
/// JavaScript as the error's userInfo.
static NSString *const RNRevokeGPTErrorDomain = @"com.revokegpt.reactnative";

/// RNRevokeGPTImpl's completion: a value, or a code and its details.
typedef void (^RNRevokeGPTCompletion)(NSString *_Nullable value, NSString *_Nullable code,
                                      NSDictionary<NSString *, id> *_Nullable details);

/// Settles a promise from an RNRevokeGPTImpl completion. The rejection's message is the code
/// itself: no native text reaches JavaScript.
static RNRevokeGPTCompletion RNRevokeGPTSettle(RCTPromiseResolveBlock resolve,
                                                   RCTPromiseRejectBlock reject)
{
  return ^(NSString *_Nullable value, NSString *_Nullable code, NSDictionary<NSString *, id> *_Nullable details) {
    if (code != nil) {
      NSError *error = [NSError errorWithDomain:RNRevokeGPTErrorDomain code:0 userInfo:details ?: @{}];
      reject(code, code, error);
    } else {
      resolve(value);
    }
  };
}

@implementation RNRevokeGPT {
  RNRevokeGPTImpl *_impl;
}

+ (NSString *)moduleName
{
  return @"RevokeGPT";
}

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

- (instancetype)init
{
  if (self = [super init]) {
    // React Native's top-most presented view controller; called on the main thread only.
    _impl = [[RNRevokeGPTImpl alloc] initWithPresenter:^UIViewController *_Nullable {
      return RCTPresentedViewController();
    }];
  }
  return self;
}

- (void)invalidate
{
  [_impl cancelAll];
}

- (void)configure:(JS::NativeRevokeGPT::SpecConfigureConfig &)config
          resolve:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject
{
  std::optional<double> timeoutMs = config.timeoutMs();
  std::optional<bool> debugLogging = config.debugLogging();
  // cloudProjectNumber is Android-only (Play Integrity) and has no iOS meaning.
  [_impl configureWithSiteKey:config.siteKey() ?: @""
                     endpoint:config.endpoint()
                 widgetOrigin:config.widgetOrigin()
                    timeoutMs:timeoutMs.has_value() ? @(timeoutMs.value()) : nil
                       locale:config.locale()
                        theme:config.theme()
                     keyScope:config.keyScope()
                 debugLogging:debugLogging.has_value() ? @(debugLogging.value()) : nil
                   completion:RNRevokeGPTSettle(resolve, reject)];
}

- (void)execute:(NSString *_Nullable)action
          cdata:(NSString *_Nullable)cdata
        resolve:(RCTPromiseResolveBlock)resolve
         reject:(RCTPromiseRejectBlock)reject
{
  [_impl executeWithAction:action cdata:cdata completion:RNRevokeGPTSettle(resolve, reject)];
}

- (void)challengeAccount:(NSString *)requestToken
            languageCode:(NSString *_Nullable)languageCode
                 resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject
{
  [_impl challengeAccountWithRequestToken:requestToken
                             languageCode:languageCode
                               completion:RNRevokeGPTSettle(resolve, reject)];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeRevokeGPTSpecJSI>(params);
}

@end
