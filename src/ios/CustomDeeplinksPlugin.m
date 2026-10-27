#import "CustomDeeplinksPlugin.h"
#import "AppDelegate+CustomDeeplinksPlugin.h"
#import <objc/runtime.h>

@implementation CustomDeeplinksPlugin

static NSString *pendingURL = nil;

static void notifyAppsFlyer(NSUserActivity *userActivity) {
    id appDelegate = [UIApplication sharedApplication].delegate;
    if ([appDelegate respondsToSelector:@selector(notifyAppsFlyerWithUserActivity:restorationHandler:)]) {
        [appDelegate notifyAppsFlyerWithUserActivity:userActivity restorationHandler:nil];
    }
}

// Scene-based app lifecycle (cordova-ios 7+): on cold start the Universal Link only arrives in
// connectionOptions.userActivities, which CDVSceneDelegate ignores. Hook its
// -scene:willConnectToSession:options: to keep the URL until JS asks for it via getPendingDeeplink.
static void (*originalWillConnect)(id, SEL, UIScene *, UISceneSession *, UISceneConnectionOptions *) = NULL;

static void customWillConnect(id self, SEL _cmd, UIScene *scene, UISceneSession *session, UISceneConnectionOptions *options) {
    for (NSUserActivity *activity in options.userActivities) {
        if ([activity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] && activity.webpageURL != nil) {
            pendingURL = activity.webpageURL.absoluteString;
            NSLog(@"[CustomDeeplinks] Cold start universal link: %@", pendingURL);
            notifyAppsFlyer(activity);
        }
    }

    if (originalWillConnect != NULL) {
        originalWillConnect(self, _cmd, scene, session, options);
    }
}

+ (void)load {
    Class sceneDelegateClass = NSClassFromString(@"CDVSceneDelegate");
    if (sceneDelegateClass == nil) return;

    Method method = class_getInstanceMethod(sceneDelegateClass, @selector(scene:willConnectToSession:options:));
    if (method == NULL) return;

    originalWillConnect = (void *)method_setImplementation(method, (IMP)customWillConnect);
}

- (NSString *)safeJsonString:(NSString *)input {
    if (input == nil) return @"\"\"";
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[input] options:0 error:&error];
    if (!jsonData) {
        return @"\"\"";
    }
    NSString *jsonArrayString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (jsonArrayString.length >= 2) {
        return [jsonArrayString substringWithRange:NSMakeRange(1, jsonArrayString.length - 2)];
    }
    return @"\"\"";
}

- (void)pluginInitialize {
    // Plugin is loaded on startup (onload=true), before the page - a pending URL is picked up
    // by JS via getPendingDeeplink, so it must not be consumed here.

    // Warm start under the Scene-based lifecycle: CDVSceneDelegate posts this instead of
    // AppDelegate's -application:continueUserActivity: being called.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onContinueUserActivity:)
                                                 name:CDVPluginContinueUserActivityNotification
                                               object:nil];
}

- (void)onContinueUserActivity:(NSNotification *)notification {
    NSUserActivity *userActivity = notification.object;
    if (![userActivity isKindOfClass:[NSUserActivity class]]) return;
    if (![userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb]) return;

    notifyAppsFlyer(userActivity);
    [self handleUserActivity:userActivity];
}

- (BOOL)handleUserActivity:(NSUserActivity *)userActivity {
    if (userActivity.webpageURL == nil) return NO;

    NSString *urlString = userActivity.webpageURL.absoluteString;
    NSLog(@"[CustomDeeplinks] Handling universal link: %@", urlString);

    pendingURL = urlString;

    if (self.webViewEngine && self.webViewEngine.engineWebView) {
        NSString *safeURLJson = [self safeJsonString:urlString];
        NSString *js = [NSString stringWithFormat:@"window.CustomDeeplinks && window.CustomDeeplinks.onDeepLink && window.CustomDeeplinks.onDeepLink(%@);", safeURLJson];
        [self.commandDelegate evalJs:js];
        NSLog(@"[CustomDeeplinks] Fire universal link immediately: %@", urlString);
    }

    return YES;
}


- (void)getPendingDeeplink:(CDVInvokedUrlCommand *)command {
    if (pendingURL != nil) {
        NSLog(@"[CustomDeeplinks] Returning pending URL: %@", pendingURL);
        
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:pendingURL];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];

        pendingURL = nil;
    } else {
        NSLog(@"[CustomDeeplinks] No pending URL");
        
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }
}

- (void)clearPendingDeeplink:(CDVInvokedUrlCommand *)command {
    NSLog(@"[CustomDeeplinks] Clearing pending URL via JS acknowledgment");
    pendingURL = nil;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@end
