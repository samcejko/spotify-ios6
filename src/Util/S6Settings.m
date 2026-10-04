#import "S6Settings.h"
#import "S6Keychain.h"
#import "S6Utils.h"
#import "S6Common.h"

#define DEF [NSUserDefaults standardUserDefaults]
static NSString * const S6AccountKey = @"spot6.account";   // keychain: JSON {username, type, data (base64)}
static const NSUInteger S6MaxRecentSearches = 12;

@implementation S6Settings

+ (void)registerDefaults
{
    [DEF registerDefaults:@{
        @"quality": @(S6QualityVeryHigh),
        @"normalize": @YES,
        @"crossfade": @0,
        @"autoplay": @YES,
        @"darkTheme": @YES,
        @"verifyTLS": @YES,
        @"recentSearches": @[],
    }];
}

+ (void)save { [DEF synchronize]; }

+ (void)notify
{
    S6Main(^{ [[NSNotificationCenter defaultCenter] postNotificationName:S6SettingsDidChangeNotification object:nil]; });
}

#pragma mark - Account

+ (NSDictionary *)account
{
    NSString *json = [S6Keychain stringForKey:S6AccountKey];
    if (!json.length) return nil;
    return S6Dict([S6Utils JSONObjectFromData:[json dataUsingEncoding:NSUTF8StringEncoding]]);
}

+ (NSString *)username { return S6Str([self account][@"username"]); }
+ (NSInteger)authType { return S6Int([self account][@"type"]); }
+ (NSData *)authData { return [S6Utils base64Decode:S6Str([self account][@"data"]) ?: @""]; }
+ (BOOL)hasAccount { return [self username].length > 0 && [self authData].length > 0; }

+ (void)setUsername:(NSString *)username authType:(NSInteger)authType authData:(NSData *)authData
{
    if (!username.length || !authData.length) return;
    NSDictionary *d = @{ @"username": username, @"type": @(authType), @"data": [S6Utils base64Encode:authData] };
    NSData *json = [S6Utils JSONDataFromObject:d];
    [S6Keychain setString:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] forKey:S6AccountKey];
    [self notify];
}

+ (void)forgetAccount
{
    [S6Keychain setString:nil forKey:S6AccountKey];
    [self notify];
}

#pragma mark - Device

// 40 hex digits like Spotify's own devices; made once and kept (Spotify ties the credentials it hands to a device
// through the zeroconf login to this id)
+ (NSString *)deviceId
{
    NSString *d = [DEF stringForKey:@"deviceId"];
    if (d.length == 40) return d;
    NSMutableString *m = [NSMutableString stringWithCapacity:40];
    for (int i = 0; i < 5; i++) [m appendFormat:@"%08x", arc4random()];
    [DEF setObject:m forKey:@"deviceId"];
    [DEF synchronize];
    return m;
}

+ (NSString *)deviceName
{
    NSString *n = [DEF stringForKey:@"deviceName"];
    if (n.length) return n;
    return S6IsPad() ? @"Spot6 (iPad)" : @"Spot6 (iPhone)";
}

+ (void)setDeviceName:(NSString *)name
{
    NSString *s = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length) [DEF setObject:s forKey:@"deviceName"];
    else [DEF removeObjectForKey:@"deviceName"];
    [self notify];
}

#pragma mark - Playback

+ (S6Quality)quality
{
    NSInteger q = [DEF integerForKey:@"quality"];
    return (S6Quality)MAX(0, MIN(2, q));
}
+ (void)setQuality:(S6Quality)quality { [DEF setInteger:quality forKey:@"quality"]; [self notify]; }

+ (BOOL)normalize { return [DEF boolForKey:@"normalize"]; }
+ (void)setNormalize:(BOOL)value { [DEF setBool:value forKey:@"normalize"]; [self notify]; }

+ (NSInteger)crossfadeSeconds { return MAX(0, MIN(12, [DEF integerForKey:@"crossfade"])); }
+ (void)setCrossfadeSeconds:(NSInteger)value { [DEF setInteger:MAX(0, MIN(12, value)) forKey:@"crossfade"]; [self notify]; }

+ (BOOL)autoplay { return [DEF boolForKey:@"autoplay"]; }
+ (void)setAutoplay:(BOOL)value { [DEF setBool:value forKey:@"autoplay"]; [self notify]; }

#pragma mark - Appearance, network

+ (BOOL)darkTheme { return [DEF boolForKey:@"darkTheme"]; }
+ (void)setDarkTheme:(BOOL)value { [DEF setBool:value forKey:@"darkTheme"]; [self notify]; }

+ (BOOL)verifyTLS { return [DEF boolForKey:@"verifyTLS"]; }
+ (void)setVerifyTLS:(BOOL)value { [DEF setBool:value forKey:@"verifyTLS"]; [self notify]; }

#pragma mark - Recent searches

+ (NSArray *)recentSearches { return S6Arr([DEF objectForKey:@"recentSearches"]) ?: @[]; }

+ (void)addRecentSearch:(NSString *)query
{
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return;
    NSMutableArray *list = [[self recentSearches] mutableCopy];
    for (NSInteger i = (NSInteger)list.count - 1; i >= 0; i--) {
        if ([S6Str(list[(NSUInteger)i]) caseInsensitiveCompare:q] == NSOrderedSame) [list removeObjectAtIndex:(NSUInteger)i];
    }
    [list insertObject:q atIndex:0];
    while (list.count > S6MaxRecentSearches) [list removeLastObject];
    [DEF setObject:list forKey:@"recentSearches"];
}

+ (void)clearRecentSearches { [DEF setObject:@[] forKey:@"recentSearches"]; }

@end
