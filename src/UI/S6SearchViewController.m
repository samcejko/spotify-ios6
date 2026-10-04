#import "S6SearchViewController.h"
#import "S6Cells.h"
#import "S6Router.h"
#import "S6Theme.h"
#import "S6Models.h"
#import "S6WebAPI.h"
#import "S6Player.h"
#import "S6Settings.h"
#import "S6Utils.h"
#import "S6Common.h"

enum { S6SearchSongs, S6SearchArtists, S6SearchAlbums, S6SearchPlaylists, S6SearchShows, S6SearchSectionCount };

@interface S6SearchViewController () <UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, strong) NSArray *songs, *artists, *albums, *playlists, *shows;
@property (nonatomic, strong) NSArray *categories;   // NSDictionary {id, name, icon}
@property (nonatomic, strong) S6APITask *task;
@property (nonatomic, strong) NSTimer *debounce;
@end

@implementation S6SearchViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        self.title = L(@"Search");
        self.refreshable = NO;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.tableView registerClass:[S6TrackCell class] forCellReuseIdentifier:@"track"];
    [self.tableView registerClass:[S6MediaCell class] forCellReuseIdentifier:@"media"];
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.placeholder = L(@"Artists, songs or podcasts");
    self.searchBar.delegate = self;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    [[S6Theme shared] applyToSearchBar:self.searchBar];
    self.tableView.tableHeaderView = self.searchBar;
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    [self.searchBar resignFirstResponder];
}

- (void)focusSearchField { [self.searchBar becomeFirstResponder]; }

- (void)searchFor:(NSString *)query
{
    self.searchBar.text = query;
    self.query = query;
    [self load];
}

- (BOOL)searching { return self.query.length > 0; }

- (void)load
{
    [self.task cancel];
    if (![self searching]) {
        self.songs = self.artists = self.albums = self.playlists = self.shows = nil;
        [self finishLoadingWithError:nil empty:NO emptyMessage:nil];
        if (!self.categories) [self loadCategories];
        return;
    }
    [self startLoading];
    NSString *q = self.query;
    __weak S6SearchViewController *weakSelf = self;
    self.task = [S6WebAPI get:[NSString stringWithFormat:@"/search?q=%@&type=track,artist,album,playlist,show&limit=20&market=from_token", [S6Utils urlEncode:q]]
                   completion:^(id json, NSError *error) {
        S6SearchViewController *me = weakSelf;
        if (![q isEqualToString:me.query]) return;
        NSDictionary *d = S6Dict(json);
        NSMutableArray *songs = [NSMutableArray array], *artists = [NSMutableArray array], *albums = [NSMutableArray array];
        NSMutableArray *playlists = [NSMutableArray array], *shows = [NSMutableArray array];
        for (id t in S6Arr(S6Dict(d[@"tracks"])[@"items"])) { S6Track *x = [S6Track trackFromJSON:t]; if (x.uri.length) [songs addObject:x]; }
        for (id a in S6Arr(S6Dict(d[@"artists"])[@"items"])) { S6Artist *x = [S6Artist artistFromJSON:a]; if (x.artistId) [artists addObject:x]; }
        for (id a in S6Arr(S6Dict(d[@"albums"])[@"items"])) { S6Album *x = [S6Album albumFromJSON:a]; if (x.albumId) [albums addObject:x]; }
        for (id p in S6Arr(S6Dict(d[@"playlists"])[@"items"])) { S6Playlist *x = [S6Playlist playlistFromJSON:p]; if (x.playlistId) [playlists addObject:x]; }
        for (id s in S6Arr(S6Dict(d[@"shows"])[@"items"])) { S6Show *x = [S6Show showFromJSON:s]; if (x.showId) [shows addObject:x]; }
        me.songs = songs; me.artists = artists; me.albums = albums; me.playlists = playlists; me.shows = shows;
        BOOL empty = !songs.count && !artists.count && !albums.count && !playlists.count && !shows.count;
        [me finishLoadingWithError:empty ? error : nil empty:empty emptyMessage:[NSString stringWithFormat:L(@"Nothing found for \"%@\"."), q]];
    }];
}

- (void)loadCategories
{
    __weak S6SearchViewController *weakSelf = self;
    NSString *locale = [[NSLocale preferredLanguages].firstObject ?: @"en" stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    [S6WebAPI get:[NSString stringWithFormat:@"/browse/categories?limit=50&locale=%@", locale] completion:^(id json, NSError *error) {
        NSMutableArray *list = [NSMutableArray array];
        for (id c in S6Arr(S6Dict(S6Dict(json)[@"categories"])[@"items"])) {
            NSDictionary *d = S6Dict(c);
            if (!S6Str(d[@"id"]).length) continue;
            [list addObject:@{ @"id": S6Str(d[@"id"]), @"name": S6Str(d[@"name"]) ?: @"", @"icon": [S6Image urlIn:d[@"icons"] forSize:100] ?: @"" }];
        }
        weakSelf.categories = list;
        if (![weakSelf searching]) [weakSelf.tableView reloadData];
    }];
}

#pragma mark - Search bar

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    [self.debounce invalidate];
    self.debounce = [NSTimer scheduledTimerWithTimeInterval:0.45 target:self selector:@selector(debounced) userInfo:nil repeats:NO];
}

- (void)debounced
{
    NSString *q = [self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([q isEqualToString:self.query ?: @""]) return;
    self.query = q;
    [self load];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
    [self debounced];
    if (self.query.length) [S6Settings addRecentSearch:self.query];
}

#pragma mark - Table

- (NSArray *)itemsIn:(NSInteger)section
{
    switch (section) {
        case S6SearchSongs: return self.songs;
        case S6SearchArtists: return self.artists;
        case S6SearchAlbums: return self.albums;
        case S6SearchPlaylists: return self.playlists;
        default: return self.shows;
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return [self searching] ? S6SearchSectionCount : 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (![self searching]) return section == 0 ? (NSInteger)[S6Settings recentSearches].count : (NSInteger)self.categories.count;
    NSInteger n = (NSInteger)[self itemsIn:section].count;
    return section == S6SearchSongs ? MIN(n, 10) : MIN(n, 8);
}

- (NSString *)titleFor:(NSInteger)section
{
    if (![self searching]) return section == 0 ? L(@"Recent searches") : L(@"Browse all");
    switch (section) {
        case S6SearchSongs: return L(@"Songs");
        case S6SearchArtists: return L(@"Artists");
        case S6SearchAlbums: return L(@"Albums");
        case S6SearchPlaylists: return L(@"Playlists");
        default: return L(@"Podcasts");
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (![self tableView:tableView numberOfRowsInSection:section]) return nil;
    return S6SectionHeader([self titleFor:section], tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return [self tableView:tableView numberOfRowsInSection:section] ? 26 : 0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (![self searching]) return indexPath.section == 0 ? 44 : 64;
    return indexPath.section == S6SearchSongs ? 56 : 68;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    S6Theme *theme = [S6Theme shared];
    if (![self searching]) {
        if (indexPath.section == 0) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"recent"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"recent"];
            [theme styleCell:cell];
            cell.textLabel.text = [S6Settings recentSearches][(NSUInteger)indexPath.row];
            cell.imageView.image = [theme icon:S6IconClock size:18 color:[theme secondaryTextColor]];
            return cell;
        }
        S6MediaCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media" forIndexPath:indexPath];
        NSDictionary *c = self.categories[(NSUInteger)indexPath.row];
        cell.round = NO;
        [cell showTitle:c[@"name"] subtitle:nil imageURL:c[@"icon"]];
        return cell;
    }
    id item = [self itemsIn:indexPath.section][(NSUInteger)indexPath.row];
    if (indexPath.section == S6SearchSongs) {
        S6TrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
        cell.showsArt = YES;
        [cell showTrack:item number:0];
        [cell.moreButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.moreButton addTarget:self action:@selector(moreTapped:) forControlEvents:UIControlEventTouchUpInside];
        cell.moreButton.tag = indexPath.row;
        return cell;
    }
    S6MediaCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media" forIndexPath:indexPath];
    cell.round = indexPath.section == S6SearchArtists;
    if ([item isKindOfClass:[S6Artist class]]) [cell showTitle:[item name] subtitle:L(@"Artist") imageURL:[item imageURLForSize:120]];
    else if ([item isKindOfClass:[S6Album class]]) [cell showTitle:[item name] subtitle:[NSString stringWithFormat:@"%@ · %@", L(@"Album"), [item artistNames]] imageURL:[item imageURLForSize:120]];
    else if ([item isKindOfClass:[S6Playlist class]]) [cell showTitle:[item name] subtitle:[NSString stringWithFormat:L(@"by %@"), [item ownerName] ?: @""] imageURL:[item imageURLForSize:120]];
    else [cell showTitle:[item name] subtitle:[item publisher] imageURL:[item imageURLForSize:120]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (![self searching]) {
        if (indexPath.section == 0) {
            [self searchFor:[S6Settings recentSearches][(NSUInteger)indexPath.row]];
            return;
        }
        NSDictionary *c = self.categories[(NSUInteger)indexPath.row];
        [S6Router push:[[S6CategoryViewController alloc] initWithCategoryId:c[@"id"] name:c[@"name"]]];
        return;
    }
    if (self.query.length) [S6Settings addRecentSearch:self.query];
    id item = [self itemsIn:indexPath.section][(NSUInteger)indexPath.row];
    if (indexPath.section == S6SearchSongs) {
        [[S6Player shared] playTracks:@[ item ] startingAt:0 contextURI:[item uri] contextName:[item name]];
        return;
    }
    if ([item isKindOfClass:[S6Artist class]]) [S6Router openArtist:item];
    else if ([item isKindOfClass:[S6Album class]]) [S6Router openAlbum:item];
    else if ([item isKindOfClass:[S6Playlist class]]) [S6Router openPlaylist:item];
    else if ([item isKindOfClass:[S6Show class]]) [S6Router openShow:item];
}

- (void)moreTapped:(UIButton *)sender
{
    if (sender.tag < (NSInteger)self.songs.count) [S6Router showActionsForTrack:self.songs[(NSUInteger)sender.tag] fromView:sender inController:self playlist:nil];
}

@end

@interface S6CategoryViewController ()
@property (nonatomic, copy) NSString *categoryId;
@property (nonatomic, strong) NSArray *playlists;
@end

@implementation S6CategoryViewController

- (instancetype)initWithCategoryId:(NSString *)categoryId name:(NSString *)name
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _categoryId = [categoryId copy];
        _playlists = @[];
        self.title = name;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = 68;
    [self.tableView registerClass:[S6MediaCell class] forCellReuseIdentifier:@"media"];
}

- (void)load
{
    [self startLoading];
    __weak S6CategoryViewController *weakSelf = self;
    [S6WebAPI get:[NSString stringWithFormat:@"/browse/categories/%@/playlists?limit=50", self.categoryId] completion:^(id json, NSError *error) {
        NSMutableArray *list = [NSMutableArray array];
        for (id p in S6Arr(S6Dict(S6Dict(json)[@"playlists"])[@"items"])) { S6Playlist *x = [S6Playlist playlistFromJSON:p]; if (x.playlistId) [list addObject:x]; }
        weakSelf.playlists = list;
        [weakSelf finishLoadingWithError:list.count ? nil : error empty:!list.count emptyMessage:L(@"Nothing here.")];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.playlists.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    S6MediaCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media" forIndexPath:indexPath];
    S6Playlist *p = self.playlists[(NSUInteger)indexPath.row];
    [cell showTitle:p.name subtitle:[NSString stringWithFormat:L(@"by %@"), p.ownerName ?: @""] imageURL:[p imageURLForSize:120]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [S6Router openPlaylist:self.playlists[(NSUInteger)indexPath.row]];
}

@end
