#import <Foundation/Foundation.h>

@class S6Album, S6Artist, S6Playlist, S6Track;

typedef void (^S6APICompletion)(id json, NSError *error);

// A request on its way; after -cancel its completion never runs
@interface S6APITask : NSObject
@property (atomic, readonly) BOOL cancelled;
- (void)cancel;
@end

// Spotify's public Web API (api.spotify.com/v1) as the logged-in user. Completions run on the main thread.
@interface S6WebAPI : NSObject

// `path` like "/me/playlists?limit=50"; a full https URL (the "next" of a page) works too. `body` is sent as JSON.
+ (S6APITask *)request:(NSString *)method path:(NSString *)path body:(id)body completion:(S6APICompletion)completion;
+ (S6APITask *)get:(NSString *)path completion:(S6APICompletion)completion;

// Pages of tracks: playlist items and saved tracks (item.track) or album tracks (the item itself)
+ (S6APITask *)tracksAt:(NSString *)path album:(S6Album *)album
             completion:(void (^)(NSArray *tracks, NSInteger total, NSString *next, NSError *error))completion;
// Every track of a list, page after page (playlists, liked songs, albums)
+ (S6APITask *)allTracksAt:(NSString *)path album:(S6Album *)album max:(NSInteger)max
                  progress:(void (^)(NSArray *tracksSoFar, NSInteger total))progress
                completion:(void (^)(NSArray *tracks, NSError *error))completion;

// The library
+ (void)isTrackSaved:(NSString *)trackId completion:(void (^)(BOOL saved))completion;
+ (void)setTrack:(NSString *)trackId saved:(BOOL)saved completion:(void (^)(NSError *error))completion;
+ (void)setAlbum:(NSString *)albumId saved:(BOOL)saved completion:(void (^)(NSError *error))completion;
+ (void)setArtist:(NSString *)artistId followed:(BOOL)followed completion:(void (^)(NSError *error))completion;
+ (void)setPlaylist:(NSString *)playlistId followed:(BOOL)followed completion:(void (^)(NSError *error))completion;
+ (void)addTrackURIs:(NSArray *)uris toPlaylist:(NSString *)playlistId completion:(void (^)(NSError *error))completion;
+ (void)removeTrackURI:(NSString *)uri fromPlaylist:(NSString *)playlistId completion:(void (^)(NSError *error))completion;
+ (void)createPlaylistNamed:(NSString *)name completion:(void (^)(S6Playlist *playlist, NSError *error))completion;

+ (NSString *)debugState;

@end
