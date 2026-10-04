#import "S6Player.h"
#import "S6PlaybackEngine.h"
#import "S6Models.h"
#import "S6SpClient.h"
#import "S6Catalog.h"
#import "S6ImageLoader.h"
#import "S6Settings.h"
#import "S6Common.h"
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>

NSString * const S6PlayerDidChangeNotification = @"S6PlayerDidChangeNotification";
NSString * const S6PlayerDidFailNotification = @"S6PlayerDidFailNotification";

static const NSInteger S6RestartThresholdMs = 3000;    // "previous" after this restarts the song instead
static const NSInteger S6MaxSkipsOnError = 5;

@interface S6Player () <S6PlaybackEngineDelegate>
@property (nonatomic, strong) S6Track *currentTrack;
@property (nonatomic) BOOL playing;
@property (nonatomic) BOOL loading;
@property (nonatomic, copy) NSString *contextURI;
@property (nonatomic, copy) NSString *contextName;
@property (nonatomic, strong) NSMutableArray *queue;          // user queue
@end

@implementation S6Player {
    NSArray *_contextTracks;
    NSMutableArray *_order;           // indices into _contextTracks, in play order
    NSInteger _orderPos;              // where the current context song is in _order (-1 none)
    BOOL _currentFromQueue;           // the current song came from the user queue
    NSUInteger _loadToken;            // bumps with every load: late answers are dropped
    S6Track *_preparedTrack;          // the next song the engine got ready (gapless)
    NSUInteger _prepareToken;
    NSInteger _failures;
    S6PlaybackEngine *_engine;
    dispatch_queue_t _loadQueue;
    id _artworkToken;
    NSString *_artworkURL;
    UIImage *_artwork;
    BOOL _fetchingRadio;
}

+ (instancetype)shared
{
    static S6Player *player;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ player = [[S6Player alloc] init]; });
    return player;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _queue = [NSMutableArray array];
        _order = [NSMutableArray array];
        _orderPos = -1;
        _loadQueue = dispatch_queue_create("com.samcejko.spot6.load", DISPATCH_QUEUE_CONCURRENT);
        _engine = [S6PlaybackEngine shared];
        _engine.delegate = self;
        [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateNowPlaying) userInfo:nil repeats:YES];
    }
    return self;
}

- (NSArray *)userQueue { return [self.queue copy]; }
- (BOOL)buffering { return self.loading || _engine.buffering; }
- (NSInteger)positionMs { return _engine.currentItem ? _engine.positionMs : 0; }
- (NSInteger)durationMs { return _engine.currentItem.durationMs ?: self.currentTrack.durationMs; }
- (NSString *)formatName { return _engine.currentItem.formatName; }

- (void)changed
{
    [[NSNotificationCenter defaultCenter] postNotificationName:S6PlayerDidChangeNotification object:self];
    [self updateNowPlaying];
}

#pragma mark - Context

static void S6Shuffle(NSMutableArray *a)
{
    for (NSUInteger i = a.count; i > 1; i--) [a exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((u_int32_t)i)];
}

- (void)buildOrderStartingWith:(NSInteger)first
{
    [_order removeAllObjects];
    for (NSUInteger i = 0; i < _contextTracks.count; i++) [_order addObject:@(i)];
    if (self.shuffle) {
        S6Shuffle(_order);
        if (first >= 0) {
            [_order removeObject:@(first)];
            [_order insertObject:@(first) atIndex:0];
        }
        _orderPos = first >= 0 ? 0 : -1;
    } else {
        _orderPos = first;
    }
}

- (void)playTracks:(NSArray *)tracks startingAt:(NSUInteger)index contextURI:(NSString *)uri contextName:(NSString *)name
{
    if (!tracks.count) return;
    _contextTracks = [tracks copy];
    self.contextURI = uri;
    self.contextName = name;
    NSInteger start = (NSInteger)MIN(index, tracks.count - 1);
    // (a song that cannot play is passed over)
    while (start < (NSInteger)tracks.count && ![tracks[(NSUInteger)start] playable]) start++;
    if (start >= (NSInteger)tracks.count) return;
    [self buildOrderStartingWith:start];
    _currentFromQueue = NO;
    _failures = 0;
    [self loadAndPlay:tracks[(NSUInteger)start]];
}

- (void)playTracksShuffled:(NSArray *)tracks contextURI:(NSString *)uri contextName:(NSString *)name
{
    if (!tracks.count) return;
    self.shuffle = YES;
    [self playTracks:tracks startingAt:arc4random_uniform((u_int32_t)tracks.count) contextURI:uri contextName:name];
}

- (void)setShuffle:(BOOL)shuffle
{
    if (_shuffle == shuffle) return;
    _shuffle = shuffle;
    // the order changes, the current song stays where it is
    NSInteger current = (_orderPos >= 0 && _orderPos < (NSInteger)_order.count) ? [_order[(NSUInteger)_orderPos] integerValue] : -1;
    [self buildOrderStartingWith:current];
    [self dropPrepared];
    [self changed];
}

- (void)setRepeat:(S6RepeatMode)repeat
{
    _repeat = repeat;
    [self dropPrepared];
    [self changed];
}

- (void)addToQueue:(S6Track *)track
{
    if (!track) return;
    [self.queue addObject:track];
    [self dropPrepared];
    [self changed];
}

- (void)playNext:(S6Track *)track
{
    if (!track) return;
    [self.queue insertObject:track atIndex:0];
    [self dropPrepared];
    [self changed];
}

- (void)removeFromQueueAtIndex:(NSUInteger)index
{
    if (index < self.queue.count) [self.queue removeObjectAtIndex:index];
    [self dropPrepared];
    [self changed];
}

- (void)clearQueue
{
    [self.queue removeAllObjects];
    [self dropPrepared];
    [self changed];
}

- (NSArray *)upcomingTracks:(NSUInteger)max
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger p = _orderPos + 1; p < (NSInteger)_order.count && out.count < max; p++) {
        [out addObject:_contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]]];
    }
    return out;
}

// What comes after the current song, without moving there: (track, from queue?, order position)
- (S6Track *)peekNext:(BOOL *)fromQueue position:(NSInteger *)position
{
    if (self.queue.count) { *fromQueue = YES; *position = _orderPos; return self.queue[0]; }
    *fromQueue = NO;
    if (self.repeat == S6RepeatOne && self.currentTrack) { *position = _orderPos; return self.currentTrack; }
    for (NSInteger p = _orderPos + 1; p < (NSInteger)_order.count; p++) {
        S6Track *t = _contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]];
        if (t.playable) { *position = p; return t; }
    }
    if (self.repeat == S6RepeatAll && _order.count) {
        for (NSInteger p = 0; p < (NSInteger)_order.count; p++) {
            S6Track *t = _contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]];
            if (t.playable) { *position = p; return t; }
        }
    }
    return nil;
}

#pragma mark - Loading

- (void)loadAndPlay:(S6Track *)track
{
    NSUInteger token = ++_loadToken;
    [self dropPrepared];
    self.currentTrack = track;
    self.loading = YES;
    self.playing = YES;
    [_engine stop];
    [self changed];
    S6Quality quality = [S6Settings quality];
    dispatch_async(_loadQueue, ^{
        NSError *error = nil;
        S6PlaybackItem *item = [S6PlaybackItem loadTrack:track quality:quality error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self->_loadToken) { [item cancel]; return; }
            self.loading = NO;
            if (!item) {
                [self failed:track error:error];
                return;
            }
            self->_failures = 0;
            [self->_engine playItem:item fromMs:0 paused:!self.playing];
        });
    });
}

- (void)failed:(S6Track *)track error:(NSError *)error
{
    S6Log(@"cannot play %@: %@", track.name, error.localizedDescription);
    [[NSNotificationCenter defaultCenter] postNotificationName:S6PlayerDidFailNotification object:self
                                                      userInfo:@{ @"error": error ?: S6MakeError(S6ErrorPlayback, L(@"This song cannot be played.")) }];
    if (++_failures >= S6MaxSkipsOnError) {
        self.playing = NO;
        [self changed];
        return;
    }
    [self advanceAutomatically:NO];
}

- (void)dropPrepared
{
    _prepareToken++;
    _preparedTrack = nil;
    [_engine queueNextItem:nil];
}

- (void)engineNeedsNextItem
{
    BOOL fromQueue = NO;
    NSInteger position = -1;
    S6Track *next = [self peekNext:&fromQueue position:&position];
    if (!next || next == _preparedTrack) return;
    NSUInteger token = ++_prepareToken;
    _preparedTrack = next;
    S6Quality quality = [S6Settings quality];
    dispatch_async(_loadQueue, ^{
        S6PlaybackItem *item = [S6PlaybackItem loadTrack:next quality:quality error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self->_prepareToken || !item) { [item cancel]; return; }
            [self->_engine queueNextItem:item];
        });
    });
}

#pragma mark - Engine events

- (void)engineDidStartItem:(S6PlaybackItem *)item
{
    if (item.track != self.currentTrack) {
        // the prepared next song went on without a gap: the queue moves along
        [self moveToTrack:item.track];
        self.currentTrack = item.track;
        _preparedTrack = nil;
    }
    self.loading = NO;
    [self changed];
}

- (void)engineDidFinishItem:(S6PlaybackItem *)item
{
    [self advanceAutomatically:YES];
}

- (void)engineDidFailItem:(S6PlaybackItem *)item error:(NSError *)error
{
    [self failed:item.track error:error];
}

// The queue position follows a song that started by itself (gapless)
- (void)moveToTrack:(S6Track *)track
{
    if (self.queue.count && self.queue[0] == track) {
        [self.queue removeObjectAtIndex:0];
        _currentFromQueue = YES;
        return;
    }
    _currentFromQueue = NO;
    if (self.repeat == S6RepeatOne) return;
    for (NSInteger p = _orderPos + 1; p < (NSInteger)_order.count; p++) {
        if (_contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]] == track) { _orderPos = p; return; }
    }
    for (NSInteger p = 0; p < (NSInteger)_order.count; p++) {
        if (_contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]] == track) { _orderPos = p; return; }
    }
}

- (void)advanceAutomatically:(BOOL)automatic
{
    if (automatic && self.repeat == S6RepeatOne && self.currentTrack) {
        [self loadAndPlay:self.currentTrack];
        return;
    }
    if (self.queue.count) {
        S6Track *t = self.queue[0];
        [self.queue removeObjectAtIndex:0];
        _currentFromQueue = YES;
        [self loadAndPlay:t];
        return;
    }
    for (NSInteger p = _orderPos + 1; p < (NSInteger)_order.count; p++) {
        S6Track *t = _contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]];
        if (!t.playable) continue;
        _orderPos = p;
        _currentFromQueue = NO;
        [self loadAndPlay:t];
        return;
    }
    if (self.repeat == S6RepeatAll && _order.count) {
        if (self.shuffle) S6Shuffle(_order);
        _orderPos = -1;
        [self advanceAutomatically:NO];
        return;
    }
    if ([S6Settings autoplay] && self.currentTrack.uri.length && !_fetchingRadio) {
        // the end of the context: similar songs follow (Spotify's autoplay)
        _fetchingRadio = YES;
        S6Track *seed = self.currentTrack;
        [S6SpClient radioForURI:seed.uri completion:^(NSArray *uris, NSError *error) {
            self->_fetchingRadio = NO;
            if (!uris.count) { self.playing = NO; [self changed]; return; }
            NSMutableArray *list = [NSMutableArray array];
            for (NSString *u in uris) if (list.count < 50 && ![u isEqualToString:seed.uri]) [list addObject:u];
            [S6Catalog tracksForURIs:list completion:^(NSArray *found, NSError *e) {
                NSMutableArray *tracks = [NSMutableArray array];
                for (S6Track *track in found) if (track.uri.length && track.playable) [tracks addObject:track];
                if (!tracks.count) { self.playing = NO; [self changed]; return; }
                [self playTracks:tracks startingAt:0 contextURI:[@"spotify:radio:" stringByAppendingString:seed.trackId ?: @""]
                     contextName:[NSString stringWithFormat:L(@"%@ Radio"), seed.name]];
            }];
        }];
        return;
    }
    self.playing = NO;
    [_engine stop];
    [self changed];
}

#pragma mark - Controls

- (void)play
{
    if (!self.currentTrack) return;
    self.playing = YES;
    if (_engine.currentItem) [_engine resume];
    else if (!self.loading) [self loadAndPlay:self.currentTrack];
    [self changed];
}

- (void)pause
{
    self.playing = NO;
    [_engine pause];
    [self changed];
}

- (void)togglePlay
{
    if (self.playing) [self pause];
    else [self play];
}

- (void)next
{
    if (!self.currentTrack) return;
    self.playing = YES;
    [self advanceAutomatically:NO];
}

- (void)previous
{
    if (!self.currentTrack) return;
    if (self.positionMs > S6RestartThresholdMs || _orderPos <= 0 || _currentFromQueue) {
        [self seekToMs:0];
        if (!self.playing) [self play];
        return;
    }
    for (NSInteger p = _orderPos - 1; p >= 0; p--) {
        S6Track *t = _contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]];
        if (!t.playable) continue;
        _orderPos = p;
        self.playing = YES;
        [self loadAndPlay:t];
        return;
    }
    [self seekToMs:0];
}

- (void)seekToMs:(NSInteger)ms
{
    [_engine seekToMs:ms];
    [self changed];
}

#pragma mark - Lock screen, remote controls

- (void)handleRemoteEvent:(UIEvent *)event
{
    if (event.type != UIEventTypeRemoteControl) return;
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlPlay: [self play]; break;
        case UIEventSubtypeRemoteControlPause: [self pause]; break;
        case UIEventSubtypeRemoteControlStop: [self pause]; break;
        case UIEventSubtypeRemoteControlTogglePlayPause: [self togglePlay]; break;
        case UIEventSubtypeRemoteControlNextTrack: [self next]; break;
        case UIEventSubtypeRemoteControlPreviousTrack: [self previous]; break;
        default: break;
    }
}

- (void)updateNowPlaying
{
    S6Track *t = self.currentTrack;
    if (!t) {
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
        return;
    }
    NSString *art = [t imageURLForSize:300];
    if (art.length && ![art isEqualToString:_artworkURL]) {
        _artworkURL = art;
        _artwork = nil;
        __weak S6Player *weakSelf = self;
        _artworkToken = [[S6ImageLoader shared] loadImage:art maxPixels:600 completion:^(UIImage *image) {
            S6Player *me = weakSelf;
            if (!me || ![me->_artworkURL isEqualToString:art]) return;
            me->_artwork = image;
            [me updateNowPlaying];
        }];
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = t.name ?: @"";
    info[MPMediaItemPropertyArtist] = [t artistNames] ?: @"";
    if (t.album.name.length) info[MPMediaItemPropertyAlbumTitle] = t.album.name;
    info[MPMediaItemPropertyPlaybackDuration] = @((double)self.durationMs / 1000.0);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @((double)self.positionMs / 1000.0);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.playing && !self.buffering ? 1.0 : 0.0);
    if (_artwork) info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithImage:_artwork];
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

- (NSString *)debugState
{
    return [NSString stringWithFormat:@"player: %@ (%@), %@, context %@ (%ld/%lu), queue %lu, shuffle %d, repeat %ld | %@",
            self.currentTrack.name ?: @"-", self.currentTrack.uri ?: @"-", self.playing ? (self.loading ? @"loading" : @"playing") : @"paused",
            self.contextName ?: @"-", (long)_orderPos, (unsigned long)_order.count, (unsigned long)self.queue.count, self.shuffle, (long)self.repeat,
            [_engine debugState]];
}

@end
