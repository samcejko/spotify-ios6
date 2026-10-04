#import "S6HomeViewController.h"
#import "S6Cells.h"
#import "S6Router.h"
#import "S6Theme.h"
#import "S6Models.h"
#import "S6WebAPI.h"
#import "S6Player.h"
#import "S6Session.h"
#import "S6Common.h"

@interface S6HomeShelf : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray *items;        // card dictionaries
@property (nonatomic) NSInteger order;
@end
@implementation S6HomeShelf
@end

@interface S6HomeViewController ()
@property (nonatomic, strong) NSMutableArray *shelves;    // S6HomeShelf, sorted by order
@property (nonatomic) NSInteger pending;
@property (nonatomic, strong) NSError *firstError;
@property (nonatomic, strong) UILabel *greeting;
@end

@implementation S6HomeViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _shelves = [NSMutableArray array];
        self.title = L(@"Home");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.tableView registerClass:[S6ShelfCell class] forCellReuseIdentifier:@"shelf"];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 64)];
    self.greeting = [[UILabel alloc] initWithFrame:CGRectMake(14, 16, self.view.bounds.size.width - 28, 36)];
    self.greeting.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.greeting.font = [[S6Theme shared] headerFont];
    self.greeting.textColor = [[S6Theme shared] primaryTextColor];
    self.greeting.backgroundColor = [UIColor clearColor];
    [header addSubview:self.greeting];
    self.tableView.tableHeaderView = header;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionChanged) name:S6SessionStateDidChangeNotification object:nil];
}

- (void)sessionChanged
{
    if ([S6Session shared].state == S6SessionStateReady && !self.shelves.count && !self.loading) [self reload];
}

- (NSString *)greetingText
{
    NSDateComponents *c = [[NSCalendar currentCalendar] components:NSHourCalendarUnit fromDate:[NSDate date]];
    if (c.hour >= 4 && c.hour < 12) return L(@"Good morning");
    if (c.hour >= 12 && c.hour < 18) return L(@"Good afternoon");
    return L(@"Good evening");
}

- (CGFloat)cardWidth { return S6IsPad() ? 150 : 120; }

- (void)addShelf:(NSString *)title items:(NSArray *)items order:(NSInteger)order
{
    if (!items.count) return;
    S6HomeShelf *s = [[S6HomeShelf alloc] init];
    s.title = title;
    s.items = items;
    s.order = order;
    [self.shelves addObject:s];
    [self.shelves sortUsingComparator:^NSComparisonResult(S6HomeShelf *a, S6HomeShelf *b) { return [@(a.order) compare:@(b.order)]; }];
    [self.tableView reloadData];
}

static NSDictionary *S6AlbumCard(S6Album *a)
{
    return @{ @"title": a.name ?: @"", @"subtitle": [a artistNames] ?: @"", @"image": [a imageURLForSize:300] ?: @"", @"item": a };
}

static NSDictionary *S6PlaylistCard(S6Playlist *p)
{
    NSString *sub = p.ownerName.length ? [NSString stringWithFormat:L(@"by %@"), p.ownerName] : @"";
    return @{ @"title": p.name ?: @"", @"subtitle": sub, @"image": [p imageURLForSize:300] ?: @"", @"item": p };
}

- (void)load
{
    self.greeting.text = [self greetingText];
    [self.shelves removeAllObjects];
    self.firstError = nil;
    [self startLoading];
    self.pending = 6;
    __weak S6HomeViewController *weakSelf = self;

    [S6WebAPI get:@"/me/player/recently-played?limit=50" completion:^(id json, NSError *error) {
        NSMutableArray *cards = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (id item in S6Arr(S6Dict(json)[@"items"])) {
            S6Track *t = [S6Track trackFromJSON:S6Dict(item)[@"track"]];
            if (!t.album.albumId.length || [seen containsObject:t.album.albumId]) continue;
            [seen addObject:t.album.albumId];
            [cards addObject:S6AlbumCard(t.album)];
            if (cards.count >= 20) break;
        }
        [weakSelf addShelf:L(@"Recently played") items:cards order:0];
        [weakSelf part:error];
    }];
    [S6WebAPI get:@"/me/top/artists?limit=20&time_range=short_term" completion:^(id json, NSError *error) {
        NSMutableArray *cards = [NSMutableArray array];
        for (id a in S6Arr(S6Dict(json)[@"items"])) {
            S6Artist *artist = [S6Artist artistFromJSON:a];
            if (artist) [cards addObject:@{ @"title": artist.name ?: @"", @"subtitle": L(@"Artist"), @"image": [artist imageURLForSize:300] ?: @"", @"round": @YES, @"item": artist }];
        }
        [weakSelf addShelf:L(@"Your top artists") items:cards order:1];
        [weakSelf part:error];
    }];
    [S6WebAPI get:@"/me/top/tracks?limit=30&time_range=short_term" completion:^(id json, NSError *error) {
        NSMutableArray *tracks = [NSMutableArray array];
        for (id t in S6Arr(S6Dict(json)[@"items"])) { S6Track *x = [S6Track trackFromJSON:t]; if (x.uri.length) [tracks addObject:x]; }
        NSMutableArray *cards = [NSMutableArray array];
        for (S6Track *t in tracks) {
            [cards addObject:@{ @"title": t.name ?: @"", @"subtitle": [t artistNames] ?: @"", @"image": [t imageURLForSize:300] ?: @"",
                                @"item": @{ @"tracks": tracks, @"index": @(cards.count) } }];
        }
        [weakSelf addShelf:L(@"Your top songs") items:cards order:2];
        [weakSelf part:error];
    }];
    [S6WebAPI get:@"/me/playlists?limit=30" completion:^(id json, NSError *error) {
        NSMutableArray *cards = [NSMutableArray array];
        for (id p in S6Arr(S6Dict(json)[@"items"])) { S6Playlist *x = [S6Playlist playlistFromJSON:p]; if (x.playlistId) [cards addObject:S6PlaylistCard(x)]; }
        [weakSelf addShelf:L(@"Your playlists") items:cards order:3];
        [weakSelf part:error];
    }];
    [S6WebAPI get:@"/browse/new-releases?limit=30" completion:^(id json, NSError *error) {
        NSMutableArray *cards = [NSMutableArray array];
        for (id a in S6Arr(S6Dict(S6Dict(json)[@"albums"])[@"items"])) { S6Album *x = [S6Album albumFromJSON:a]; if (x.albumId) [cards addObject:S6AlbumCard(x)]; }
        [weakSelf addShelf:L(@"New releases") items:cards order:4];
        [weakSelf part:nil];
    }];
    [S6WebAPI get:@"/browse/featured-playlists?limit=30" completion:^(id json, NSError *error) {
        NSMutableArray *cards = [NSMutableArray array];
        for (id p in S6Arr(S6Dict(S6Dict(json)[@"playlists"])[@"items"])) { S6Playlist *x = [S6Playlist playlistFromJSON:p]; if (x.playlistId) [cards addObject:S6PlaylistCard(x)]; }
        NSString *message = S6Str(S6Dict(json)[@"message"]);
        [weakSelf addShelf:message.length ? message : L(@"Featured playlists") items:cards order:5];
        [weakSelf part:nil];
    }];
}

- (void)part:(NSError *)error
{
    if (error && !self.firstError) self.firstError = error;
    if (--self.pending > 0) return;
    [self finishLoadingWithError:self.shelves.count ? nil : self.firstError empty:!self.shelves.count emptyMessage:L(@"Nothing here yet.")];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)self.shelves.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [S6ShelfCell heightForCardWidth:[self cardWidth]];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    return S6SectionHeader([self.shelves[(NSUInteger)section] title], tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return 26; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    S6ShelfCell *cell = [tableView dequeueReusableCellWithIdentifier:@"shelf" forIndexPath:indexPath];
    [cell showItems:[self.shelves[(NSUInteger)indexPath.section] items] cardWidth:[self cardWidth]];
    cell.onSelect = ^(id item) {
        if ([item isKindOfClass:[S6Album class]]) [S6Router openAlbum:item];
        else if ([item isKindOfClass:[S6Playlist class]]) [S6Router openPlaylist:item];
        else if ([item isKindOfClass:[S6Artist class]]) [S6Router openArtist:item];
        else if ([item isKindOfClass:[NSDictionary class]]) {
            NSArray *tracks = item[@"tracks"];
            [[S6Player shared] playTracks:tracks startingAt:[item[@"index"] unsignedIntegerValue] contextURI:nil contextName:L(@"Your top songs")];
        }
    };
    return cell;
}

@end
