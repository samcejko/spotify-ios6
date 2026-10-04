#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class S6Track;

typedef NS_ENUM(NSInteger, S6RepeatMode) {
    S6RepeatOff = 0,
    S6RepeatAll,
    S6RepeatOne,
};

extern NSString * const S6PlayerDidChangeNotification;      // the song, the state or the queue changed (main thread)
extern NSString * const S6PlayerDidFailNotification;        // userInfo[@"error"]: a song could not be played

// What plays: a context (an album, a playlist, the liked songs, an artist's top songs...) in its order or shuffled,
// the songs the user put in the queue first, repeat, and similar songs when everything has played (autoplay).
// Talks to the engine, the lock screen and the remote controls. Main thread only.
@interface S6Player : NSObject

+ (instancetype)shared;

- (void)playTracks:(NSArray *)tracks startingAt:(NSUInteger)index contextURI:(NSString *)uri contextName:(NSString *)name;
- (void)playTracksShuffled:(NSArray *)tracks contextURI:(NSString *)uri contextName:(NSString *)name;
- (void)addToQueue:(S6Track *)track;
- (void)playNext:(S6Track *)track;                 // first in the queue

- (void)play;
- (void)pause;
- (void)togglePlay;
- (void)next;
- (void)previous;
- (void)seekToMs:(NSInteger)ms;

@property (nonatomic, readonly) S6Track *currentTrack;
@property (nonatomic, readonly) BOOL playing;      // meant to play (also while loading or buffering)
@property (nonatomic, readonly) BOOL loading;
@property (nonatomic, readonly) BOOL buffering;
@property (nonatomic, readonly) NSInteger positionMs;
@property (nonatomic, readonly) NSInteger durationMs;
@property (nonatomic, readonly, copy) NSString *contextURI;
@property (nonatomic, readonly, copy) NSString *contextName;
@property (nonatomic, readonly, copy) NSString *formatName;
@property (nonatomic) BOOL shuffle;
@property (nonatomic) S6RepeatMode repeat;

@property (nonatomic, readonly) NSArray *userQueue;        // S6Track, "Next in queue"
- (NSArray *)upcomingTracks:(NSUInteger)max;               // "Next from <context>"
- (void)removeFromQueueAtIndex:(NSUInteger)index;
- (void)clearQueue;

- (void)handleRemoteEvent:(UIEvent *)event;              // from the app delegate
- (NSString *)debugState;

@end
