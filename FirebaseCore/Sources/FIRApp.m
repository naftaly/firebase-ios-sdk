// Copyright 2017 Google
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <sys/utsname.h>

#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#endif

#if __has_include(<AppKit/AppKit.h>)
#import <AppKit/AppKit.h>
#endif

#if __has_include(<WatchKit/WatchKit.h>)
#import <WatchKit/WatchKit.h>
#endif

#import "FirebaseCore/Sources/Public/FirebaseCore/FIRApp.h"

#import "FirebaseCore/Sources/FIRAnalyticsConfiguration.h"
#import "FirebaseCore/Sources/FIRBundleUtil.h"
#import "FirebaseCore/Sources/FIRComponentContainerInternal.h"
#import "FirebaseCore/Sources/FIRConfigurationInternal.h"
#import "FirebaseCore/Sources/FIRFirebaseUserAgent.h"

#import "FirebaseCore/Extension/FIRAppInternal.h"
#import "FirebaseCore/Extension/FIRHeartbeatLogger.h"
#import "FirebaseCore/Extension/FIRLibrary.h"
#import "FirebaseCore/Extension/FIRLogger.h"
#import "FirebaseCore/Sources/FIROptionsInternal.h"
#import "FirebaseCore/Sources/Public/FirebaseCore/FIROptions.h"
#import "FirebaseCore/Sources/Public/FirebaseCore/FIRVersion.h"

#import <GoogleUtilities/GULAppEnvironmentUtil.h>

#import <objc/runtime.h>

NSString *const kFIRDefaultAppName = @"__FIRAPP_DEFAULT";
NSString *const kFIRAppReadyToConfigureSDKNotification = @"FIRAppReadyToConfigureSDKNotification";
NSString *const kFIRAppDeleteNotification = @"FIRAppDeleteNotification";
NSString *const kFIRAppIsDefaultAppKey = @"FIRAppIsDefaultAppKey";
NSString *const kFIRAppNameKey = @"FIRAppNameKey";
NSString *const kFIRGoogleAppIDKey = @"FIRGoogleAppIDKey";

NSString *const kFIRGlobalAppDataCollectionEnabledDefaultsKeyFormat =
    @"/google/firebase/global_data_collection_enabled:%@";
NSString *const kFIRGlobalAppDataCollectionEnabledPlistKey =
    @"FirebaseDataCollectionDefaultEnabled";

NSString *const kFIRAppDiagnosticsConfigurationTypeKey = @"ConfigType";
NSString *const kFIRAppDiagnosticsErrorKey = @"Error";
NSString *const kFIRAppDiagnosticsFIRAppKey = @"FIRApp";
NSString *const kFIRAppDiagnosticsSDKNameKey = @"SDKName";
NSString *const kFIRAppDiagnosticsSDKVersionKey = @"SDKVersion";
NSString *const kFIRAppDiagnosticsApplePlatformPrefix = @"apple-platform";

// Auth internal notification notification and key.
NSString *const FIRAuthStateDidChangeInternalNotification =
    @"FIRAuthStateDidChangeInternalNotification";
NSString *const FIRAuthStateDidChangeInternalNotificationAppKey =
    @"FIRAuthStateDidChangeInternalNotificationAppKey";
NSString *const FIRAuthStateDidChangeInternalNotificationTokenKey =
    @"FIRAuthStateDidChangeInternalNotificationTokenKey";
NSString *const FIRAuthStateDidChangeInternalNotificationUIDKey =
    @"FIRAuthStateDidChangeInternalNotificationUIDKey";

/**
 * Error domain for exceptions and NSError construction.
 */
NSString *const kFirebaseCoreErrorDomain = @"com.firebase.core";

/**
 * The URL to download plist files.
 */
static NSString *const kPlistURL = @"https://console.firebase.google.com/";

@interface FIRApp ()

#ifdef DEBUG
@property(nonatomic) BOOL alreadyOutputDataCollectionFlag;
#endif  // DEBUG

@end

@implementation FIRApp

// This is necessary since our custom getter prevents `_options` from being created.
@synthesize options = _options;

static NSMutableDictionary *sAllApps;
static FIRApp *sDefaultApp;

+ (void)configure {
  FIROptions *options = [FIROptions defaultOptions];
  if (!options) {
#if DEBUG
    [self findMisnamedGoogleServiceInfoPlist];
#endif  // DEBUG
    [NSException raise:kFirebaseCoreErrorDomain
                format:@"`FirebaseApp.configure()` could not find "
                       @"a valid GoogleService-Info.plist in your project. Please download one "
                       @"from %@.",
                       kPlistURL];
  }
  [FIRApp configureWithOptions:options];
}

+ (void)configureWithOptions:(FIROptions *)options {
  if (!options) {
    [NSException raise:kFirebaseCoreErrorDomain
                format:@"Options is nil. Please pass a valid options."];
  }
  [FIRApp configureWithName:kFIRDefaultAppName options:options];
}

+ (NSCharacterSet *)applicationNameAllowedCharacters {
  static NSCharacterSet *applicationNameAllowedCharacters;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSMutableCharacterSet *allowedNameCharacters = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowedNameCharacters addCharactersInString:@"-_"];
    applicationNameAllowedCharacters = [allowedNameCharacters copy];
  });
  return applicationNameAllowedCharacters;
}

+ (void)configureWithName:(NSString *)name options:(FIROptions *)options {
  if (!name || !options) {
    [NSException raise:kFirebaseCoreErrorDomain format:@"Neither name nor options can be nil."];
  }
  if (name.length == 0) {
    [NSException raise:kFirebaseCoreErrorDomain format:@"Name cannot be empty."];
  }

  if ([name isEqualToString:kFIRDefaultAppName]) {
    if (sDefaultApp) {
      // The default app already exists. Handle duplicate `configure` calls and return.
      [self appWasConfiguredTwice:sDefaultApp usingOptions:options];
      return;
    }

    FIRLogDebug(kFIRLoggerCore, @"I-COR000001", @"Configuring the default app.");
  } else {
    // Validate the app name and ensure it hasn't been configured already.
    NSCharacterSet *nameCharacters = [NSCharacterSet characterSetWithCharactersInString:name];

    if (![[self applicationNameAllowedCharacters] isSupersetOfSet:nameCharacters]) {
      [NSException raise:kFirebaseCoreErrorDomain
                  format:@"App name can only contain alphanumeric, "
                         @"hyphen (-), and underscore (_) characters"];
    }

    @synchronized(self) {
      if (sAllApps && sAllApps[name]) {
        // The app already exists. Handle a duplicate `configure` call and return.
        [self appWasConfiguredTwice:sAllApps[name] usingOptions:options];
        return;
      }
    }

    FIRLogDebug(kFIRLoggerCore, @"I-COR000002", @"Configuring app named %@", name);
  }

  // Default instantiation, make sure we populate with Swift SDKs that can't register in time.
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    [self registerSwiftComponents];
  });

  @synchronized(self) {
    FIRApp *app = [[FIRApp alloc] initInstanceWithName:name options:options];
    if (app.isDefaultApp) {
      sDefaultApp = app;
    }

    [FIRApp addAppToAppDictionary:app];

    // The FIRApp instance is ready to go, `sDefaultApp` is assigned, other SDKs are now ready to be
    // instantiated.
    [app.container instantiateEagerComponents];
    [FIRApp sendNotificationsToSDKs:app];
  }
}

/// Called when `configure` has been called multiple times for the same app. This can either throw
/// an exception (most cases) or ignore the duplicate configuration in situations where it's allowed
/// like an extension.
+ (void)appWasConfiguredTwice:(FIRApp *)app usingOptions:(FIROptions *)options {
  // Only extensions should potentially be able to call `configure` more than once.
  if (![GULAppEnvironmentUtil isAppExtension]) {
    // Throw an exception since this is now an invalid state.
    if (app.isDefaultApp) {
      [NSException raise:kFirebaseCoreErrorDomain
                  format:@"Default app has already been configured."];
    } else {
      [NSException raise:kFirebaseCoreErrorDomain
                  format:@"App named %@ has already been configured.", app.name];
    }
  }

  // In an extension, the entry point could be called multiple times. As long as the options are
  // identical we should allow multiple `configure` calls.
  if ([options isEqual:app.options]) {
    // Everything is identical but the extension's lifecycle triggered `configure` twice.
    // Ignore duplicate calls and return since everything should still be in a valid state.
    FIRLogDebug(kFIRLoggerCore, @"I-COR000035",
                @"Ignoring second `configure` call in an extension.");
    return;
  } else {
    [NSException raise:kFirebaseCoreErrorDomain
                format:@"App named %@ has already been configured.", app.name];
  }
}

+ (FIRApp *)defaultApp {
  if (sDefaultApp) {
    return sDefaultApp;
  }
  FIRLogError(kFIRLoggerCore, @"I-COR000003",
              @"The default Firebase app has not yet been "
              @"configured. Add `FirebaseApp.configure()` to your "
              @"application initialization. This can be done in "
              @"in the App Delegate's application(_:didFinishLaunchingWithOptions:)` "
              @"(or the `@main` struct's initializer in SwiftUI). "
              @"Read more: "
              @"https://firebase.google.com/docs/ios/setup#initialize_firebase_in_your_app");
  return nil;
}

+ (FIRApp *)appNamed:(NSString *)name {
  @synchronized(self) {
    if (sAllApps) {
      FIRApp *app = sAllApps[name];
      if (app) {
        return app;
      }
    }
    FIRLogError(kFIRLoggerCore, @"I-COR000004", @"App with name %@ does not exist.", name);
    return nil;
  }
}

+ (NSDictionary *)allApps {
  @synchronized(self) {
    if (!sAllApps) {
      FIRLogError(kFIRLoggerCore, @"I-COR000005", @"No app has been configured yet.");
    }
    return [sAllApps copy];
  }
}

// Public only for tests
+ (void)resetApps {
  @synchronized(self) {
    sDefaultApp = nil;
    [sAllApps removeAllObjects];
    sAllApps = nil;
    [[self userAgent] reset];
  }
}

- (void)deleteApp:(FIRAppVoidBoolCallback)completion {
  @synchronized([self class]) {
    if (sAllApps && sAllApps[self.name]) {
      FIRLogDebug(kFIRLoggerCore, @"I-COR000006", @"Deleting app named %@", self.name);

      // Remove all registered libraries from the container to avoid creating new instances.
      [self.container removeAllComponents];
      // Remove all cached instances from the container before deleting the app.
      [self.container removeAllCachedInstances];

      [sAllApps removeObjectForKey:self.name];
      [self clearDataCollectionSwitchFromUserDefaults];
      if ([self.name isEqualToString:kFIRDefaultAppName]) {
        sDefaultApp = nil;
      }
      NSDictionary *appInfoDict = @{kFIRAppNameKey : self.name};
      [[NSNotificationCenter defaultCenter] postNotificationName:kFIRAppDeleteNotification
                                                          object:[self class]
                                                        userInfo:appInfoDict];
      completion(YES);
    } else {
      FIRLogError(kFIRLoggerCore, @"I-COR000007", @"App does not exist.");
      completion(NO);
    }
  }
}

+ (void)addAppToAppDictionary:(FIRApp *)app {
  if (!sAllApps) {
    sAllApps = [NSMutableDictionary dictionary];
  }
  if ([app configureCore]) {
    sAllApps[app.name] = app;
  } else {
    [NSException raise:kFirebaseCoreErrorDomain
                format:@"Configuration fails. It may be caused by an invalid GOOGLE_APP_ID in "
                       @"GoogleService-Info.plist or set in the customized options."];
  }
}

- (instancetype)initInstanceWithName:(NSString *)name options:(FIROptions *)options {
  self = [super init];
  if (self) {
    _name = [name copy];
    _options = [options copy];
    _options.editingLocked = YES;
    _isDefaultApp = [name isEqualToString:kFIRDefaultAppName];
    _container = [[FIRComponentContainer alloc] initWithApp:self];
    _heartbeatLogger = [[FIRHeartbeatLogger alloc] initWithAppID:self.options.googleAppID];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)configureCore {
  [self checkExpectedBundleID];
  if (![self isAppIDValid]) {
    return NO;
  }

  // Initialize the Analytics once there is a valid options under default app. Analytics should
  // always initialize first by itself before the other SDKs.
  if ([self.name isEqualToString:kFIRDefaultAppName]) {
    Class firAnalyticsClass = NSClassFromString(@"FIRAnalytics");
    if (firAnalyticsClass) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
      SEL startWithConfigurationSelector = @selector(startWithConfiguration:options:);
#pragma clang diagnostic pop
      if ([firAnalyticsClass respondsToSelector:startWithConfigurationSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [firAnalyticsClass performSelector:startWithConfigurationSelector
                                withObject:[FIRConfiguration sharedInstance].analyticsConfiguration
                                withObject:_options];
#pragma clang diagnostic pop
      }
    }
  }

  [self subscribeForAppDidBecomeActiveNotifications];

  return YES;
}

- (FIROptions *)options {
  return [_options copy];
}

- (void)setDataCollectionDefaultEnabled:(BOOL)dataCollectionDefaultEnabled {
#ifdef DEBUG
  FIRLogDebug(kFIRLoggerCore, @"I-COR000034", @"Explicitly %@ data collection flag.",
              dataCollectionDefaultEnabled ? @"enabled" : @"disabled");
  self.alreadyOutputDataCollectionFlag = YES;
#endif  // DEBUG

  NSString *key =
      [NSString stringWithFormat:kFIRGlobalAppDataCollectionEnabledDefaultsKeyFormat, self.name];
  [[NSUserDefaults standardUserDefaults] setBool:dataCollectionDefaultEnabled forKey:key];

  // Core also controls the FirebaseAnalytics flag, so check if the Analytics flags are set
  // within FIROptions and change the Analytics value if necessary. Analytics only works with the
  // default app, so return if this isn't the default app.
  if (!self.isDefaultApp) {
    return;
  }

  // Check if the Analytics flag is explicitly set. If so, no further actions are necessary.
  if ([self.options isAnalyticsCollectionExplicitlySet]) {
    return;
  }

  // The Analytics flag has not been explicitly set, so update with the value being set.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  [[FIRAnalyticsConfiguration sharedInstance]
      setAnalyticsCollectionEnabled:dataCollectionDefaultEnabled
                     persistSetting:NO];
#pragma clang diagnostic pop
}

- (BOOL)isDataCollectionDefaultEnabled {
  // Check if it's been manually set before in code, and use that as the higher priority value.
  NSNumber *defaultsObject = [[self class] readDataCollectionSwitchFromUserDefaultsForApp:self];
  if (defaultsObject != nil) {
#ifdef DEBUG
    if (!self.alreadyOutputDataCollectionFlag) {
      FIRLogDebug(kFIRLoggerCore, @"I-COR000031", @"Data Collection flag is %@ in user defaults.",
                  [defaultsObject boolValue] ? @"enabled" : @"disabled");
      self.alreadyOutputDataCollectionFlag = YES;
    }
#endif  // DEBUG
    return [defaultsObject boolValue];
  }

  // Read the Info.plist to see if the flag is set. If it's not set, it should default to `YES`.
  // As per the implementation of `readDataCollectionSwitchFromPlist`, it's a cached value and has
  // no performance impact calling multiple times.
  NSNumber *collectionEnabledPlistValue = [[self class] readDataCollectionSwitchFromPlist];
  if (collectionEnabledPlistValue != nil) {
#ifdef DEBUG
    if (!self.alreadyOutputDataCollectionFlag) {
      FIRLogDebug(kFIRLoggerCore, @"I-COR000032", @"Data Collection flag is %@ in plist.",
                  [collectionEnabledPlistValue boolValue] ? @"enabled" : @"disabled");
      self.alreadyOutputDataCollectionFlag = YES;
    }
#endif  // DEBUG
    return [collectionEnabledPlistValue boolValue];
  }

#ifdef DEBUG
  if (!self.alreadyOutputDataCollectionFlag) {
    FIRLogDebug(kFIRLoggerCore, @"I-COR000033", @"Data Collection flag is not set.");
    self.alreadyOutputDataCollectionFlag = YES;
  }
#endif  // DEBUG
  return YES;
}

#pragma mark - private

+ (void)sendNotificationsToSDKs:(FIRApp *)app {
  // TODO: Remove this notification once all SDKs are registered with `FIRCoreConfigurable`.
  NSNumber *isDefaultApp = [NSNumber numberWithBool:app.isDefaultApp];
  NSDictionary *appInfoDict = @{
    kFIRAppNameKey : app.name,
    kFIRAppIsDefaultAppKey : isDefaultApp,
    kFIRGoogleAppIDKey : app.options.googleAppID
  };
  [[NSNotificationCenter defaultCenter] postNotificationName:kFIRAppReadyToConfigureSDKNotification
                                                      object:self
                                                    userInfo:appInfoDict];
}

+ (BOOL)isDefaultAppConfigured {
  return (sDefaultApp != nil);
}

+ (void)registerLibrary:(nonnull NSString *)name withVersion:(nonnull NSString *)version {
  // Create the set of characters which aren't allowed, only if this feature is used.
  NSMutableCharacterSet *allowedSet = [NSMutableCharacterSet alphanumericCharacterSet];
  [allowedSet addCharactersInString:@"-_."];
  NSCharacterSet *disallowedSet = [allowedSet invertedSet];
  // Make sure the library name and version strings do not contain unexpected characters, and
  // add the name/version pair to the dictionary.
  if ([name rangeOfCharacterFromSet:disallowedSet].location == NSNotFound &&
      [version rangeOfCharacterFromSet:disallowedSet].location == NSNotFound) {
    [[self userAgent] setValue:version forComponent:name];
  } else {
    FIRLogError(kFIRLoggerCore, @"I-COR000027",
                @"The library name (%@) or version number (%@) contain invalid characters. "
                @"Only alphanumeric, dash, underscore and period characters are allowed.",
                name, version);
  }
}

+ (void)registerInternalLibrary:(nonnull Class<FIRLibrary>)library
                       withName:(nonnull NSString *)name {
  [self registerInternalLibrary:library withName:name withVersion:FIRFirebaseVersion()];
}

+ (void)registerInternalLibrary:(nonnull Class<FIRLibrary>)library
                       withName:(nonnull NSString *)name
                    withVersion:(nonnull NSString *)version {
  // This is called at +load time, keep the work to a minimum.

  // Ensure the class given conforms to the proper protocol.
  if (![(Class)library conformsToProtocol:@protocol(FIRLibrary)] ||
      ![(Class)library respondsToSelector:@selector(componentsToRegister)]) {
    [NSException raise:NSInvalidArgumentException
                format:@"Class %@ attempted to register components, but it does not conform to "
                       @"`FIRLibrary or provide a `componentsToRegister:` method.",
                       library];
  }

  [FIRComponentContainer registerAsComponentRegistrant:library];
  [self registerLibrary:name withVersion:version];
}

+ (FIRFirebaseUserAgent *)userAgent {
  static dispatch_once_t onceToken;
  static FIRFirebaseUserAgent *_userAgent;
  dispatch_once(&onceToken, ^{
    _userAgent = [[FIRFirebaseUserAgent alloc] init];
    [_userAgent setValue:FIRFirebaseVersion() forComponent:@"fire-ios"];
  });
  return _userAgent;
}

+ (NSString *)firebaseUserAgent {
  return [[self userAgent] firebaseUserAgent];
}

- (void)checkExpectedBundleID {
  NSArray *bundles = [FIRBundleUtil relevantBundles];
  NSString *expectedBundleID = [self expectedBundleID];
  // The checking is only done when the bundle ID is provided in the serviceInfo dictionary for
  // backward compatibility.
  if (expectedBundleID != nil && ![FIRBundleUtil hasBundleIdentifierPrefix:expectedBundleID
                                                                 inBundles:bundles]) {
    FIRLogError(kFIRLoggerCore, @"I-COR000008",
                @"The project's Bundle ID is inconsistent with "
                @"either the Bundle ID in '%@.%@', or the Bundle ID in the options if you are "
                @"using a customized options. To ensure that everything can be configured "
                @"correctly, you may need to make the Bundle IDs consistent. To continue with this "
                @"plist file, you may change your app's bundle identifier to '%@'. Or you can "
                @"download a new configuration file that matches your bundle identifier from %@ "
                @"and replace the current one.",
                kServiceInfoFileName, kServiceInfoFileType, expectedBundleID, kPlistURL);
  }
}

#pragma mark - private - App ID Validation

/**
 * Validates the format of app ID and its included bundle ID hash contained in GOOGLE_APP_ID in the
 * plist file. This is the main method for validating app ID.
 *
 * @return YES if the app ID fulfills the expected format and contains a hashed bundle ID, NO
 * otherwise.
 */
- (BOOL)isAppIDValid {
  NSString *appID = _options.googleAppID;
  BOOL isValid = [FIRApp validateAppID:appID];
  if (!isValid) {
    NSString *expectedBundleID = [self expectedBundleID];
    FIRLogError(kFIRLoggerCore, @"I-COR000009",
                @"The GOOGLE_APP_ID either in the plist file "
                @"'%@.%@' or the one set in the customized options is invalid. If you are using "
                @"the plist file, use the iOS version of bundle identifier to download the file, "
                @"and do not manually edit the GOOGLE_APP_ID. You may change your app's bundle "
                @"identifier to '%@'. Or you can download a new configuration file that matches "
                @"your bundle identifier from %@ and replace the current one.",
                kServiceInfoFileName, kServiceInfoFileType, expectedBundleID, kPlistURL);
  };
  return isValid;
}

+ (BOOL)validateAppID:(NSString *)appID {
  // Failing validation only occurs when we are sure we are looking at a V2 app ID and it does not
  // have a valid hashed bundle ID, otherwise we just warn about the potential issue.
  if (!appID.length) {
    return NO;
  }

  NSScanner *stringScanner = [NSScanner scannerWithString:appID];
  stringScanner.charactersToBeSkipped = nil;

  NSString *appIDVersion;
  if (![stringScanner scanCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet]
                                 intoString:&appIDVersion]) {
    return NO;
  }

  if (![stringScanner scanString:@":" intoString:NULL]) {
    // appIDVersion must be separated by ":"
    return NO;
  }

  NSArray *knownVersions = @[ @"1" ];
  if (![knownVersions containsObject:appIDVersion]) {
    // Permit unknown yet properly formatted app ID versions.
    FIRLogInfo(kFIRLoggerCore, @"I-COR000010", @"Unknown GOOGLE_APP_ID version: %@", appIDVersion);
    return YES;
  }

  if (![self validateAppIDFormat:appID withVersion:appIDVersion]) {
    return NO;
  }

  if (![self validateBundleIDHashWithinAppID:appID forVersion:appIDVersion]) {
    return NO;
  }

  return YES;
}

+ (NSString *)actualBundleID {
  return [[NSBundle mainBundle] bundleIdentifier];
}

/**
 * Validates that the format of the app ID string is what is expected based on the supplied version.
 * The version must end in ":".
 *
 * For v1 app ids the format is expected to be
 * '<version #>:<project number>:ios:<hashed bundle id>'.
 *
 * This method does not verify that the contents of the app id are correct, just that they fulfill
 * the expected format.
 *
 * @param appID Contents of GOOGLE_APP_ID from the plist file.
 * @param version Indicates what version of the app id format this string should be.
 * @return YES if provided string fulfills the expected format, NO otherwise.
 */
+ (BOOL)validateAppIDFormat:(NSString *)appID withVersion:(NSString *)version {
  if (!appID.length || !version.length) {
    return NO;
  }

  NSScanner *stringScanner = [NSScanner scannerWithString:appID];
  stringScanner.charactersToBeSkipped = nil;

  // Skip version part
  // '*<version #>*:<project number>:ios:<hashed bundle id>'
  if (![stringScanner scanString:version intoString:NULL]) {
    // The version part is missing or mismatched
    return NO;
  }

  // Validate version part (see part between '*' symbols below)
  // '<version #>*:*<project number>:ios:<hashed bundle id>'
  if (![stringScanner scanString:@":" intoString:NULL]) {
    // appIDVersion must be separated by ":"
    return NO;
  }

  // Validate version part (see part between '*' symbols below)
  // '<version #>:*<project number>*:ios:<hashed bundle id>'.
  NSInteger projectNumber = NSNotFound;
  if (![stringScanner scanInteger:&projectNumber]) {
    // NO project number found.
    return NO;
  }

  // Validate version part (see part between '*' symbols below)
  // '<version #>:<project number>*:*ios:<hashed bundle id>'.
  if (![stringScanner scanString:@":" intoString:NULL]) {
    // The project number must be separated by ":"
    return NO;
  }

  // Validate version part (see part between '*' symbols below)
  // '<version #>:<project number>:*ios*:<hashed bundle id>'.
  NSString *platform;
  if (![stringScanner scanUpToString:@":" intoString:&platform]) {
    return NO;
  }

  if (![platform isEqualToString:@"ios"]) {
    // The platform must be @"ios"
    return NO;
  }

  // Validate version part (see part between '*' symbols below)
  // '<version #>:<project number>:ios*:*<hashed bundle id>'.
  if (![stringScanner scanString:@":" intoString:NULL]) {
    // The platform must be separated by ":"
    return NO;
  }

  // Validate version part (see part between '*' symbols below)
  // '<version #>:<project number>:ios:*<hashed bundle id>*'.
  unsigned long long bundleIDHash = NSNotFound;
  if (![stringScanner scanHexLongLong:&bundleIDHash]) {
    // Hashed bundleID part is missing
    return NO;
  }

  if (!stringScanner.isAtEnd) {
    // There are not allowed characters in the hashed bundle ID part
    return NO;
  }

  return YES;
}

/**
 * Validates that the hashed bundle ID included in the app ID string is what is expected based on
 * the supplied version.
 *
 * Note that the v1 hash algorithm is not permitted on the client and cannot be fully validated.
 *
 * @param appID Contents of GOOGLE_APP_ID from the plist file.
 * @param version Indicates what version of the app id format this string should be.
 * @return YES if provided string fulfills the expected hashed bundle ID and the version is known,
 *         NO otherwise.
 */
+ (BOOL)validateBundleIDHashWithinAppID:(NSString *)appID forVersion:(NSString *)version {
  // Extract the hashed bundle ID from the given app ID.
  // This assumes the app ID format is the same for all known versions below.
  // If the app ID format changes in future versions, the tokenizing of the app
  // ID format will need to take into account the version of the app ID.
  NSArray *components = [appID componentsSeparatedByString:@":"];
  if (components.count != 4) {
    return NO;
  }

  NSString *suppliedBundleIDHashString = components[3];
  if (!suppliedBundleIDHashString.length) {
    return NO;
  }

  uint64_t suppliedBundleIDHash;
  NSScanner *scanner = [NSScanner scannerWithString:suppliedBundleIDHashString];
  if (![scanner scanHexLongLong:&suppliedBundleIDHash]) {
    return NO;
  }

  if ([version isEqual:@"1"]) {
    // The v1 hash algorithm is not permitted on the client so the actual hash cannot be validated.
    return YES;
  }

  // Unknown version.
  return NO;
}

- (NSString *)expectedBundleID {
  return _options.bundleID;
}

// end App ID validation

#pragma mark - Reading From Plist & User Defaults

/**
 * Clears the data collection switch from the standard NSUserDefaults for easier testing and
 * readability.
 */
- (void)clearDataCollectionSwitchFromUserDefaults {
  NSString *key =
      [NSString stringWithFormat:kFIRGlobalAppDataCollectionEnabledDefaultsKeyFormat, self.name];
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
}

/**
 * Reads the data collection switch from the standard NSUserDefaults for easier testing and
 * readability.
 */
+ (nullable NSNumber *)readDataCollectionSwitchFromUserDefaultsForApp:(FIRApp *)app {
  // Read the object in user defaults, and only return if it's an NSNumber.
  NSString *key =
      [NSString stringWithFormat:kFIRGlobalAppDataCollectionEnabledDefaultsKeyFormat, app.name];
  id collectionEnabledDefaultsObject = [[NSUserDefaults standardUserDefaults] objectForKey:key];
  if ([collectionEnabledDefaultsObject isKindOfClass:[NSNumber class]]) {
    return collectionEnabledDefaultsObject;
  }

  return nil;
}

/**
 * Reads the data collection switch from the Info.plist for easier testing and readability. Will
 * only read once from the plist and return the cached value.
 */
+ (nullable NSNumber *)readDataCollectionSwitchFromPlist {
  static NSNumber *collectionEnabledPlistObject;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // Read the data from the `Info.plist`, only assign it if it's there and an NSNumber.
    id plistValue = [[NSBundle mainBundle]
        objectForInfoDictionaryKey:kFIRGlobalAppDataCollectionEnabledPlistKey];
    if (plistValue && [plistValue isKindOfClass:[NSNumber class]]) {
      collectionEnabledPlistObject = (NSNumber *)plistValue;
    }
  });

  return collectionEnabledPlistObject;
}

#pragma mark - Swift Components.

+ (void)registerSwiftComponents {
  SEL componentsToRegisterSEL = @selector(componentsToRegister);
  // Dictionary of class names that conform to `FIRLibrary` and their user agents. These should only
  // be SDKs that are written in Swift but still visible to ObjC.
  // This is only necessary for products that need to do work at launch during configuration.
  NSDictionary<NSString *, NSString *> *swiftComponents = @{
    @"FIRSessions" : @"fire-ses",
    @"FIRAuthComponent" : @"fire-auth",
  };
  for (NSString *className in swiftComponents.allKeys) {
    Class klass = NSClassFromString(className);
    if (klass && [klass respondsToSelector:componentsToRegisterSEL]) {
      [FIRApp registerInternalLibrary:klass withName:swiftComponents[className]];
    }
  }

  // Swift libraries that don't need component behaviour
  NSDictionary<NSString *, NSString *> *swiftLibraries = @{
    @"FIRCombineAuthLibrary" : @"comb-auth",
    @"FIRCombineFirestoreLibrary" : @"comb-firestore",
    @"FIRCombineFunctionsLibrary" : @"comb-functions",
    @"FIRCombineStorageLibrary" : @"comb-storage",
    @"FIRFunctions" : @"fire-fun",
    @"FIRStorage" : @"fire-str",
    @"FIRVertexAIComponent" : @"fire-vertex",
    @"FIRDataConnectComponent" : @"fire-dc",
  };
  for (NSString *className in swiftLibraries.allKeys) {
    Class klass = NSClassFromString(className);
    if (klass) {
      NSString *version = FIRFirebaseVersion();
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
      SEL sdkVersionSelector = @selector(sdkVersion);
#pragma clang diagnostic pop
      if ([klass respondsToSelector:sdkVersionSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSString *sdkVersion = (NSString *)[klass performSelector:sdkVersionSelector];
        if (sdkVersion) version = sdkVersion;
#pragma clang diagnostic pop
      }
      [FIRApp registerLibrary:swiftLibraries[className] withVersion:version];
    }
  }
}

#pragma mark - App Life Cycle

- (void)subscribeForAppDidBecomeActiveNotifications {
#if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_VISION
  NSNotificationName notificationName = UIApplicationDidBecomeActiveNotification;
#elif TARGET_OS_OSX
  NSNotificationName notificationName = NSApplicationDidBecomeActiveNotification;
#elif TARGET_OS_WATCH
  // TODO(ncooke3): Remove when minimum supported watchOS version is watchOS 7.0.
  // On watchOS 7.0+, heartbeats are logged when the watch app becomes active.
  // On watchOS 6.0, heartbeats are logged when the Firebase app is configuring.
  // While it does not cover all use cases, logging when the Firebase app is
  // configuring is done because watchOS lifecycle notifications are a
  // watchOS 7.0+ feature.
  NSNotificationName notificationName = kFIRAppReadyToConfigureSDKNotification;
  if (@available(watchOS 7.0, *)) {
    notificationName = WKApplicationDidBecomeActiveNotification;
  }
#endif

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(appDidBecomeActive:)
                                               name:notificationName
                                             object:nil];
}

- (void)appDidBecomeActive:(NSNotification *)notification {
  if ([self isDataCollectionDefaultEnabled]) {
    // If changing the below line, consult with the Games team to ensure they
    // are not negatively impacted. For more details, see
    // go/firebase-game-sdk-user-agent-register-timing.
    [self.heartbeatLogger log];
  }
}

#if DEBUG
+ (void)findMisnamedGoogleServiceInfoPlist {
  for (NSBundle *bundle in [NSBundle allBundles]) {
    // Not recursive, but we're looking for misnames, not people accidentally
    // hiding their config file in a subdirectory of their bundle.
    NSArray *plistPaths = [bundle pathsForResourcesOfType:@"plist" inDirectory:nil];
    for (NSString *path in plistPaths) {
      @autoreleasepool {
        NSDictionary<NSString *, id> *contents = [NSDictionary dictionaryWithContentsOfFile:path];
        if (contents == nil) {
          continue;
        }

        NSString *projectID = contents[@"PROJECT_ID"];
        if (projectID != nil) {
          [NSException raise:kFirebaseCoreErrorDomain
                      format:@"`FirebaseApp.configure()` could not find the default "
                             @"configuration plist in your project, but did find one at "
                             @"%@. Please rename this file to GoogleService-Info.plist to "
                             @"use it as the default configuration.",
                             path];
        }
      }
    }
  }
}
#endif  // DEBUG

@end
