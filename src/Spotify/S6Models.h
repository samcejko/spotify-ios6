#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// What the Web API describes (api.spotify.com JSON), in the shapes the screens use

@interface S6Image : NSObject
+ (NSString *)urlIn:(id)images forSize:(CGFloat)pixels;   // the smallest image at least this big (else the biggest)
@end

@interface S6Artist : NSObject
@property (nonatomic, copy) NSString *artistId;
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray *images;           // JSON image objects
@property (nonatomic) NSInteger followers;
@property (nonatomic, copy) NSArray *genres;
+ (instancetype)artistFromJSON:(NSDictionary *)json;
- (NSString *)imageURLForSize:(CGFloat)pixels;
@end

@interface S6Album : NSObject
@property (nonatomic, copy) NSString *albumId;
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray *artists;          // S6Artist
@property (nonatomic, copy) NSArray *images;
@property (nonatomic, copy) NSString *albumType;       // album, single, compilation
@property (nonatomic, copy) NSString *releaseDate;
@property (nonatomic) NSInteger totalTracks;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSArray *tracks;           // S6Track, when the album was fetched whole
+ (instancetype)albumFromJSON:(NSDictionary *)json;
- (NSString *)imageURLForSize:(CGFloat)pixels;
- (NSString *)artistNames;
- (NSString *)year;
@end

@interface S6Track : NSObject
@property (nonatomic, copy) NSString *trackId;         // base62; nil for local files
@property (nonatomic, copy) NSString *uri;             // spotify:track:... or spotify:episode:...
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray *artists;          // S6Artist
@property (nonatomic, strong) S6Album *album;
@property (nonatomic) NSInteger durationMs;
@property (nonatomic) BOOL explicitContent;
@property (nonatomic) BOOL playable;
@property (nonatomic) BOOL isEpisode;
@property (nonatomic) NSInteger trackNumber;
@property (nonatomic) NSInteger discNumber;
@property (nonatomic, copy) NSString *addedAt;         // in a playlist or the library
+ (instancetype)trackFromJSON:(NSDictionary *)json;    // a track or an episode object
+ (instancetype)trackFromJSON:(NSDictionary *)json album:(S6Album *)album;   // album tracks come without their album
- (NSString *)artistNames;
- (NSString *)imageURLForSize:(CGFloat)pixels;
- (NSDictionary *)toJSON;                              // for the saved queue
@end

@interface S6Playlist : NSObject
@property (nonatomic, copy) NSString *playlistId;
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *descriptionText;
@property (nonatomic, copy) NSString *ownerName;
@property (nonatomic, copy) NSString *ownerId;
@property (nonatomic, copy) NSArray *images;
@property (nonatomic) NSInteger totalTracks;
@property (nonatomic) NSInteger followers;
@property (nonatomic) BOOL collaborative;
@property (nonatomic, copy) NSString *snapshotId;
+ (instancetype)playlistFromJSON:(NSDictionary *)json;
- (NSString *)imageURLForSize:(CGFloat)pixels;
@end

@interface S6Show : NSObject
@property (nonatomic, copy) NSString *showId;
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *publisher;
@property (nonatomic, copy) NSString *descriptionText;
@property (nonatomic, copy) NSArray *images;
+ (instancetype)showFromJSON:(NSDictionary *)json;
- (NSString *)imageURLForSize:(CGFloat)pixels;
@end

// "spotify:track:abc" -> "track", "abc"
NSString *S6URIType(NSString *uri);
NSString *S6URIId(NSString *uri);
NSString *S6FormatDurationMs(NSInteger ms);   // 3:05, 1:02:03
