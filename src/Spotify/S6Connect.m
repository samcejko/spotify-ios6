#import "S6Connect.h"
#import "S6WebSocket.h"
#import "S6Session.h"
#import "S6Tokens.h"
#import "S6SpClient.h"
#import "S6Pathfinder.h"
#import "S6Player.h"
#import "S6AudioOutput.h"
#import "S6Proto.h"
#import "S6Crypto.h"
#import "S6Models.h"
#import "S6Settings.h"
#import "S6Utils.h"
#import "S6Common.h"
#include <zlib.h>
#include <unistd.h>

NSString * const S6ConnectDidChangeNotification = @"S6ConnectDidChangeNotification";

static const NSTimeInterval S6DealerPingInterval = 30;
static const long long S6ActivationGraceMs = 6000;        // cluster news older than our taking over is not a takeover

static long long S6NowMs(void) { return (long long)([[NSDate date] timeIntervalSince1970] * 1000.0); }

static NSString *S6RandomHex(NSUInteger bytes) { return [S6Crypto hex:[S6Crypto randomBytes:bytes]]; }

static NSData *S6Gunzip(NSData *data)
{
    if (data.length < 18) return nil;
    z_stream s;
    memset(&s, 0, sizeof(s));
    if (inflateInit2(&s, 16 + MAX_WBITS) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:data.length * 4 + 4096];
    s.next_in = (Bytef *)data.bytes;
    s.avail_in = (uInt)data.length;
    int ret = Z_OK;
    while (ret == Z_OK) {
        if (s.total_out >= out.length) [out increaseLengthBy:out.length];
        s.next_out = (Bytef *)out.mutableBytes + s.total_out;
        s.avail_out = (uInt)(out.length - s.total_out);
        ret = inflate(&s, Z_NO_FLUSH);
    }
    uLong total = s.total_out;
    inflateEnd(&s);
    if (ret != Z_STREAM_END) return nil;
    out.length = total;
    return out;
}

// {uri, uid} of a ContextTrack (protobuf: uri 1, uid 2, gid 3)
static NSDictionary *S6EntryFromProto(NSData *m)
{
    NSString *uri = S6ProtoString(m, 1);
    if (!uri.length) {
        NSData *gid = S6ProtoBytes(m, 3);
        if (gid.length == 16) uri = [@"spotify:track:" stringByAppendingString:S6Base62FromGid(gid) ?: @""];
    }
    if (!uri.length) return nil;
    NSString *uid = S6ProtoString(m, 2);
    return uid.length ? @{ @"uri": uri, @"uid": uid } : @{ @"uri": uri };
}

// {uri, uid} of a track in JSON ({uri, uid, metadata...})
static NSDictionary *S6EntryFromJSON(id json)
{
    NSDictionary *d = S6Dict(json);
    NSString *uri = S6Str(d[@"uri"]);
    if (!uri.length) return nil;
    NSString *uid = S6Str(d[@"uid"]);
    return uid.length ? @{ @"uri": uri, @"uid": uid } : @{ @"uri": uri };
}

// (one object per place in the list: the same song twice keeps two uids)
static S6Track *S6CopyTrack(S6Track *s)
{
    S6Track *t = [[S6Track alloc] init];
    t.trackId = s.trackId;
    t.uri = s.uri;
    t.name = s.name;
    t.artists = s.artists;
    t.album = s.album;
    t.durationMs = s.durationMs;
    t.explicitContent = s.explicitContent;
    t.playable = s.playable;
    t.isEpisode = s.isEpisode;
    t.trackNumber = s.trackNumber;
    t.discNumber = s.discNumber;
    t.playcount = s.playcount;
    t.releaseDate = s.releaseDate;
    return t;
}

static S6Track *S6BareTrack(NSString *uri)
{
    S6Track *t = [[S6Track alloc] init];
    t.uri = uri;
    t.trackId = S6URIId(uri);
    t.isEpisode = [S6URIType(uri) isEqualToString:@"episode"];
    t.name = @"";
    t.playable = ![S6URIType(uri) isEqualToString:@"local"] && t.trackId.length > 0;
    return t;
}

// A song as the player state lists it (ProvidedTrack)
static NSDictionary *S6Provided(S6Track *t, NSString *provider)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:t.uri ?: @"" forKey:@"uri"];
    if (t.uid.length) d[@"uid"] = t.uid;
    d[@"provider"] = provider;
    if ([provider isEqualToString:@"queue"]) d[@"metadata"] = @{ @"is_queued": @"true" };
    if (t.album.uri.length) d[@"album_uri"] = t.album.uri;
    S6Artist *a = t.artists.firstObject;
    if (a.uri.length) d[@"artist_uri"] = a.uri;
    return d;
}

@interface S6Connect ()
@property (atomic) BOOL registered;
@property (atomic) BOOL active;
@property (atomic, copy) NSString *controller;
@property (atomic, copy) NSString *lastEvent;
@property (atomic, copy) NSString *connectionId;
@property (atomic) BOOL running;
@property (nonatomic, strong) NSDictionary *cluster;      // the last cluster in JSON (main thread)
@end

@implementation S6Connect {
    NSUInteger _generation;            // a new start makes an older dealer thread finish
    S6WebSocket *_socket;
    dispatch_queue_t _putQueue;        // the state updates, one after the other
    dispatch_queue_t _workQueue;       // resolving contexts
    // (main thread)
    BOOL _putScheduled;
    NSString *_pendingReason;
    NSUInteger _messageCounter;
    NSUInteger _startToken;
    uint32_t _lastCommandMessageId;
    NSString *_lastCommandSender;
    NSString *_playbackId;
    NSString *_sessionId;
    NSDictionary *_playOrigin;
    NSString *_lastTrackURI;
    long long _activatedAt;
    long long _startedPlayingAt;
}

+ (instancetype)shared
{
    static S6Connect *connect;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ connect = [[S6Connect alloc] init]; });
    return connect;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _putQueue = dispatch_queue_create("com.samcejko.spot6.connect.state", DISPATCH_QUEUE_SERIAL);
        _workQueue = dispatch_queue_create("com.samcejko.spot6.connect.work", DISPATCH_QUEUE_CONCURRENT);
        _playbackId = S6RandomHex(16);
        _sessionId = S6RandomHex(16);
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(sessionChanged) name:S6SessionStateDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(playerChanged) name:S6PlayerDidChangeNotification object:nil];
    }
    return self;
}

- (void)event:(NSString *)text
{
    self.lastEvent = text;
    S6Log(@"connect: %@", text);
}

- (void)changed
{
    S6Main(^{ [[NSNotificationCenter defaultCenter] postNotificationName:S6ConnectDidChangeNotification object:self]; });
}

- (void)sessionChanged
{
    S6SessionState state = [S6Session shared].state;
    if (state == S6SessionStateReady) [self start];
    else if (state == S6SessionStateLoggedOut || state == S6SessionStateFailed) [self stop];
}

#pragma mark - Starting and stopping

- (void)start
{
    if (self.running) return;
    self.running = YES;
    NSUInteger generation;
    @synchronized (self) { generation = ++_generation; }
    NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(dealerLoop:) object:@(generation)];
    thread.name = @"S6Connect dealer";
    [thread start];
}

- (void)stop
{
    if (!self.running) return;
    self.running = NO;
    if (self.active) {
        self.active = NO;
        [self sendState:@"BECAME_INACTIVE"];
    }
    @synchronized (self) {
        _generation++;
        [_socket cancel];
    }
    self.registered = NO;
    [self changed];
}

- (BOOL)isCurrent:(NSUInteger)generation
{
    @synchronized (self) { return generation == _generation; }
}

#pragma mark - The dealer (push channel)

- (void)dealerLoop:(NSNumber *)generationNumber
{
    NSUInteger generation = generationNumber.unsignedIntegerValue;
    NSTimeInterval backoff = 2;
    while ([self isCurrent:generation]) {
        @autoreleasepool {
            NSError *error = nil;
            NSString *token = [[S6Session shared] waitUntilReady:30 error:&error] ? [[S6Tokens shared] accessTokenWithError:&error] : nil;
            if (!token) {
                [self event:[NSString stringWithFormat:@"no token for the dealer (%@)", error.localizedDescription ?: @"?"]];
                [self pause:backoff generation:generation];
                backoff = MIN(60, backoff * 2);
                continue;
            }
            NSString *host = [S6Session shared].dealerHost ?: @"dealer.spotify.com:443";
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"wss://%@/?access_token=%@", host, [S6Utils urlEncode:token]]];
            S6WebSocket *ws = [[S6WebSocket alloc] init];
            @synchronized (self) {
                if (generation != _generation) break;
                _socket = ws;
            }
            if (![ws connectToURL:url origin:nil userAgent:S6UserAgent verify:[S6Settings verifyTLS] error:&error]) {
                [self event:[NSString stringWithFormat:@"dealer %@: %@", host, error.localizedDescription]];
                [ws close];
                [self pause:backoff generation:generation];
                backoff = MIN(60, backoff * 2);
                continue;
            }
            [self event:[NSString stringWithFormat:@"dealer %@ connected", host]];
            backoff = 2;
            NSDate *lastPing = [NSDate date];
            while ([self isCurrent:generation]) {
                @autoreleasepool {
                    BOOL closed = NO;
                    NSError *readError = nil;
                    NSArray *messages = [ws readMessages:&closed error:&readError];
                    for (NSString *text in messages) [self handleText:text socket:ws];
                    if (closed) {
                        [self event:[NSString stringWithFormat:@"dealer closed (%@)", readError.localizedDescription ?: @"by the server"]];
                        break;
                    }
                    if (-[lastPing timeIntervalSinceNow] >= S6DealerPingInterval) {
                        lastPing = [NSDate date];
                        if (![ws sendText:@"{\"type\":\"ping\"}" error:&readError]) break;
                    }
                }
            }
            [ws close];
            @synchronized (self) { if (_socket == ws) _socket = nil; }
            self.connectionId = nil;
            self.registered = NO;
            [self changed];
            if ([self isCurrent:generation]) [self pause:2 generation:generation];
        }
    }
}

- (void)pause:(NSTimeInterval)seconds generation:(NSUInteger)generation
{
    for (int i = 0; i < (int)(seconds * 4) && [self isCurrent:generation]; i++) usleep(250000);
}

// A dealer message's first payload: JSON (an object) or protobuf bytes, base64 and gzip undone
- (id)payloadOf:(NSDictionary *)message
{
    id first = S6Arr(message[@"payloads"]).firstObject;
    if ([first isKindOfClass:[NSDictionary class]]) return first;
    NSString *text = S6Str(first);
    if (!text.length) return nil;
    NSDictionary *headers = S6Dict(message[@"headers"]);
    NSData *data = [S6Utils base64Decode:text];
    if ([[S6Str(headers[@"Transfer-Encoding"]) lowercaseString] isEqualToString:@"gzip"]) data = S6Gunzip(data) ?: data;
    if ([[S6Str(headers[@"Content-Type"]) lowercaseString] rangeOfString:@"json"].location != NSNotFound) {
        return S6Dict([S6Utils JSONObjectFromData:data]) ?: data;
    }
    return data;
}

// A request's command: {"compressed": base64 of gzipped JSON} or the JSON itself
- (NSDictionary *)requestPayload:(NSDictionary *)message
{
    NSDictionary *payload = S6Dict(message[@"payload"]);
    NSString *compressed = S6Str(payload[@"compressed"]);
    if (!compressed.length) return payload;
    NSData *data = S6Gunzip([S6Utils base64Decode:compressed]);
    return S6Dict([S6Utils JSONObjectFromData:data]);
}

// (dealer thread)
- (void)handleText:(NSString *)text socket:(S6WebSocket *)ws
{
    NSDictionary *message = S6Dict([S6Utils JSONObjectFromData:[text dataUsingEncoding:NSUTF8StringEncoding]]);
    NSString *type = S6Str(message[@"type"]);
    if (!message || [type isEqualToString:@"pong"]) return;
    if ([type isEqualToString:@"request"]) {
        // the acknowledgement first: the device that sent the command waits for it
        NSString *key = S6Str(message[@"key"]) ?: @"";
        NSData *reply = [S6Utils JSONDataFromObject:@{ @"type": @"reply", @"key": key, @"payload": @{ @"success": @YES } }];
        [ws sendText:[[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding] error:NULL];
        NSString *ident = S6Str(message[@"message_ident"]) ?: @"";
        NSDictionary *payload = [self requestPayload:message];
        if (!payload) { S6Log(@"connect: request %@ without a readable payload", ident); return; }
        dispatch_async(dispatch_get_main_queue(), ^{ [self handleRequest:payload ident:ident]; });
        return;
    }
    if (![type isEqualToString:@"message"]) return;
    NSString *uri = S6Str(message[@"uri"]) ?: @"";
    if ([uri hasPrefix:@"hm://pusher/v1/connections/"]) {
        NSString *cid = S6Str(S6Dict(message[@"headers"])[@"Spotify-Connection-Id"]);
        if (!cid.length) cid = [[uri substringFromIndex:@"hm://pusher/v1/connections/".length] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        self.connectionId = cid;
        dispatch_async(dispatch_get_main_queue(), ^{ [self sendState:@"NEW_DEVICE"]; });
        return;
    }
    id payload = [self payloadOf:message];
    if ([uri hasPrefix:@"hm://connect-state/v1/cluster"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self handleCluster:payload]; });
    } else if ([uri rangeOfString:@"connect/volume"].location != NSNotFound) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self handleVolume:payload]; });
    } else if ([uri rangeOfString:@"connect/logout"].location == NSNotFound) {
        S6Log(@"connect: message %@", uri);
    }
}

#pragma mark - What comes in (main thread)

- (void)handleRequest:(NSDictionary *)payload ident:(NSString *)ident
{
    if ([ident rangeOfString:@"volume"].location != NSNotFound) { [self handleVolume:payload]; return; }
    if ([ident rangeOfString:@"player/command"].location == NSNotFound) { S6Log(@"connect: request %@", ident); return; }
    [self handleCommand:payload];
}

- (NSString *)nameOfDevice:(NSString *)deviceId
{
    NSDictionary *devices = S6Dict(self.cluster[@"devices"]) ?: S6Dict(self.cluster[@"device"]);
    return S6Str(S6Dict(devices[deviceId])[@"name"]);
}

- (void)handleCluster:(id)payload
{
    NSString *activeDevice = nil;
    if ([payload isKindOfClass:[NSDictionary class]]) {
        NSDictionary *cluster = S6Dict(payload[@"cluster"]) ?: payload;
        self.cluster = cluster;
        activeDevice = S6Str(cluster[@"active_device_id"]);
    } else if ([payload isKindOfClass:[NSData class]]) {
        // ClusterUpdate (protobuf): cluster 1 -> active_device_id 2
        activeDevice = S6ProtoString(S6ProtoBytes(payload, 1), 2);
    }
    if (self.active && activeDevice.length && ![activeDevice isEqualToString:[S6Settings deviceId]] &&
        S6NowMs() - _activatedAt > S6ActivationGraceMs) {
        // another device took the playback over: it goes on there
        NSString *name = [self nameOfDevice:activeDevice];
        [self event:[NSString stringWithFormat:@"playback moved to %@", name ?: activeDevice]];
        self.active = NO;
        [[S6Player shared] pause];
        [self sendState:@"BECAME_INACTIVE"];
        [self changed];
    }
}

- (void)handleVolume:(id)payload
{
    NSInteger volume = -1;
    if ([payload isKindOfClass:[NSDictionary class]]) volume = payload[@"volume"] ? S6Int(payload[@"volume"]) : -1;
    else if ([payload isKindOfClass:[NSData class]]) volume = (NSInteger)S6ProtoVarint(payload, 1, (uint64_t)-1);
    if (volume < 0 || volume > 65535) return;
    [S6AudioOutput shared].volume = (float)volume / 65535.f;
    [self event:[NSString stringWithFormat:@"volume %ld %%", (long)(volume * 100 / 65535)]];
    [self scheduleState:@"VOLUME_CHANGED"];
}

- (void)handleCommand:(NSDictionary *)request
{
    NSDictionary *cmd = S6Dict(request[@"command"]) ?: request;
    NSString *endpoint = S6Str(cmd[@"endpoint"]) ?: @"";
    _lastCommandMessageId = (uint32_t)S6Int(request[@"message_id"]);
    _lastCommandSender = S6Str(request[@"sent_by_device_id"]);
    if (_lastCommandSender.length) self.controller = [self nameOfDevice:_lastCommandSender] ?: self.controller;
    [self event:[NSString stringWithFormat:@"command %@ from %@", endpoint, self.controller ?: _lastCommandSender ?: @"?"]];
    S6Player *p = [S6Player shared];
    if ([endpoint isEqualToString:@"transfer"]) {
        [self transfer:cmd];
    } else if ([endpoint isEqualToString:@"play"]) {
        [self play:cmd];
    } else if ([endpoint isEqualToString:@"pause"]) {
        [p pause];
    } else if ([endpoint isEqualToString:@"resume"]) {
        [self takeOver];
        [p play];
    } else if ([endpoint isEqualToString:@"seek_to"]) {
        NSInteger value = S6Int(cmd[@"value"]);
        if ([S6Str(cmd[@"relative"]) isEqualToString:@"current"]) value += p.positionMs;
        else if (cmd[@"position"] && !cmd[@"value"]) value = S6Int(cmd[@"position"]);
        [p seekToMs:MAX(0, value)];
    } else if ([endpoint isEqualToString:@"skip_next"]) {
        [self takeOver];
        [p next];
    } else if ([endpoint isEqualToString:@"skip_prev"]) {
        [self takeOver];
        [p previous];
    } else if ([endpoint isEqualToString:@"set_shuffling_context"]) {
        p.shuffle = S6Bool(cmd[@"value"]);
    } else if ([endpoint isEqualToString:@"set_repeating_context"]) {
        if (S6Bool(cmd[@"value"])) { if (p.repeat == S6RepeatOff) p.repeat = S6RepeatAll; }
        else if (p.repeat == S6RepeatAll) p.repeat = S6RepeatOff;
    } else if ([endpoint isEqualToString:@"set_repeating_track"]) {
        if (S6Bool(cmd[@"value"])) p.repeat = S6RepeatOne;
        else if (p.repeat == S6RepeatOne) p.repeat = S6RepeatAll;
    } else if ([endpoint isEqualToString:@"set_options"]) {
        NSDictionary *o = S6Dict(cmd[@"options"]) ?: cmd;
        if (o[@"shuffling_context"]) p.shuffle = S6Bool(o[@"shuffling_context"]);
        if (o[@"repeating_track"] || o[@"repeating_context"]) {
            p.repeat = S6Bool(o[@"repeating_track"]) ? S6RepeatOne : S6Bool(o[@"repeating_context"]) ? S6RepeatAll : S6RepeatOff;
        }
    } else if ([endpoint isEqualToString:@"add_to_queue"]) {
        NSDictionary *entry = S6EntryFromJSON(cmd[@"track"]);
        if (entry) [self resolve:@[ entry ] then:^(NSArray *tracks) { for (S6Track *t in tracks) [[S6Player shared] addToQueue:t]; }];
    } else if ([endpoint isEqualToString:@"set_queue"]) {
        NSMutableArray *queued = [NSMutableArray array];
        for (id t in S6Arr(cmd[@"next_tracks"])) {
            NSDictionary *d = S6Dict(t);
            BOOL isQueued = [S6Str(d[@"provider"]) isEqualToString:@"queue"] || [S6Str(S6Dict(d[@"metadata"])[@"is_queued"]) isEqualToString:@"true"];
            NSDictionary *entry = S6EntryFromJSON(d);
            if (isQueued && entry) [queued addObject:entry];
        }
        [self resolve:queued then:^(NSArray *tracks) { [[S6Player shared] replaceQueue:tracks]; }];
    } else if (![endpoint isEqualToString:@"update_context"]) {
        S6Log(@"connect: command %@ not handled", endpoint);
    }
    [self scheduleState:@"PLAYER_STATE_CHANGED"];
    [self changed];
}

// A command that plays makes this the active device
- (void)takeOver
{
    if (self.active) return;
    self.active = YES;
    _activatedAt = S6NowMs();
    _startedPlayingAt = _activatedAt;
    _sessionId = S6RandomHex(16);
    [self changed];
}

#pragma mark - Playing a context

// TransferState (protobuf): options 1 {shuffling_context 1, repeating_context 2, repeating_track 3}; playback 2
// {timestamp 1, position_as_of_timestamp 2, is_paused 4, current_track 5}; current_session 3 {play_origin 1,
// context 2 {uri 1, metadata 3, pages 5 {tracks 4}}, current_uid 3}; queue 4 {tracks 1}
- (NSDictionary *)stateFromTransfer:(NSData *)data
{
    NSData *options = S6ProtoBytes(data, 1), *playback = S6ProtoBytes(data, 2), *session = S6ProtoBytes(data, 3), *queue = S6ProtoBytes(data, 4);
    NSData *context = S6ProtoBytes(session, 2);
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"shuffle"] = @(S6ProtoVarint(options, 1, 0) != 0);
    s[@"repeatContext"] = @(S6ProtoVarint(options, 2, 0) != 0);
    s[@"repeatTrack"] = @(S6ProtoVarint(options, 3, 0) != 0);
    s[@"timestamp"] = @((long long)S6ProtoVarint(playback, 1, 0));
    s[@"position"] = @((long long)S6ProtoVarint(playback, 2, 0));
    s[@"paused"] = @(S6ProtoVarint(playback, 4, 0) != 0);
    NSDictionary *current = S6EntryFromProto(S6ProtoBytes(playback, 5));
    if (current) s[@"current"] = current;
    s[@"uid"] = S6ProtoString(session, 3) ?: @"";
    s[@"context"] = S6ProtoString(context, 1) ?: @"";
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    for (NSData *entry in S6ProtoAllBytes(context, 3)) {
        NSString *k = S6ProtoString(entry, 1), *v = S6ProtoString(entry, 2);
        if (k.length && v) meta[k] = v;
    }
    s[@"name"] = meta[@"context_description"] ?: @"";
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSData *page in S6ProtoAllBytes(context, 5)) {
        for (NSData *t in S6ProtoAllBytes(page, 4)) {
            NSDictionary *entry = S6EntryFromProto(t);
            if (entry) [tracks addObject:entry];
        }
    }
    s[@"tracks"] = tracks;
    NSMutableArray *queued = [NSMutableArray array];
    for (NSData *t in S6ProtoAllBytes(queue, 1)) {
        NSDictionary *entry = S6EntryFromProto(t);
        if (entry) [queued addObject:entry];
    }
    s[@"queue"] = queued;
    return s;
}

// The same from the other device's player state in the cluster (JSON), when the transfer data says too little
- (NSDictionary *)stateFromCluster
{
    NSDictionary *ps = S6Dict(self.cluster[@"player_state"]);
    if (!ps) return nil;
    NSDictionary *options = S6Dict(ps[@"options"]);
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"shuffle"] = @(S6Bool(options[@"shuffling_context"]));
    s[@"repeatContext"] = @(S6Bool(options[@"repeating_context"]));
    s[@"repeatTrack"] = @(S6Bool(options[@"repeating_track"]));
    s[@"timestamp"] = @((long long)S6Dbl(ps[@"timestamp"]));
    s[@"position"] = @((long long)S6Dbl(ps[@"position_as_of_timestamp"]));
    s[@"paused"] = @(S6Bool(ps[@"is_paused"]));
    NSDictionary *current = S6EntryFromJSON(ps[@"track"]);
    if (current) s[@"current"] = current;
    s[@"uid"] = S6Str(S6Dict(ps[@"track"])[@"uid"]) ?: @"";
    s[@"context"] = S6Str(ps[@"context_uri"]) ?: @"";
    s[@"name"] = S6Str(S6Dict(ps[@"context_metadata"])[@"context_description"]) ?: @"";
    s[@"tracks"] = @[];
    NSMutableArray *queued = [NSMutableArray array];
    for (id t in S6Arr(ps[@"next_tracks"])) {
        NSDictionary *d = S6Dict(t);
        NSDictionary *entry = S6EntryFromJSON(d);
        if (entry && [S6Str(d[@"provider"]) isEqualToString:@"queue"]) [queued addObject:entry];
    }
    s[@"queue"] = queued;
    return s;
}

- (void)transfer:(NSDictionary *)cmd
{
    NSData *data = [S6Utils base64Decode:S6Str(cmd[@"data"]) ?: @""];
    NSDictionary *state = data.length ? [self stateFromTransfer:data] : nil;
    if (!state || (![state[@"context"] length] && !state[@"current"])) state = [self stateFromCluster];
    if (!state) { [self event:@"transfer without a state"]; return; }
    NSDictionary *options = S6Dict(cmd[@"options"]);
    NSString *restorePaused = S6Str(options[@"restore_paused"]);
    BOOL paused = [restorePaused isEqualToString:@"pause"] ? YES : [restorePaused isEqualToString:@"resume"] ? NO : [state[@"paused"] boolValue];
    long long position = [state[@"position"] longLongValue], timestamp = [state[@"timestamp"] longLongValue];
    if (![state[@"paused"] boolValue] && timestamp > 0) position += MAX(0, S6NowMs() - timestamp);   // (it kept playing there meanwhile)
    if ([S6Str(options[@"restore_position"]) isEqualToString:@"beginning"]) position = 0;
    S6Player *p = [S6Player shared];
    p.shuffle = [state[@"shuffle"] boolValue];
    p.repeat = [state[@"repeatTrack"] boolValue] ? S6RepeatOne : [state[@"repeatContext"] boolValue] ? S6RepeatAll : S6RepeatOff;
    [self playContext:state[@"context"] entries:state[@"tracks"] current:state[@"current"] uid:state[@"uid"] index:-1
           positionMs:position paused:paused name:state[@"name"] queue:state[@"queue"]];
}

- (void)play:(NSDictionary *)cmd
{
    NSDictionary *context = S6Dict(cmd[@"context"]);
    NSMutableArray *entries = [NSMutableArray array];
    for (id page in S6Arr(context[@"pages"])) {
        for (id t in S6Arr(S6Dict(page)[@"tracks"])) {
            NSDictionary *entry = S6EntryFromJSON(t);
            if (entry) [entries addObject:entry];
        }
    }
    NSDictionary *options = S6Dict(cmd[@"options"]);
    NSDictionary *skip = S6Dict(options[@"skip_to"]);
    NSString *trackURI = S6Str(skip[@"track_uri"]);
    NSInteger index = skip[@"track_index"] ? S6Int(skip[@"track_index"]) : -1;
    NSDictionary *override = S6Dict(options[@"player_options_override"]);
    S6Player *p = [S6Player shared];
    if (override[@"shuffling_context"]) p.shuffle = S6Bool(override[@"shuffling_context"]);
    if (override[@"repeating_track"] || override[@"repeating_context"]) {
        p.repeat = S6Bool(override[@"repeating_track"]) ? S6RepeatOne : S6Bool(override[@"repeating_context"]) ? S6RepeatAll : S6RepeatOff;
    }
    _playOrigin = S6Dict(cmd[@"play_origin"]);
    [self playContext:S6Str(context[@"uri"]) entries:entries current:trackURI.length ? @{ @"uri": trackURI } : nil uid:S6Str(skip[@"track_uid"])
                index:index positionMs:S6Int(options[@"seek_to"]) paused:S6Bool(options[@"initially_paused"])
                 name:S6Str(S6Dict(context[@"metadata"])[@"context_description"]) queue:nil];
}

- (void)playContext:(NSString *)uri entries:(NSArray *)given current:(NSDictionary *)current uid:(NSString *)uid index:(NSInteger)index
         positionMs:(long long)position paused:(BOOL)paused name:(NSString *)name queue:(NSArray *)queued
{
    [self takeOver];
    NSUInteger token = ++_startToken;
    NSArray *givenEntries = [given copy] ?: @[];
    NSArray *queueEntries = [queued copy] ?: @[];
    [self event:[NSString stringWithFormat:@"playing %@ (%lu songs given, start %@)", uri ?: @"-", (unsigned long)givenEntries.count,
                 uid.length ? uid : current[@"uri"] ?: @(index)]];
    dispatch_async(_workQueue, ^{
        NSArray *entries = givenEntries.count ? givenEntries : (uri.length ? [self contextResolve:uri] : @[]);
        if (!entries.count && current) entries = @[ current ];
        // where to start: the uid, else the song, else the place
        NSUInteger start = NSNotFound;
        for (NSUInteger i = 0; i < entries.count && start == NSNotFound && uid.length; i++) if ([entries[i][@"uid"] isEqualToString:uid]) start = i;
        for (NSUInteger i = 0; i < entries.count && start == NSNotFound && current; i++) if ([entries[i][@"uri"] isEqualToString:current[@"uri"]]) start = i;
        if (start == NSNotFound) start = index >= 0 && (NSUInteger)index < entries.count ? (NSUInteger)index : 0;
        NSArray *tracks = [self tracksFor:entries];
        NSArray *queueTracks = queueEntries.count ? [self tracksFor:queueEntries] : @[];
        NSString *contextName = name.length ? name : nil;
        if (!contextName && [S6URIType(uri) isEqualToString:@"album"] && tracks.count) contextName = [tracks[0] album].name;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self->_startToken) return;
            if (!tracks.count) { [self event:[NSString stringWithFormat:@"nothing to play in %@", uri ?: @"-"]]; return; }
            S6Player *p = [S6Player shared];
            [p playTracks:tracks startingAt:start positionMs:(NSInteger)position paused:paused contextURI:uri contextName:contextName ?: L(@"Spotify Connect")];
            [p replaceQueue:queueTracks];
            [self scheduleState:@"PLAYER_STATE_CHANGED"];
        });
    });
}

// The songs of a context through the context resolver (spclient), page after page (blocking)
- (NSArray *)contextResolve:(NSString *)uri
{
    NSMutableArray *entries = [NSMutableArray array];
    NSMutableArray *pending = [NSMutableArray arrayWithObject:[@"/context-resolve/v1/" stringByAppendingString:uri]];
    for (int fetched = 0; pending.count && fetched < 12 && entries.count < 1500; fetched++) {
        NSString *path = pending[0];
        [pending removeObjectAtIndex:0];
        NSData *data = [S6SpClient request:@"GET" path:path body:nil contentType:nil accept:@"application/json" status:NULL error:NULL];
        NSDictionary *json = S6Dict([S6Utils JSONObjectFromData:data]);
        if (!json) continue;
        NSArray *pages = S6Arr(json[@"pages"]) ?: @[ json ];   // (a further page answers as a page)
        for (id p in pages) {
            NSDictionary *page = S6Dict(p);
            NSArray *tracks = S6Arr(page[@"tracks"]);
            for (id t in tracks) {
                NSDictionary *entry = S6EntryFromJSON(t);
                if (entry) [entries addObject:entry];
            }
            // (a page that came without its songs says where they are; the last one says where more are)
            NSMutableArray *links = [NSMutableArray array];
            if (!tracks.count && S6Str(page[@"page_url"]).length) [links addObject:S6Str(page[@"page_url"])];
            if (S6Str(page[@"next_page_url"]).length) [links addObject:S6Str(page[@"next_page_url"])];
            for (NSString *next in links) {
                if ([next hasPrefix:@"hm://"]) [pending addObject:[@"/" stringByAppendingString:[next substringFromIndex:5]]];
            }
        }
    }
    S6Log(@"connect: %@ resolved to %lu songs", uri, (unsigned long)entries.count);
    return entries;
}

// Names, artists and covers of {uri, uid} entries through GraphQL, 50 at a time side by side (blocking); the order
// and the uids stay
- (NSArray *)tracksFor:(NSArray *)entries
{
    NSUInteger n = MIN(entries.count, (NSUInteger)1500);
    NSUInteger batches = (n + 49) / 50;
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    dispatch_apply(batches, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t b) {
        NSMutableArray *uris = [NSMutableArray array];
        for (NSUInteger i = b * 50; i < MIN(n, (b + 1) * 50); i++) {
            NSString *u = entries[i][@"uri"];
            if ([S6URIType(u) isEqualToString:@"track"]) [uris addObject:u];
        }
        if (!uris.count) return;
        NSDictionary *data = [S6Pathfinder query:@"decorateContextTracks" variables:@{ @"uris": uris } error:NULL];
        NSMutableDictionary *mine = [NSMutableDictionary dictionary];
        for (id t in S6Arr(data[@"tracks"])) {
            S6Track *track = [S6Track trackFromGraphQL:t album:nil];
            if (track.uri) mine[track.uri] = track;
        }
        @synchronized (found) { [found addEntriesFromDictionary:mine]; }
    });
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        NSDictionary *entry = entries[i];
        S6Track *known = found[entry[@"uri"]];
        S6Track *t = known ? S6CopyTrack(known) : S6BareTrack(entry[@"uri"]);
        t.uid = entry[@"uid"];
        [tracks addObject:t];
    }
    return tracks;
}

// A few songs resolved in the background, then `then` on the main thread
- (void)resolve:(NSArray *)entries then:(void (^)(NSArray *tracks))then
{
    NSArray *list = [entries copy];
    void (^done)(NSArray *) = [then copy];
    dispatch_async(_workQueue, ^{
        NSArray *tracks = [self tracksFor:list];
        dispatch_async(dispatch_get_main_queue(), ^{
            done(tracks);
            [self scheduleState:@"PLAYER_STATE_CHANGED"];
        });
    });
}

#pragma mark - What goes out

- (void)playerChanged
{
    if (!self.registered) return;
    S6Player *p = [S6Player shared];
    if (!self.active) {
        // music started here by hand: the account's playback is here now (the other device stops)
        if (!p.currentTrack || !p.playing) return;
        [self takeOver];
        self.controller = nil;
    }
    if (![p.currentTrack.uri isEqualToString:_lastTrackURI]) {
        _lastTrackURI = p.currentTrack.uri;
        _playbackId = S6RandomHex(16);
    }
    [self scheduleState:@"PLAYER_STATE_CHANGED"];
}

// Changes close together go out as one
- (void)scheduleState:(NSString *)reason
{
    if (!self.connectionId.length) return;
    _pendingReason = reason;
    if (_putScheduled) return;
    _putScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_putScheduled = NO;
        [self sendState:self->_pendingReason ?: @"PLAYER_STATE_CHANGED"];
    });
}

- (NSDictionary *)deviceInfo
{
    NSDictionary *capabilities = @{
        @"can_be_player": @YES, @"gaia_eq_connect_id": @YES, @"supports_logout": @NO, @"is_observable": @YES, @"volume_steps": @64,
        @"supported_types": @[ @"audio/track", @"audio/episode" ], @"command_acks": @YES, @"supports_playlist_v2": @YES,
        @"is_controllable": @YES, @"supports_transfer_command": @YES, @"supports_command_request": @YES, @"supports_gzip_pushes": @YES,
        @"supports_set_options_command": @YES, @"needs_full_player_state": @YES, @"hidden": @NO, @"disable_volume": @NO,
        @"restrict_to_local": @NO, @"is_voice_enabled": @NO, @"supports_rename": @NO, @"supports_external_episodes": @NO,
        @"supports_set_backend_metadata": @NO,
    };
    return @{ @"can_play": @YES, @"volume": @((NSInteger)lroundf([S6AudioOutput shared].volume * 65535.f)), @"name": [S6Settings deviceName] ?: @"Spot6",
              @"capabilities": capabilities, @"device_software_version": @"1.2.52.442", @"device_type": S6IsPad() ? @"TABLET" : @"SMARTPHONE",
              @"spirc_version": @"3.2.6", @"device_id": [S6Settings deviceId] ?: @"", @"client_id": S6ClientId, @"brand": @"Spot6",
              @"model": S6IsPad() ? @"iPad" : @"iPhone" };
}

- (NSDictionary *)playerState:(long long)now
{
    S6Player *p = [S6Player shared];
    S6Track *t = p.currentTrack;
    if (!t.uri.length) return nil;
    BOOL paused = !p.playing;
    NSString *context = p.contextURI.length ? p.contextURI : t.uri;
    NSMutableArray *next = [NSMutableArray array];
    for (S6Track *q in p.userQueue) if (next.count < 20) [next addObject:S6Provided(q, @"queue")];
    for (S6Track *q in [p upcomingTracks:30]) [next addObject:S6Provided(q, @"context")];
    NSMutableArray *previous = [NSMutableArray array];
    for (S6Track *q in [p previousTracks:10]) [previous addObject:S6Provided(q, @"context")];
    NSMutableString *revision = [NSMutableString string];
    for (NSDictionary *d in next) [revision appendString:d[@"uri"]];
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"timestamp"] = @(now);
    s[@"context_uri"] = context;
    s[@"context_url"] = [@"context://" stringByAppendingString:context];
    s[@"context_restrictions"] = @{};
    s[@"play_origin"] = _playOrigin ?: @{ @"feature_identifier": @"spot6", @"feature_version": [S6Utils appVersion] ?: @"" };
    s[@"index"] = @{ @"page": @0, @"track": @(MAX(0, p.contextIndex)) };
    s[@"track"] = S6Provided(t, p.contextIndex < 0 ? @"queue" : @"context");
    s[@"playback_id"] = _playbackId ?: S6RandomHex(16);
    s[@"playback_speed"] = @(paused ? 0 : 1);
    s[@"position_as_of_timestamp"] = @(p.positionMs);
    s[@"duration"] = @(p.durationMs);
    s[@"is_playing"] = @YES;
    s[@"is_paused"] = @(paused);
    // (BOOLs boxed as BOOL: JSON true/false, not 1/0)
    s[@"is_buffering"] = @((BOOL)(p.buffering && !paused));
    s[@"is_system_initiated"] = @NO;
    s[@"options"] = @{ @"shuffling_context": @(p.shuffle), @"repeating_context": @((BOOL)(p.repeat == S6RepeatAll)),
                       @"repeating_track": @((BOOL)(p.repeat == S6RepeatOne)) };
    s[@"restrictions"] = @{};
    s[@"next_tracks"] = next;
    s[@"prev_tracks"] = previous;
    s[@"session_id"] = _sessionId ?: S6RandomHex(16);
    s[@"queue_revision"] = [NSString stringWithFormat:@"%lu", (unsigned long)revision.hash];
    if (p.contextName.length) s[@"context_metadata"] = @{ @"context_description": p.contextName };
    return s;
}

- (NSDictionary *)stateRequest:(NSString *)reason
{
    long long now = S6NowMs();
    NSMutableDictionary *device = [NSMutableDictionary dictionaryWithObject:[self deviceInfo] forKey:@"device_info"];
    BOOL active = self.active && ![reason isEqualToString:@"BECAME_INACTIVE"];
    NSDictionary *state = active ? [self playerState:now] : nil;
    if (state) device[@"player_state"] = state;
    NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary:@{
        @"member_type": @"CONNECT_STATE", @"put_state_reason": reason, @"device": device, @"is_active": @((BOOL)(active && state != nil)),
        @"client_side_timestamp": @(now), @"message_id": @(++_messageCounter) }];
    if (_lastCommandSender.length) {
        r[@"last_command_sent_by_device_id"] = _lastCommandSender;
        r[@"last_command_message_id"] = @(_lastCommandMessageId);
    }
    if (active && state) {
        r[@"started_playing_at"] = @(_startedPlayingAt);
        r[@"has_been_playing_for_ms"] = @(MAX(0, now - _startedPlayingAt));
    }
    return r;
}

// The state goes out now (main thread: taken from the player here, sent in the background)
- (void)sendState:(NSString *)reason
{
    NSString *cid = self.connectionId;
    if (!cid.length) return;
    NSData *body = [S6Utils JSONDataFromObject:[self stateRequest:reason]];
    NSString *path = [@"/connect-state/v1/devices/" stringByAppendingString:[S6Settings deviceId] ?: @""];
    dispatch_async(_putQueue, ^{
        NSInteger status = 0;
        NSError *error = nil;
        NSData *answer = [S6SpClient request:@"PUT" path:path body:body contentType:@"application/json" accept:@"application/json"
                                     headers:@{ @"X-Spotify-Connection-Id": cid } status:&status error:&error];
        NSDictionary *cluster = S6Dict([S6Utils JSONObjectFromData:answer]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!answer) { [self event:[NSString stringWithFormat:@"state %@ refused: %@", reason, error.localizedDescription]]; return; }
            if (cluster) self.cluster = cluster;
            if ([reason isEqualToString:@"NEW_DEVICE"]) {
                self.registered = YES;
                NSDictionary *devices = S6Dict(cluster[@"devices"]) ?: S6Dict(cluster[@"device"]);
                NSMutableArray *names = [NSMutableArray array];
                for (NSString *key in devices) [names addObject:S6Str(S6Dict(devices[key])[@"name"]) ?: key];
                [self event:[NSString stringWithFormat:@"registered as \"%@\"; devices of the account: %@", [S6Settings deviceName],
                             names.count ? [names componentsJoinedByString:@", "] : @"(none listed)"]];
                // music already playing here goes on as the account's
                if ([S6Player shared].currentTrack && [S6Player shared].playing) [self playerChanged];
            }
            [self changed];
        });
    });
}

#pragma mark - Debug

- (void)debugSendCommand:(NSDictionary *)command
{
    NSString *me = [S6Settings deviceId] ?: @"";
    NSData *body = [S6Utils JSONDataFromObject:@{ @"command": command ?: @{} }];
    dispatch_async(_putQueue, ^{
        NSInteger status = 0;
        NSError *error = nil;
        NSData *answer = [S6SpClient request:@"POST" path:[NSString stringWithFormat:@"/connect-state/v1/player/command/from/%@/to/%@", me, me]
                                        body:body contentType:@"application/json" accept:@"application/json" status:&status error:&error];
        NSString *text = answer ? [[NSString alloc] initWithData:answer encoding:NSUTF8StringEncoding] : error.localizedDescription;
        S6Log(@"connect test %@: HTTP %ld %@", command[@"endpoint"], (long)status, [S6Utils truncate:text ?: @"" to:200]);
    });
}

- (NSString *)debugState
{
    return [NSString stringWithFormat:@"connect: %@, %@, connection %@, controller %@, volume %.0f%%, last: %@", self.registered ? @"registered" : @"not registered",
            self.active ? @"active" : @"inactive", self.connectionId.length ? @"yes" : @"no", self.controller ?: @"-",
            [S6AudioOutput shared].volume * 100.0, self.lastEvent ?: @"-"];
}

@end
