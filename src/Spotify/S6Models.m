#import "S6Models.h"
#import "S6Common.h"

NSString *S6URIType(NSString *uri)
{
    NSArray *parts = [uri componentsSeparatedByString:@":"];
    return parts.count >= 3 ? parts[parts.count - 2] : nil;
}

NSString *S6URIId(NSString *uri)
{
    NSArray *parts = [uri componentsSeparatedByString:@":"];
    return parts.count >= 3 ? parts.lastObject : nil;
}

NSString *S6FormatDurationMs(NSInteger ms)
{
    NSInteger total = MAX(0, (ms + 500) / 1000);
    NSInteger h = total / 3600, m = (total / 60) % 60, s = total % 60;
    if (h) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)m, (long)s];
}

@implementation S6Image

+ (NSString *)urlIn:(id)images forSize:(CGFloat)pixels
{
    NSArray *list = S6Arr(images);
    NSString *best = nil, *biggest = nil;
    NSInteger bestWidth = NSIntegerMax, biggestWidth = -1;
    for (id item in list) {
        NSDictionary *d = S6Dict(item);
        NSString *url = S6Str(d[@"url"]);
        if (!url.length) continue;
        NSInteger w = S6Int(d[@"width"]);
        if (w == 0) w = 640;   // (some images say nothing about their size)
        if (w >= pixels && w < bestWidth) { best = url; bestWidth = w; }
        if (w > biggestWidth) { biggest = url; biggestWidth = w; }
    }
    return best ?: biggest;
}

@end

@implementation S6Artist

+ (instancetype)artistFromJSON:(NSDictionary *)json
{
    NSDictionary *j = S6Dict(json);
    if (!j) return nil;
    S6Artist *a = [[S6Artist alloc] init];
    a.artistId = S6Str(j[@"id"]);
    a.uri = S6Str(j[@"uri"]) ?: (a.artistId ? [@"spotify:artist:" stringByAppendingString:a.artistId] : nil);
    a.name = S6Str(j[@"name"]) ?: @"";
    a.images = S6Arr(j[@"images"]);
    a.followers = S6Int(S6Dict(j[@"followers"])[@"total"]);
    a.genres = S6Arr(j[@"genres"]);
    return a;
}

- (NSString *)imageURLForSize:(CGFloat)pixels { return [S6Image urlIn:self.images forSize:pixels]; }

@end

static NSArray *S6ArtistsFrom(id list)
{
    NSMutableArray *out = [NSMutableArray array];
    for (id a in S6Arr(list)) {
        S6Artist *artist = [S6Artist artistFromJSON:a];
        if (artist) [out addObject:artist];
    }
    return out;
}

static NSString *S6Names(NSArray *artists)
{
    NSMutableArray *names = [NSMutableArray array];
    for (S6Artist *a in artists) if (a.name.length) [names addObject:a.name];
    return [names componentsJoinedByString:@", "];
}

@implementation S6Album

+ (instancetype)albumFromJSON:(NSDictionary *)json
{
    NSDictionary *j = S6Dict(json);
    if (!j) return nil;
    S6Album *a = [[S6Album alloc] init];
    a.albumId = S6Str(j[@"id"]);
    a.uri = S6Str(j[@"uri"]) ?: (a.albumId ? [@"spotify:album:" stringByAppendingString:a.albumId] : nil);
    a.name = S6Str(j[@"name"]) ?: @"";
    a.artists = S6ArtistsFrom(j[@"artists"]);
    a.images = S6Arr(j[@"images"]);
    a.albumType = S6Str(j[@"album_type"]) ?: S6Str(j[@"type"]);
    a.releaseDate = S6Str(j[@"release_date"]);
    a.totalTracks = S6Int(j[@"total_tracks"]);
    a.label = S6Str(j[@"label"]);
    NSDictionary *tracks = S6Dict(j[@"tracks"]);
    if (tracks) {
        NSMutableArray *list = [NSMutableArray array];
        for (id t in S6Arr(tracks[@"items"])) {
            S6Track *track = [S6Track trackFromJSON:t album:a];
            if (track) [list addObject:track];
        }
        a.tracks = list;
    }
    return a;
}

- (NSString *)imageURLForSize:(CGFloat)pixels { return [S6Image urlIn:self.images forSize:pixels]; }
- (NSString *)artistNames { return S6Names(self.artists); }
- (NSString *)year { return self.releaseDate.length >= 4 ? [self.releaseDate substringToIndex:4] : @""; }

@end

@implementation S6Track

+ (instancetype)trackFromJSON:(NSDictionary *)json { return [self trackFromJSON:json album:nil]; }

+ (instancetype)trackFromJSON:(NSDictionary *)json album:(S6Album *)album
{
    NSDictionary *j = S6Dict(json);
    if (!j) return nil;
    S6Track *t = [[S6Track alloc] init];
    t.trackId = S6Str(j[@"id"]);
    NSString *type = S6Str(j[@"type"]) ?: @"track";
    t.isEpisode = [type isEqualToString:@"episode"];
    t.uri = S6Str(j[@"uri"]) ?: (t.trackId ? [NSString stringWithFormat:@"spotify:%@:%@", type, t.trackId] : nil);
    t.name = S6Str(j[@"name"]) ?: @"";
    t.artists = S6ArtistsFrom(j[@"artists"]);
    t.album = album ?: [S6Album albumFromJSON:j[@"album"]];
    if (t.isEpisode) {
        // an episode: the show stands where the album would be (a show's own episode list leaves the show out)
        NSDictionary *show = S6Dict(j[@"show"]);
        S6Album *a = [[S6Album alloc] init];
        a.name = S6Str(show[@"name"]) ?: album.name ?: @"";
        a.uri = S6Str(show[@"uri"]) ?: album.uri;
        a.images = S6Arr(j[@"images"]) ?: S6Arr(show[@"images"]) ?: album.images;
        t.album = a;
        if (!t.artists.count) {
            S6Artist *publisher = [[S6Artist alloc] init];
            publisher.name = S6Str(show[@"publisher"]) ?: a.name;
            t.artists = @[ publisher ];
        }
    }
    t.durationMs = S6Int(j[@"duration_ms"]);
    t.explicitContent = S6Bool(j[@"explicit"]);
    t.playable = j[@"is_playable"] ? S6Bool(j[@"is_playable"]) : YES;
    if (S6Bool(j[@"is_local"])) t.playable = NO;
    t.trackNumber = S6Int(j[@"track_number"]);
    t.discNumber = S6Int(j[@"disc_number"]);
    return t;
}

- (NSString *)artistNames { return S6Names(self.artists); }
- (NSString *)imageURLForSize:(CGFloat)pixels { return [self.album imageURLForSize:pixels]; }

- (NSDictionary *)toJSON
{
    NSMutableArray *artists = [NSMutableArray array];
    for (S6Artist *a in self.artists) [artists addObject:@{ @"id": a.artistId ?: @"", @"name": a.name ?: @"", @"uri": a.uri ?: @"" }];
    NSMutableDictionary *album = [NSMutableDictionary dictionary];
    if (self.album) {
        album[@"id"] = self.album.albumId ?: @"";
        album[@"name"] = self.album.name ?: @"";
        album[@"uri"] = self.album.uri ?: @"";
        album[@"images"] = self.album.images ?: @[];
    }
    return @{ @"id": self.trackId ?: @"", @"uri": self.uri ?: @"", @"name": self.name ?: @"", @"type": self.isEpisode ? @"episode" : @"track",
              @"artists": artists, @"album": album, @"duration_ms": @(self.durationMs), @"explicit": @(self.explicitContent),
              @"is_playable": @(self.playable) };
}

@end

@implementation S6Playlist

+ (instancetype)playlistFromJSON:(NSDictionary *)json
{
    NSDictionary *j = S6Dict(json);
    if (!j) return nil;
    S6Playlist *p = [[S6Playlist alloc] init];
    p.playlistId = S6Str(j[@"id"]);
    p.uri = S6Str(j[@"uri"]) ?: (p.playlistId ? [@"spotify:playlist:" stringByAppendingString:p.playlistId] : nil);
    p.name = S6Str(j[@"name"]) ?: @"";
    p.descriptionText = S6Str(j[@"description"]);
    NSDictionary *owner = S6Dict(j[@"owner"]);
    p.ownerName = S6Str(owner[@"display_name"]) ?: S6Str(owner[@"id"]);
    p.ownerId = S6Str(owner[@"id"]);
    p.images = S6Arr(j[@"images"]);
    NSDictionary *tracks = S6Dict(j[@"tracks"]) ?: S6Dict(j[@"items"]);
    p.totalTracks = S6Int(tracks[@"total"]);
    p.followers = S6Int(S6Dict(j[@"followers"])[@"total"]);
    p.collaborative = S6Bool(j[@"collaborative"]);
    p.snapshotId = S6Str(j[@"snapshot_id"]);
    return p;
}

- (NSString *)imageURLForSize:(CGFloat)pixels { return [S6Image urlIn:self.images forSize:pixels]; }

@end

@implementation S6Show

+ (instancetype)showFromJSON:(NSDictionary *)json
{
    NSDictionary *j = S6Dict(json);
    if (!j) return nil;
    S6Show *s = [[S6Show alloc] init];
    s.showId = S6Str(j[@"id"]);
    s.uri = S6Str(j[@"uri"]);
    s.name = S6Str(j[@"name"]) ?: @"";
    s.publisher = S6Str(j[@"publisher"]);
    s.descriptionText = S6Str(j[@"description"]);
    s.images = S6Arr(j[@"images"]);
    return s;
}

- (NSString *)imageURLForSize:(CGFloat)pixels { return [S6Image urlIn:self.images forSize:pixels]; }

@end
