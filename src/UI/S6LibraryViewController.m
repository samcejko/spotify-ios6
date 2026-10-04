#import "S6LibraryViewController.h"
#import "S6Cells.h"
#import "S6Router.h"
#import "S6Theme.h"
#import "S6Models.h"
#import "S6WebAPI.h"
#import "S6Session.h"
#import "S6Utils.h"
#import "S6Common.h"

// Walks the pages of a library list (the state in an object: see the ARC block pitfall)
@interface S6LibraryWalk : NSObject
@property (nonatomic, strong) NSMutableArray *items;
@property (nonatomic) S6LibraryMode mode;
@property (nonatomic, copy) void (^done)(NSArray *items, NSError *error);
@property (nonatomic) BOOL cancelled;
@end
@implementation S6LibraryWalk
@end

static void S6WalkLibrary(S6LibraryWalk *walk, NSString *path)
{
    [S6WebAPI get:path completion:^(id json, NSError *error) {
        if (walk.cancelled) return;
        NSDictionary *page = S6Dict(json);
        if (walk.mode == S6LibraryArtists) page = S6Dict(page[@"artists"]);
        for (id item in S6Arr(page[@"items"])) {
            NSDictionary *d = S6Dict(item);
            id model = nil;
            switch (walk.mode) {
                case S6LibraryPlaylists: model = [S6Playlist playlistFromJSON:d]; break;
                case S6LibraryAlbums: model = [S6Album albumFromJSON:d[@"album"]]; break;
                case S6LibraryArtists: model = [S6Artist artistFromJSON:d]; break;
                case S6LibraryPodcasts: model = [S6Show showFromJSON:d[@"show"]]; break;
            }
            if (model) [walk.items addObject:model];
        }
        NSString *next = S6Str(page[@"next"]);
        if (!error && next.length && walk.items.count < 1000) {
            S6WalkLibrary(walk, next);
            return;
        }
        if (walk.done) walk.done([walk.items copy], walk.items.count ? nil : error);
        walk.done = nil;
    }];
}

static NSString *S6LibraryPath(S6LibraryMode mode)
{
    switch (mode) {
        case S6LibraryPlaylists: return @"/me/playlists?limit=50";
        case S6LibraryAlbums: return @"/me/albums?limit=50";
        case S6LibraryArtists: return @"/me/following?type=artist&limit=50";
        default: return @"/me/shows?limit=50";
    }
}

@interface S6LibraryViewController () <UIAlertViewDelegate>
@property (nonatomic) BOOL switcher;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, strong) S6LibraryWalk *walk;
@property (nonatomic, strong) UISegmentedControl *segments;
@end

@implementation S6LibraryViewController

- (instancetype)initWithMode:(S6LibraryMode)mode switcher:(BOOL)switcher
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _mode = mode;
        _switcher = switcher;
        _items = @[];
    }
    return self;
}

- (NSString *)titleForMode:(S6LibraryMode)mode
{
    switch (mode) {
        case S6LibraryPlaylists: return L(@"Playlists");
        case S6LibraryAlbums: return L(@"Albums");
        case S6LibraryArtists: return L(@"Artists");
        default: return L(@"Podcasts");
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = 68;
    [self.tableView registerClass:[S6MediaCell class] forCellReuseIdentifier:@"media"];
    if (self.switcher) {
        self.segments = [[UISegmentedControl alloc] initWithItems:@[ L(@"Playlists"), L(@"Albums"), L(@"Artists"), L(@"Podcasts") ]];
        self.segments.segmentedControlStyle = UISegmentedControlStyleBar;
        self.segments.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
        self.segments.selectedSegmentIndex = self.mode;
        [self.segments addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
        self.navigationItem.titleView = self.segments;
        self.title = L(@"Your Library");
    } else {
        self.title = [self titleForMode:self.mode];
    }
    [self updateAddButton];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:S6LibraryDidChangeNotification object:nil];
}

- (void)updateAddButton
{
    self.navigationItem.rightBarButtonItem = self.mode == S6LibraryPlaylists ?
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(newPlaylist)] : nil;
}

- (void)segmentChanged
{
    self.mode = (S6LibraryMode)self.segments.selectedSegmentIndex;
    self.items = @[];
    [self.tableView reloadData];
    [self updateAddButton];
    [self load];
}

- (void)setMode:(S6LibraryMode)mode
{
    _mode = mode;
    if (!self.switcher && self.isViewLoaded) self.title = [self titleForMode:mode];
}

- (void)load
{
    self.walk.cancelled = YES;
    [self startLoading];
    S6LibraryWalk *walk = [[S6LibraryWalk alloc] init];
    walk.items = [NSMutableArray array];
    walk.mode = self.mode;
    __weak S6LibraryViewController *weakSelf = self;
    S6LibraryMode mode = self.mode;
    walk.done = ^(NSArray *items, NSError *error) {
        S6LibraryViewController *me = weakSelf;
        if (!me || me.mode != mode) return;
        me.items = items;
        NSString *empty = mode == S6LibraryAlbums ? L(@"Albums you save show up here.") : mode == S6LibraryArtists ? L(@"Artists you follow show up here.") :
                          mode == S6LibraryPodcasts ? L(@"Podcasts you follow show up here.") : L(@"Nothing here yet.");
        [me finishLoadingWithError:error empty:!items.count && mode != S6LibraryPlaylists emptyMessage:empty];
    };
    self.walk = walk;
    S6WalkLibrary(walk, S6LibraryPath(self.mode));
}

- (void)newPlaylist
{
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:L(@"New playlist") message:nil delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Create"), nil];
    a.alertViewStyle = UIAlertViewStylePlainTextInput;
    [a textFieldAtIndex:0].placeholder = L(@"Playlist name");
    [a show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex) return;
    NSString *name = [[alertView textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return;
    [S6WebAPI createPlaylistNamed:name completion:^(S6Playlist *playlist, NSError *error) {
        if (!playlist) { [S6Router toast:error.localizedDescription]; return; }
        [S6Router openPlaylist:playlist];
    }];
}

#pragma mark - Table

- (BOOL)hasLikedRow { return self.mode == S6LibraryPlaylists; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.items.count + ([self hasLikedRow] ? 1 : 0);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    S6MediaCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media" forIndexPath:indexPath];
    NSInteger row = indexPath.row;
    if ([self hasLikedRow]) {
        if (row == 0) {
            cell.round = NO;
            [cell showTitle:L(@"Liked Songs") subtitle:L(@"Playlist") imageURL:nil];
            cell.art.image = [[S6Theme shared] icon:S6IconHeartFilled size:52 color:[[S6Theme shared] accentColor]];
            cell.art.contentMode = UIViewContentModeCenter;
            return cell;
        }
        row--;
    }
    cell.art.contentMode = UIViewContentModeScaleAspectFill;
    id item = self.items[(NSUInteger)row];
    cell.round = [item isKindOfClass:[S6Artist class]];
    if ([item isKindOfClass:[S6Playlist class]]) {
        S6Playlist *p = item;
        [cell showTitle:p.name subtitle:[NSString stringWithFormat:@"%@ · %@", [NSString stringWithFormat:L(@"by %@"), p.ownerName ?: @""],
                                         [NSString stringWithFormat:L(@"%lu songs"), (unsigned long)p.totalTracks]] imageURL:[p imageURLForSize:120]];
    } else if ([item isKindOfClass:[S6Album class]]) {
        [cell showTitle:[item name] subtitle:[item artistNames] imageURL:[item imageURLForSize:120]];
    } else if ([item isKindOfClass:[S6Artist class]]) {
        [cell showTitle:[item name] subtitle:L(@"Artist") imageURL:[item imageURLForSize:120]];
    } else {
        [cell showTitle:[item name] subtitle:[item publisher] imageURL:[item imageURLForSize:120]];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger row = indexPath.row;
    if ([self hasLikedRow]) {
        if (row == 0) { [S6Router openLikedSongs]; return; }
        row--;
    }
    id item = self.items[(NSUInteger)row];
    if ([item isKindOfClass:[S6Playlist class]]) [S6Router openPlaylist:item];
    else if ([item isKindOfClass:[S6Album class]]) [S6Router openAlbum:item];
    else if ([item isKindOfClass:[S6Artist class]]) [S6Router openArtist:item];
    else if ([item isKindOfClass:[S6Show class]]) [S6Router openShow:item];
}

@end

@interface S6PlaylistPickerViewController ()
@property (nonatomic, copy) void (^completion)(id playlist);
@property (nonatomic, strong) NSArray *playlists;
@end

@implementation S6PlaylistPickerViewController

- (instancetype)initWithCompletion:(void (^)(id))completion
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _completion = [completion copy];
        _playlists = @[];
        self.title = L(@"Add to playlist");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = 68;
    [self.tableView registerClass:[S6MediaCell class] forCellReuseIdentifier:@"media"];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
}

- (void)cancel
{
    [self dismissViewControllerAnimated:YES completion:nil];
    if (self.completion) self.completion(nil);
    self.completion = nil;
}

- (void)load
{
    [self startLoading];
    S6LibraryWalk *walk = [[S6LibraryWalk alloc] init];
    walk.items = [NSMutableArray array];
    walk.mode = S6LibraryPlaylists;
    __weak S6PlaylistPickerViewController *weakSelf = self;
    NSString *me = [S6Session shared].username;
    walk.done = ^(NSArray *items, NSError *error) {
        NSMutableArray *mine = [NSMutableArray array];
        for (S6Playlist *p in items) if ([p.ownerId isEqualToString:me] || p.collaborative) [mine addObject:p];
        weakSelf.playlists = mine;
        [weakSelf finishLoadingWithError:error empty:!mine.count emptyMessage:L(@"You have no playlists of your own yet.")];
    };
    S6WalkLibrary(walk, S6LibraryPath(S6LibraryPlaylists));
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.playlists.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    S6MediaCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media" forIndexPath:indexPath];
    S6Playlist *p = self.playlists[(NSUInteger)indexPath.row];
    cell.accessoryType = UITableViewCellAccessoryNone;
    [cell showTitle:p.name subtitle:[NSString stringWithFormat:L(@"%lu songs"), (unsigned long)p.totalTracks] imageURL:[p imageURLForSize:120]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    S6Playlist *p = self.playlists[(NSUInteger)indexPath.row];
    void (^completion)(id) = self.completion;
    self.completion = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
    if (completion) completion(p);
}

@end
