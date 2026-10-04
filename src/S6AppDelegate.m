#import "S6AppDelegate.h"
#import "S6RootViewController.h"
#import "S6SearchViewController.h"
#import "S6NowPlayingViewController.h"
#import "S6Router.h"
#import "S6Session.h"
#import "S6Tokens.h"
#import "S6Pathfinder.h"
#import "S6Catalog.h"
#import "S6SpClient.h"
#import "S6Zeroconf.h"
#import "S6Connect.h"
#import "S6Models.h"
#import "S6Player.h"
#import "S6TLSSocket.h"
#import "S6ImageLoader.h"
#import "S6Settings.h"
#import "S6Theme.h"
#import "S6Utils.h"
#import "S6Common.h"
#import <AVFoundation/AVFoundation.h>
#include <dlfcn.h>
#include <signal.h>
#include <mach/mach.h>

static BOOL S6ButtonMatches(UIButton *button, NSString *text)
{
    for (NSString *name in @[ button.currentTitle ?: @"", button.accessibilityLabel ?: @"" ])
        if (name.length && [name rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static BOOL S6ViewContainsText(UIView *view, NSString *text)
{
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *s = ((UILabel *)view).text;
        return s.length && [s rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound;
    }
    for (UIView *sub in view.subviews) { if ([sub isKindOfClass:[UIControl class]]) continue; if (S6ViewContainsText(sub, text)) return YES; }
    return NO;
}

static BOOL S6PressView(UIView *v, NSString *text)
{
    if ([v isKindOfClass:[UIButton class]]) {
        if (!S6ButtonMatches((UIButton *)v, text)) return NO;
        [(UIButton *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    if ([v isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *cell = (UITableViewCell *)v;
        if (!S6ViewContainsText(cell, text)) return NO;
        UIView *table = cell.superview;
        while (table && ![table isKindOfClass:[UITableView class]]) table = table.superview;
        NSIndexPath *ip = [(UITableView *)table indexPathForCell:cell];
        id<UITableViewDelegate> delegate = [(UITableView *)table delegate];
        if (!ip || ![delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
        [delegate tableView:(UITableView *)table didSelectRowAtIndexPath:ip];
        return YES;
    }
    // (a control without a label must not match: a message to nil answers location 0)
    if ([v isKindOfClass:[UIControl class]] && v.accessibilityLabel.length &&
        [v.accessibilityLabel rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    return NO;
}

@implementation S6AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    signal(SIGPIPE, SIG_IGN);
    [S6Settings registerDefaults];
    S6Log(@"Spot6 %@ starting on %@ (iOS %@)", [S6Utils appVersion], [S6Utils deviceModel], [UIDevice currentDevice].systemVersion);
    [S6TLSSocket warmUp];
    [[S6ImageLoader shared] pruneDisk];
    [[S6Theme shared] applyGlobalAppearance];

    // music goes on with the screen locked and the silent switch on
    NSError *audioError = nil;
    if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&audioError]) S6Log(@"audio session: %@", audioError);
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];
    [application beginReceivingRemoteControlEvents];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[S6RootViewController alloc] init];
    self.window.backgroundColor = [UIColor blackColor];
    [self.window makeKeyAndVisible];
    [application setStatusBarStyle:UIStatusBarStyleBlackOpaque animated:NO];

    [S6Connect shared];   // (Spotify Connect starts by itself once the session is ready)
    [[S6Session shared] start];
    [[S6Zeroconf shared] start];
    return YES;
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event { [[S6Player shared] handleRemoteEvent:event]; }

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    [[S6Session shared] reconnectSoon];
    if (![S6Zeroconf shared].running) [[S6Zeroconf shared] start];
}

- (void)applicationDidEnterBackground:(UIApplication *)application { [S6Settings save]; }

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application { [[S6ImageLoader shared] clearMemory]; }

#pragma mark - Links

// spot6:open?uri=<spotify: URI or open.spotify.com link>, spot6:search?q=, and plain open.spotify.com links.
// Debug commands (need Documents/debug): stats, aptest, screen, snapshot, press?title=/n=, back, lang?set=en|cs|system,
// section?name=, play?uri=, player?cmd=pause|play|next|prev|seek&ms=|shuffle|repeat, nowplaying?panel=art|lyrics|queue,
// rotate?o=landscape|portrait
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    NSString *s = url.absoluteString ?: @"";
    NSString *lower = [s lowercaseString];
    S6RootViewController *root = [S6RootViewController shared];
    if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"] || [lower hasPrefix:@"spotify:"]) { [S6Router openURI:s]; return YES; }
    if (![lower hasPrefix:@"spot6:"]) return NO;
    NSString *target = [s substringFromIndex:@"spot6:".length];
    while ([target hasPrefix:@"/"]) target = [target substringFromIndex:1];
    NSString *query = nil;
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) { query = [target substringFromIndex:q.location + 1]; target = [target substringToIndex:q.location]; }
    NSDictionary *params = query.length ? [S6Utils parseQuery:query] : @{};
    if ([target isEqualToString:@"open"] && [params[@"uri"] length]) { [S6Router openURI:params[@"uri"]]; return YES; }
    if ([target isEqualToString:@"search"]) {
        [root showSection:S6SectionSearch];
        UIViewController *search = root.contentNavigationController.viewControllers.firstObject;
        if ([params[@"q"] length] && [search isKindOfClass:[S6SearchViewController class]]) [(S6SearchViewController *)search searchFor:params[@"q"]];
        return YES;
    }

    BOOL debug = [[NSFileManager defaultManager] fileExistsAtPath:[[S6Utils documentsPath] stringByAppendingPathComponent:@"debug"]];
    if (!debug) return YES;
    UIViewController *top = [root topController];
    if ([target isEqualToString:@"stats"]) {
        struct task_basic_info info; mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
            S6Log(@"Memory: %.1f MB resident", info.resident_size / 1048576.0);
        S6Zeroconf *zc = [S6Zeroconf shared];
        S6Log(@"Top: %@, section %ld", NSStringFromClass([top class]), (long)root.section);
        S6Log(@"Session: %@", [[S6Session shared] debugState]);
        S6Log(@"Tokens: %@", [[S6Tokens shared] debugState]);
        S6Log(@"Zeroconf: %@ on port %u, %@", zc.running ? @"running" : @"stopped", zc.port, zc.lastEvent ?: @"-");
        S6Log(@"Player: %@", [[S6Player shared] debugState]);
        S6Log(@"Connect: %@", [[S6Connect shared] debugState]);
        return YES;
    }
    // connect?cmd=pause|resume|skip_next|skip_prev|seek_to&value=|play&uri=<context>&index=N: a Spotify Connect command
    // sent to this device through Spotify, as the phone would
    if ([target isEqualToString:@"connect"]) {
        NSString *cmd = params[@"cmd"] ?: @"pause";
        NSMutableDictionary *command = [NSMutableDictionary dictionaryWithObject:cmd forKey:@"endpoint"];
        if (params[@"value"]) command[@"value"] = @([params[@"value"] longLongValue]);
        if ([cmd isEqualToString:@"play"] && [params[@"uri"] length]) {
            command[@"context"] = @{ @"uri": params[@"uri"], @"url": [@"context://" stringByAppendingString:params[@"uri"]] };
            command[@"options"] = @{ @"skip_to": @{ @"track_index": @([params[@"index"] integerValue]) } };
        }
        [[S6Connect shared] debugSendCommand:command];
        return YES;
    }
    if ([target isEqualToString:@"aptest"]) { [[S6Session shared] debugHandshakeTest]; return YES; }
    if ([target isEqualToString:@"tokentest"]) { [[S6Tokens shared] debugTokenTest]; return YES; }
    // gql?op=<operation>&vars=<JSON>[&hash=][&plat=]: one GraphQL query, the answer saved to tmp/gql-<op>.json
    if ([target isEqualToString:@"gql"]) {
        NSString *op = params[@"op"] ?: @"";
        NSString *hash = params[@"hash"] ?: [S6Pathfinder hashFor:op];
        NSString *varsText = params[@"vars"];
        id vars = varsText.length ? [S6Utils JSONObjectFromData:[varsText dataUsingEncoding:NSUTF8StringEncoding]] : @{};
        NSString *plat = params[@"plat"];
        if (!vars) { S6Log(@"gql %@: the variables are not JSON", op); return YES; }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSInteger status = 0;
            NSError *e = nil;
            NSData *data = [S6Pathfinder rawQuery:op hash:hash variables:vars platform:plat status:&status error:&e];
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"gql-%@.json", op]];
            [data ?: [NSData data] writeToFile:path atomically:YES];
            NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : e.localizedDescription;
            S6Log(@"gql %@: HTTP %ld, %lu bytes | %@", op, (long)status, (unsigned long)data.length, [S6Utils truncate:text ?: @"" to:200]);
        });
        return YES;
    }
    // sp?path=<spclient path>&out=<name>: one spclient GET, the answer saved to tmp/sp-<name>.json
    if ([target isEqualToString:@"sp"] && [params[@"path"] length]) {
        NSString *path = params[@"path"];
        NSString *name = params[@"out"] ?: @"out";
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSInteger status = 0;
            NSError *e = nil;
            NSData *data = [S6SpClient request:@"GET" path:path body:nil contentType:nil accept:@"application/json" status:&status error:&e];
            NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sp-%@.json", name]];
            [data ?: [NSData data] writeToFile:file atomically:YES];
            S6Log(@"sp %@: HTTP %ld, %lu bytes%@", path, (long)status, (unsigned long)data.length, e ? [@" " stringByAppendingString:e.localizedDescription] : @"");
        });
        return YES;
    }
    // lang?set=en|cs|system: the app's own language, for checking both (the device's stays); it applies from the next
    // launch, so the app quits
    if ([target isEqualToString:@"lang"]) {
        NSString *set = params[@"set"] ?: @"system";
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if ([set isEqualToString:@"system"]) [d removeObjectForKey:@"AppleLanguages"];
        else [d setObject:@[ set ] forKey:@"AppleLanguages"];
        [d synchronize];
        S6Log(@"Language %@ from the next launch: quitting", set);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        return YES;
    }
    if ([target isEqualToString:@"snapshot"] || [target isEqualToString:@"screen"]) {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
        BOOL ok = NO;
        if ([target isEqualToString:@"screen"]) {
            CGImageRef (*grab)(void) = (CGImageRef (*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
            CGImageRef shot = grab ? grab() : NULL;
            if (shot) { ok = [UIImagePNGRepresentation([UIImage imageWithCGImage:shot]) writeToFile:path atomically:YES]; CGImageRelease(shot); }
        } else {
            CGSize size = [UIScreen mainScreen].bounds.size;
            UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
            for (UIWindow *w in [UIApplication sharedApplication].windows) if (!w.hidden && w.alpha > 0) [w.layer renderInContext:UIGraphicsGetCurrentContext()];
            ok = [UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext()) writeToFile:path atomically:YES];
            UIGraphicsEndImageContext();
        }
        S6Log(@"%@ %@: %@", target, ok ? @"written" : @"failed", path);
        return YES;
    }
    if ([target isEqualToString:@"press"]) {
        NSString *byTitle = params[@"title"];
        NSInteger n = [params[@"n"] integerValue];
        // the screen on top first: a covered screen underneath can have a button with the same label
        NSMutableArray *views = [NSMutableArray array];
        UIView *topView = top.navigationController.view ?: top.view;
        if (topView) [views addObject:topView];
        for (UIWindow *w in [UIApplication sharedApplication].windows) [views addObject:w];
        BOOL pressed = NO;
        for (NSUInteger i = 0; i < views.count && !pressed; i++) {
            UIView *v = views[i];
            if (!byTitle.length && [v isKindOfClass:[UIActionSheet class]] && ((UIActionSheet *)v).visible) {
                UIActionSheet *sheet = (UIActionSheet *)v;
                if ([sheet.delegate respondsToSelector:@selector(actionSheet:clickedButtonAtIndex:)]) [sheet.delegate actionSheet:sheet clickedButtonAtIndex:n];
                [sheet dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (!byTitle.length && [v isKindOfClass:[UIAlertView class]] && ((UIAlertView *)v).visible) {
                UIAlertView *alert = (UIAlertView *)v;
                if ([alert.delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)]) [alert.delegate alertView:alert clickedButtonAtIndex:n];
                [alert dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (byTitle.length && !v.hidden && S6PressView(v, byTitle)) {
                pressed = YES;
            } else {
                [views addObjectsFromArray:v.subviews];
            }
        }
        S6Log(@"Press %@: %@", query ?: @"", pressed ? @"done" : @"nothing found");
        return YES;
    }
    if ([target isEqualToString:@"back"]) { [root goBack]; return YES; }
    if ([target isEqualToString:@"section"]) {
        NSDictionary *names = @{ @"home": @(S6SectionHome), @"search": @(S6SectionSearch), @"liked": @(S6SectionLikedSongs),
                                 @"playlists": @(S6SectionPlaylists), @"albums": @(S6SectionAlbums), @"artists": @(S6SectionArtists),
                                 @"podcasts": @(S6SectionPodcasts), @"settings": @(S6SectionSettings), @"library": @(S6SectionLibrary) };
        NSNumber *section = names[[params[@"name"] lowercaseString] ?: @""];
        if (section) [root showSection:(S6Section)[section integerValue]];
        S6Log(@"Section %@: %@", params[@"name"], section ? @"shown" : @"unknown");
        return YES;
    }
    if ([target isEqualToString:@"play"] && [params[@"uri"] length]) {
        NSString *uri = params[@"uri"];
        NSString *trackId = [S6URIType(uri) isEqualToString:@"track"] ? S6URIId(uri) : nil;
        if (!trackId.length) { [S6Router openURI:uri]; return YES; }
        [S6Catalog tracksForURIs:@[ uri ] completion:^(NSArray *tracks, NSError *error) {
            S6Track *t = tracks.firstObject;
            if (!t) {
                // (straight to the engine: the song needs nothing but its id)
                t = [[S6Track alloc] init];
                t.trackId = trackId;
                t.uri = uri;
                t.name = uri;
                t.playable = YES;
            }
            S6Log(@"Play %@ (%@)", uri, t.name);
            [[S6Player shared] playTracks:@[ t ] startingAt:0 contextURI:uri contextName:t.name];
        }];
        return YES;
    }
    if ([target isEqualToString:@"player"]) {
        S6Player *p = [S6Player shared];
        NSString *cmd = params[@"cmd"];
        if ([cmd isEqualToString:@"pause"]) [p pause];
        else if ([cmd isEqualToString:@"play"]) [p play];
        else if ([cmd isEqualToString:@"next"]) [p next];
        else if ([cmd isEqualToString:@"prev"]) [p previous];
        else if ([cmd isEqualToString:@"seek"]) [p seekToMs:[params[@"ms"] integerValue]];
        else if ([cmd isEqualToString:@"shuffle"]) p.shuffle = !p.shuffle;
        else if ([cmd isEqualToString:@"repeat"]) p.repeat = (S6RepeatMode)((p.repeat + 1) % 3);
        S6Log(@"Player %@: %@", cmd, [p debugState]);
        return YES;
    }
    if ([target isEqualToString:@"nowplaying"]) {
        NSString *panel = params[@"panel"];
        [root presentNowPlayingPanel:[panel isEqualToString:@"lyrics"] ? S6NowPlayingLyrics : [panel isEqualToString:@"queue"] ? S6NowPlayingQueue : S6NowPlayingArt];
        return YES;
    }
    if ([target isEqualToString:@"rotate"]) {
        // (debug only, for testing without turning the iPad: a private UIDevice method turns the interface)
        NSInteger o = [params[@"o"] isEqualToString:@"landscape"] ? UIInterfaceOrientationLandscapeLeft : UIInterfaceOrientationPortrait;
        SEL sel = NSSelectorFromString(@"setOrientation:");
        if ([[UIDevice currentDevice] respondsToSelector:sel]) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[UIDevice instanceMethodSignatureForSelector:sel]];
            inv.selector = sel;
            inv.target = [UIDevice currentDevice];
            [inv setArgument:&o atIndex:2];
            [inv invoke];
        }
        S6Log(@"Rotate to %@: interface now %ld", params[@"o"], (long)[UIApplication sharedApplication].statusBarOrientation);
        return YES;
    }
    return YES;
}

@end
