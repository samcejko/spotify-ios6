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

NSString *S6PlainText(NSString *html)
{
    if (!html.length) return html;
    if ([html rangeOfString:@"<"].location == NSNotFound && [html rangeOfString:@"&"].location == NSNotFound) return html;
    static NSRegularExpression *tags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:NULL]; });
    NSMutableString *s = [[tags stringByReplacingMatchesInString:html options:0 range:NSMakeRange(0, html.length) withTemplate:@""] mutableCopy];
    NSDictionary *entities = @{ @"&quot;": @"\"", @"&#x27;": @"'", @"&#39;": @"'", @"&apos;": @"'", @"&lt;": @"<", @"&gt;": @">",
                                @"&nbsp;": @" ", @"&#x2F;": @"/" };
    for (NSString *e in entities) [s replaceOccurrencesOfString:e withString:entities[e] options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, s.length)];
    return s;
}

#pragma mark - GraphQL helpers

// "2013-05-20T00:00:00Z" or {year, month, day} -> "2013-05-20" (or just the year)
static NSString *S6GQLDate(id date)
{
    NSDictionary *d = S6Dict(date);
    NSString *iso = S6Str(d[@"isoString"]);
    if (iso.length >= 10) return [iso substringToIndex:10];
    if (iso.length >= 4) return iso;
    NSInteger y = S6Int(d[@"year"]);
    if (!y) return nil;
    NSInteger m = S6Int(d[@"month"]), day = S6Int(d[@"day"]);
    if (m && day) return [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)y, (long)m, (long)day];
    return [NSString stringWithFormat:@"%04ld", (long)y];
}

static NSInteger S6GQLDuration(NSDictionary *d)
{
    NSDictionary *duration = S6Dict(d[@"duration"]) ?: S6Dict(d[@"trackDuration"]);
    return S6Int(duration[@"totalMilliseconds"]);
}

static BOOL S6GQLPlayable(NSDictionary *d)
{
    NSDictionary *p = S6Dict(d[@"playability"]);
    return p[@"playable"] ? S6Bool(p[@"playable"]) : YES;
}

static NSString *S6GQLURI(NSDictionary *d) { return S6Str(d[@"uri"]) ?: S6Str(d[@"_uri"]); }

#pragma mark - Images

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

#pragma mark - Artist

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

+ (instancetype)artistFromGraphQL:(NSDictionary *)data
{
    NSDictionary *d = S6Dict(data);
    NSString *uri = S6GQLURI(d);
    if (!uri.length) return nil;
    S6Artist *a = [[S6Artist alloc] init];
    a.uri = uri;
    a.artistId = S6Str(d[@"id"]) ?: S6URIId(uri);
    a.name = S6Str(S6Dict(d[@"profile"])[@"name"]) ?: S6Str(d[@"name"]) ?: @"";
    a.images = S6Arr(S6Dict(S6Dict(d[@"visuals"])[@"avatarImage"])[@"sources"]);
    NSDictionary *stats = S6Dict(d[@"stats"]);
    a.followers = S6Int(stats[@"followers"]);
    a.monthlyListeners = S6Int(stats[@"monthlyListeners"]);
    a.saved = S6Bool(d[@"saved"]);
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

static NSArray *S6GQLArtists(id artists)
{
    NSMutableArray *out = [NSMutableArray array];
    for (id item in S6Arr(S6Dict(artists)[@"items"])) {
        S6Artist *a = [S6Artist artistFromGraphQL:item];
        if (a) [out addObject:a];
    }
    return out;
}

static NSString *S6Names(NSArray *artists)
{
    NSMutableArray *names = [NSMutableArray array];
    for (S6Artist *a in artists) if (a.name.length) [names addObject:a.name];
    return [names componentsJoinedByString:@", "];
}

#pragma mark - Album

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

+ (instancetype)albumFromGraphQL:(NSDictionary *)data
{
    NSDictionary *d = S6Dict(data);
    NSString *uri = S6GQLURI(d);
    if (!uri.length) return nil;
    S6Album *a = [[S6Album alloc] init];
    a.uri = uri;
    a.albumId = S6Str(d[@"id"]) ?: S6URIId(uri);
    a.name = S6Str(d[@"name"]) ?: @"";
    a.artists = S6GQLArtists(d[@"artists"]);
    a.images = S6Arr(S6Dict(d[@"coverArt"])[@"sources"]);
    a.albumType = [S6Str(d[@"type"]) lowercaseString];
    a.releaseDate = S6GQLDate(d[@"date"]);
    a.label = S6Str(d[@"label"]);
    a.totalTracks = S6Int(S6Dict(d[@"tracksV2"])[@"totalCount"]) ?: S6Int(S6Dict(d[@"tracks"])[@"totalCount"]);
    a.saved = S6Bool(d[@"saved"]);
    return a;
}

- (NSString *)imageURLForSize:(CGFloat)pixels { return [S6Image urlIn:self.images forSize:pixels]; }
- (NSString *)artistNames { return S6Names(self.artists); }
- (NSString *)year { return self.releaseDate.length >= 4 ? [self.releaseDate substringToIndex:4] : @""; }

@end

#pragma mark - Track

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

+ (instancetype)trackFromGraphQL:(NSDictionary *)data album:(S6Album *)album
{
    NSDictionary *d = S6Dict(data);
    NSString *uri = S6GQLURI(d);
    if (!uri.length) return nil;
    NSString *type = S6Str(d[@"__typename"]);
    S6Track *t = [[S6Track alloc] init];
    t.uri = uri;
    t.isEpisode = [type isEqualToString:@"Episode"] || [S6URIType(uri) isEqualToString:@"episode"];
    t.trackId = S6Str(d[@"id"]) ?: S6URIId(uri);
    t.name = S6Str(d[@"name"]) ?: @"";
    t.durationMs = S6GQLDuration(d);
    t.playable = S6GQLPlayable(d);
    if ([type isEqualToString:@"LocalTrack"] || [S6URIType(uri) isEqualToString:@"local"]) t.playable = NO;
    t.explicitContent = [S6Str(S6Dict(d[@"contentRating"])[@"label"]) isEqualToString:@"EXPLICIT"];
    t.trackNumber = S6Int(d[@"trackNumber"]);
    t.discNumber = S6Int(d[@"discNumber"]);
    t.playcount = [S6Str(d[@"playcount"]) longLongValue];
    if (t.isEpisode) {
        // an episode: its show stands where the album would be, the publisher where the artists would
        NSDictionary *show = S6Dict(S6Dict(d[@"podcastV2"])[@"data"]);
        S6Album *a = [[S6Album alloc] init];
        a.name = S6Str(show[@"name"]) ?: album.name ?: @"";
        a.uri = S6Str(show[@"uri"]) ?: album.uri;
        a.images = S6Arr(S6Dict(d[@"coverArt"])[@"sources"]) ?: S6Arr(S6Dict(show[@"coverArt"])[@"sources"]) ?: album.images;
        t.album = a;
        S6Artist *publisher = [[S6Artist alloc] init];
        publisher.name = S6Str(S6Dict(show[@"publisher"])[@"name"]) ?: a.name;
        t.artists = @[ publisher ];
        t.releaseDate = S6GQLDate(d[@"releaseDate"]);
        return t;
    }
    t.artists = S6GQLArtists(d[@"artists"]);
    NSDictionary *albumData = S6Dict(d[@"albumOfTrack"]);
    t.album = albumData ? [S6Album albumFromGraphQL:albumData] : album;
    if (t.album != album && album && !t.album.images.count) t.album.images = album.images;
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

#pragma mark - Playlist

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

+ (instancetype)playlistFromGraphQL:(NSDictionary *)data
{
    NSDictionary *d = S6Dict(data);
    NSString *uri = S6GQLURI(d);
    if (!uri.length) return nil;
    S6Playlist *p = [[S6Playlist alloc] init];
    p.uri = uri;
    p.playlistId = S6Str(d[@"id"]) ?: S6URIId(uri);
    p.name = S6Str(d[@"name"]) ?: @"";
    p.descriptionText = S6PlainText(S6Str(d[@"description"]));
    NSDictionary *owner = S6Dict(S6Dict(d[@"ownerV2"])[@"data"]);
    p.ownerName = S6Str(owner[@"name"]) ?: S6Str(owner[@"username"]);
    p.ownerId = S6Str(owner[@"username"]) ?: S6Str(owner[@"id"]);
    p.images = S6Arr(S6Dict(S6Arr(S6Dict(d[@"images"])[@"items"]).firstObject)[@"sources"]);
    p.totalTracks = S6Int(S6Dict(d[@"content"])[@"totalCount"]);
    p.followers = S6Int(d[@"followers"]);
    p.editable = S6Bool(S6Dict(d[@"currentUserCapabilities"])[@"canEditItems"]);
    p.saved = S6Bool(d[@"following"]);
    return p;
}

- (NSString *)imageURLForSize:(CGFloat)pixels { return [S6Image urlIn:self.images forSize:pixels]; }

@end

#pragma mark - Show

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

+ (instancetype)showFromGraphQL:(NSDictionary *)data
{
    NSDictionary *d = S6Dict(data);
    NSString *uri = S6GQLURI(d);
    if (!uri.length) return nil;
    S6Show *s = [[S6Show alloc] init];
    s.uri = uri;
    s.showId = S6Str(d[@"id"]) ?: S6URIId(uri);
    s.name = S6Str(d[@"name"]) ?: @"";
    s.publisher = S6Str(S6Dict(d[@"publisher"])[@"name"]);
    s.descriptionText = S6PlainText(S6Str(d[@"description"]));
    s.images = S6Arr(S6Dict(d[@"coverArt"])[@"sources"]);
    s.saved = S6Bool(d[@"saved"]);
    return s;
}

- (NSString *)imageURLForSize:(CGFloat)pixels { return [S6Image urlIn:self.images forSize:pixels]; }

@end

#pragma mark - Any entity

id S6EntityFromGraphQL(NSDictionary *node)
{
    NSDictionary *d = S6Dict(node);
    for (int depth = 0; d && depth < 5; depth++) {
        NSString *type = S6Str(d[@"__typename"]);
        if ([type isEqualToString:@"Track"] || [type isEqualToString:@"Episode"]) return [S6Track trackFromGraphQL:d album:nil];
        if ([type isEqualToString:@"Album"]) return [S6Album albumFromGraphQL:d];
        if ([type isEqualToString:@"Artist"]) return [S6Artist artistFromGraphQL:d];
        if ([type isEqualToString:@"Playlist"]) return [S6Playlist playlistFromGraphQL:d];
        if ([type isEqualToString:@"Podcast"]) return [S6Show showFromGraphQL:d];
        // wrappers: {data: …}, {item: …}, {content: …}, {itemV2: …}, {entity: …}
        NSDictionary *inner = S6Dict(d[@"data"]) ?: S6Dict(d[@"item"]) ?: S6Dict(d[@"content"]) ?: S6Dict(d[@"itemV2"]) ?: S6Dict(d[@"entity"]);
        if (!inner || inner == d) return nil;
        d = inner;
    }
    return nil;
}
