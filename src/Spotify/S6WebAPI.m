#import "S6WebAPI.h"
#import "S6Models.h"
#import "S6Tokens.h"
#import "S6Session.h"
#import "S6Utils.h"
#import "S6Common.h"
#include <unistd.h>

static NSString * const S6APIBase = @"https://api.spotify.com/v1";

@interface S6APITask ()
@property (atomic) BOOL cancelled;
@end

@implementation S6APITask
- (void)cancel { self.cancelled = YES; }
@end

// The state of a walk over pages (kept in an object: blocks in __block variables can stay on the stack)
@interface S6TrackWalk : NSObject
@property (nonatomic, strong) NSMutableArray *tracks;
@property (nonatomic, strong) S6Album *album;
@property (nonatomic) NSInteger max;
@property (nonatomic, copy) void (^progress)(NSArray *, NSInteger);
@property (nonatomic, copy) void (^completion)(NSArray *, NSError *);
@property (nonatomic, strong) S6APITask *task;
@end
@implementation S6TrackWalk
@end

static NSInteger S6RequestCount;
static NSInteger S6LastStatus;

@implementation S6WebAPI

+ (dispatch_queue_t)queue
{
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.samcejko.spot6.webapi", DISPATCH_QUEUE_CONCURRENT); });
    return q;
}

+ (S6APITask *)get:(NSString *)path completion:(S6APICompletion)completion
{
    return [self request:@"GET" path:path body:nil completion:completion];
}

+ (S6APITask *)request:(NSString *)method path:(NSString *)path body:(id)body completion:(S6APICompletion)completion
{
    S6APITask *task = [[S6APITask alloc] init];
    S6APICompletion done = [completion copy];
    dispatch_async([self queue], ^{
        NSError *error = nil;
        id json = [self syncRequest:method path:path body:body error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!task.cancelled && done) done(json, error);
        });
    });
    return task;
}

+ (id)syncRequest:(NSString *)method path:(NSString *)path body:(id)body error:(NSError **)error
{
    NSString *url = [path hasPrefix:@"https://"] ? path : [S6APIBase stringByAppendingString:path];
    NSData *bodyData = body ? [S6Utils JSONDataFromObject:body] : nil;
    for (int attempt = 0; attempt < 3; attempt++) {
        NSString *token = [[S6Tokens shared] webTokenWithError:error];
        if (!token) return nil;
        NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:@{ @"Authorization": [@"Bearer " stringByAppendingString:token],
                                                                                       @"Accept": @"application/json" }];
        if (bodyData) headers[@"Content-Type"] = @"application/json";
        NSInteger status = 0;
        NSDictionary *responseHeaders = nil;
        NSData *data = S6SyncRequest(method, url, headers, bodyData ?: ([method isEqualToString:@"GET"] ? nil : [NSData data]), &status, &responseHeaders, error);
        S6RequestCount++;
        S6LastStatus = status;
        if (!data) return nil;
        if (status == 401 && attempt == 0) {
            [[S6Tokens shared] invalidateWebToken];
            continue;
        }
        if (status == 429) {
            NSInteger wait = [responseHeaders[@"retry-after"] integerValue];
            S6Log(@"web api: rate limited on %@ (retry after %ld s)", path, (long)wait);
            if (wait > 0 && wait <= 5 && attempt < 2) { sleep((unsigned)wait); continue; }
            if (error) *error = S6MakeError(429, L(@"Spotify is busy, try again in a moment."));
            return nil;
        }
        id json = data.length ? [S6Utils JSONObjectFromData:data] : nil;
        if (status >= 400) {
            NSString *message = S6Str(S6Dict(S6Dict(json)[@"error"])[@"message"]);
            S6Log(@"web api %@ %@: %ld %@", method, path, (long)status, message ?: @"");
            if (error) *error = S6MakeError(status, message.length ? message : [NSString stringWithFormat:L(@"Spotify answered with error %ld."), (long)status]);
            return json;
        }
        return json ?: @{};
    }
    if (error && !*error) *error = S6MakeError(401, L(@"Spotify did not accept the login."));
    return nil;
}

#pragma mark - Track pages

+ (NSArray *)tracksFromPage:(NSDictionary *)page album:(S6Album *)album
{
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in S6Arr(page[@"items"])) {
        NSDictionary *d = S6Dict(item);
        NSDictionary *trackJSON = S6Dict(d[@"track"]) ?: (d[@"episode"] ? S6Dict(d[@"episode"]) : nil);
        S6Track *t = trackJSON ? [S6Track trackFromJSON:trackJSON] : [S6Track trackFromJSON:d album:album];
        if (!t || !t.uri.length) continue;
        t.addedAt = S6Str(d[@"added_at"]);
        [tracks addObject:t];
    }
    return tracks;
}

+ (S6APITask *)tracksAt:(NSString *)path album:(S6Album *)album completion:(void (^)(NSArray *, NSInteger, NSString *, NSError *))completion
{
    return [self get:path completion:^(id json, NSError *error) {
        NSDictionary *page = S6Dict(json);
        NSString *next = S6Str(page[@"next"]);
        completion([self tracksFromPage:page album:album], S6Int(page[@"total"]), next.length ? next : nil, error);
    }];
}

+ (S6APITask *)allTracksAt:(NSString *)path album:(S6Album *)album max:(NSInteger)max progress:(void (^)(NSArray *, NSInteger))progress
                completion:(void (^)(NSArray *, NSError *))completion
{
    S6TrackWalk *walk = [[S6TrackWalk alloc] init];
    walk.tracks = [NSMutableArray array];
    walk.album = album;
    walk.max = max > 0 ? max : 10000;
    walk.progress = progress;
    walk.completion = completion;
    walk.task = [[S6APITask alloc] init];
    [self walk:walk path:path];
    return walk.task;
}

+ (void)walk:(S6TrackWalk *)walk path:(NSString *)path
{
    S6APITask *outer = walk.task;
    [self tracksAt:path album:walk.album completion:^(NSArray *tracks, NSInteger total, NSString *next, NSError *error) {
        if (outer.cancelled) return;
        [walk.tracks addObjectsFromArray:tracks];
        if (error || !next || (NSInteger)walk.tracks.count >= walk.max) {
            if (walk.completion) walk.completion([walk.tracks copy], walk.tracks.count ? nil : error);
            walk.completion = nil;
            walk.progress = nil;
            return;
        }
        if (walk.progress) walk.progress([walk.tracks copy], total);
        [self walk:walk path:next];
    }];
}

#pragma mark - Library

+ (void)isTrackSaved:(NSString *)trackId completion:(void (^)(BOOL))completion
{
    if (!trackId.length) { completion(NO); return; }
    [self get:[NSString stringWithFormat:@"/me/tracks/contains?ids=%@", trackId] completion:^(id json, NSError *error) {
        completion(S6Bool(S6Arr(json).firstObject));
    }];
}

+ (void)notifyLibrary
{
    [[NSNotificationCenter defaultCenter] postNotificationName:S6LibraryDidChangeNotification object:nil];
}

+ (void)setTrack:(NSString *)trackId saved:(BOOL)saved completion:(void (^)(NSError *))completion
{
    [self request:saved ? @"PUT" : @"DELETE" path:[NSString stringWithFormat:@"/me/tracks?ids=%@", trackId] body:nil completion:^(id json, NSError *error) {
        if (!error) [self notifyLibrary];
        if (completion) completion(error);
    }];
}

+ (void)setAlbum:(NSString *)albumId saved:(BOOL)saved completion:(void (^)(NSError *))completion
{
    [self request:saved ? @"PUT" : @"DELETE" path:[NSString stringWithFormat:@"/me/albums?ids=%@", albumId] body:nil completion:^(id json, NSError *error) {
        if (!error) [self notifyLibrary];
        if (completion) completion(error);
    }];
}

+ (void)setArtist:(NSString *)artistId followed:(BOOL)followed completion:(void (^)(NSError *))completion
{
    [self request:followed ? @"PUT" : @"DELETE" path:[NSString stringWithFormat:@"/me/following?type=artist&ids=%@", artistId] body:nil completion:^(id json, NSError *error) {
        if (!error) [self notifyLibrary];
        if (completion) completion(error);
    }];
}

+ (void)setPlaylist:(NSString *)playlistId followed:(BOOL)followed completion:(void (^)(NSError *))completion
{
    [self request:followed ? @"PUT" : @"DELETE" path:[NSString stringWithFormat:@"/playlists/%@/followers", playlistId] body:nil completion:^(id json, NSError *error) {
        if (!error) [self notifyLibrary];
        if (completion) completion(error);
    }];
}

+ (void)addTrackURIs:(NSArray *)uris toPlaylist:(NSString *)playlistId completion:(void (^)(NSError *))completion
{
    [self request:@"POST" path:[NSString stringWithFormat:@"/playlists/%@/tracks", playlistId] body:@{ @"uris": uris ?: @[] } completion:^(id json, NSError *error) {
        if (!error) [self notifyLibrary];
        if (completion) completion(error);
    }];
}

+ (void)removeTrackURI:(NSString *)uri fromPlaylist:(NSString *)playlistId completion:(void (^)(NSError *))completion
{
    [self request:@"DELETE" path:[NSString stringWithFormat:@"/playlists/%@/tracks", playlistId] body:@{ @"tracks": @[ @{ @"uri": uri ?: @"" } ] } completion:^(id json, NSError *error) {
        if (!error) [self notifyLibrary];
        if (completion) completion(error);
    }];
}

+ (void)createPlaylistNamed:(NSString *)name completion:(void (^)(S6Playlist *, NSError *))completion
{
    NSString *user = [S6Session shared].username ?: @"me";
    [self request:@"POST" path:[NSString stringWithFormat:@"/users/%@/playlists", [S6Utils urlEncode:user]] body:@{ @"name": name ?: @"", @"public": @NO }
       completion:^(id json, NSError *error) {
        S6Playlist *p = error ? nil : [S6Playlist playlistFromJSON:json];
        if (p) [self notifyLibrary];
        completion(p, p ? nil : error);
    }];
}

+ (NSString *)debugState
{
    return [NSString stringWithFormat:@"web api: %ld requests, last status %ld", (long)S6RequestCount, (long)S6LastStatus];
}

@end
