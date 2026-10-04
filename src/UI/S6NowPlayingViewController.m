#import "S6NowPlayingViewController.h"
#import "S6Player.h"
#import "S6Router.h"
#import "S6Cells.h"
#import "S6Theme.h"
#import "S6Models.h"
#import "S6WebAPI.h"
#import "S6SpClient.h"
#import "S6ImageLoader.h"
#import "S6Utils.h"
#import "S6Common.h"
#import <MediaPlayer/MediaPlayer.h>

#pragma mark - Lyrics

@interface S6LyricsViewController : UITableViewController
@property (nonatomic, copy) NSString *trackId;
@property (nonatomic, strong) NSArray *lines;       // NSDictionary {ms, text}
@property (nonatomic) BOOL synced;
@property (nonatomic) NSInteger currentLine;
@property (nonatomic, copy) NSString *message;
- (void)showTrack:(S6Track *)track;
- (void)tick;
@end

@implementation S6LyricsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.contentInset = UIEdgeInsetsMake(40, 0, 120, 0);
    self.currentLine = -1;
}

- (void)showTrack:(S6Track *)track
{
    if ([track.trackId isEqualToString:self.trackId]) return;
    self.trackId = track.trackId;
    self.lines = @[];
    self.currentLine = -1;
    self.message = L(@"Loading lyrics…");
    [self.tableView reloadData];
    if (!track.trackId.length || track.isEpisode) { self.message = L(@"No lyrics for this song."); [self.tableView reloadData]; return; }
    NSString *tid = track.trackId;
    [S6SpClient lyricsForTrack:tid completion:^(NSDictionary *json, NSError *error) {
        if (![tid isEqualToString:self.trackId]) return;
        NSDictionary *lyrics = S6Dict(json[@"lyrics"]);
        NSMutableArray *lines = [NSMutableArray array];
        for (id l in S6Arr(lyrics[@"lines"])) {
            NSDictionary *d = S6Dict(l);
            NSString *words = S6Str(d[@"words"]) ?: @"";
            if ([words isEqualToString:@"♪"]) words = @"♪";
            [lines addObject:@{ @"ms": @(S6Int(d[@"startTimeMs"])), @"text": [S6Utils displayText:words] ?: @"" }];
        }
        self.synced = [S6Str(lyrics[@"syncType"]) isEqualToString:@"LINE_SYNCED"];
        self.lines = lines;
        self.message = lines.count ? nil : (error.code == 404 || !error ? L(@"No lyrics for this song.") : error.localizedDescription);
        [self.tableView reloadData];
        [self tick];
    }];
}

- (void)tick
{
    if (!self.synced || !self.lines.count) return;
    NSInteger ms = [S6Player shared].positionMs + 300;
    NSInteger line = -1;
    for (NSUInteger i = 0; i < self.lines.count; i++) {
        if ([self.lines[i][@"ms"] integerValue] <= ms) line = (NSInteger)i; else break;
    }
    if (line == self.currentLine) return;
    NSInteger old = self.currentLine;
    self.currentLine = line;
    NSMutableArray *rows = [NSMutableArray array];
    if (old >= 0 && old < (NSInteger)self.lines.count) [rows addObject:[NSIndexPath indexPathForRow:old inSection:0]];
    if (line >= 0) [rows addObject:[NSIndexPath indexPathForRow:line inSection:0]];
    [self.tableView reloadRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationNone];
    if (line >= 0 && !self.tableView.isDragging && !self.tableView.isDecelerating) {
        [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:line inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    }
}

- (UIFont *)lineFont { return [UIFont fontWithName:@"HelveticaNeue-Bold" size:S6IsPad() ? 24 : 19] ?: [UIFont boldSystemFontOfSize:20]; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.message ? 1 : (NSInteger)self.lines.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.message) return 80;
    NSString *text = self.lines[(NSUInteger)indexPath.row][@"text"];
    CGSize s = [text.length ? text : @" " sizeWithFont:[self lineFont] constrainedToSize:CGSizeMake(tableView.bounds.size.width - 40, 400) lineBreakMode:NSLineBreakByWordWrapping];
    return ceilf(s.height) + 14;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"line"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"line"];
    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [self lineFont];
    if (self.message) {
        cell.textLabel.text = self.message;
        cell.textLabel.textColor = [[S6Theme shared] secondaryTextColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        return cell;
    }
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    cell.textLabel.text = self.lines[(NSUInteger)indexPath.row][@"text"];
    BOOL current = indexPath.row == self.currentLine;
    BOOL past = self.synced && indexPath.row < self.currentLine;
    cell.textLabel.textColor = current ? [UIColor whiteColor] : (past ? [UIColor colorWithWhite:1 alpha:0.55] : [UIColor colorWithWhite:1 alpha:self.synced ? 0.3 : 0.85]);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!self.synced || self.message) return;
    [[S6Player shared] seekToMs:[self.lines[(NSUInteger)indexPath.row][@"ms"] integerValue]];
}

@end

#pragma mark - Queue

enum { S6QueueNow, S6QueueUser, S6QueueNext, S6QueueSectionCount };

@interface S6QueueViewController ()
@property (nonatomic, strong) NSArray *upcoming;
- (void)refresh;
@end

@implementation S6QueueViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) self.title = L(@"Queue");
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    self.tableView.rowHeight = 56;
    [self.tableView registerClass:[S6TrackCell class] forCellReuseIdentifier:@"track"];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:S6PlayerDidChangeNotification object:nil];
    [self refresh];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)refresh
{
    self.upcoming = [[S6Player shared] upcomingTracks:50];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return S6QueueSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    S6Player *p = [S6Player shared];
    if (section == S6QueueNow) return p.currentTrack ? 1 : 0;
    if (section == S6QueueUser) return (NSInteger)p.userQueue.count;
    return (NSInteger)self.upcoming.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (![self tableView:tableView numberOfRowsInSection:section]) return nil;
    NSString *title = section == S6QueueNow ? L(@"Now playing") : section == S6QueueUser ? L(@"Next in queue") :
                      [NSString stringWithFormat:L(@"Next from: %@"), [S6Player shared].contextName ?: @""];
    return S6SectionHeader(title, tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return [self tableView:tableView numberOfRowsInSection:section] ? 26 : 0;
}

- (S6Track *)trackAt:(NSIndexPath *)ip
{
    S6Player *p = [S6Player shared];
    if (ip.section == S6QueueNow) return p.currentTrack;
    if (ip.section == S6QueueUser) return p.userQueue[(NSUInteger)ip.row];
    return self.upcoming[(NSUInteger)ip.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    S6TrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
    cell.showsArt = YES;
    [cell showTrack:[self trackAt:indexPath] number:0];
    cell.moreButton.hidden = YES;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return indexPath.section == S6QueueUser; }

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete) [[S6Player shared] removeFromQueueAtIndex:(NSUInteger)indexPath.row];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath { return L(@"Remove"); }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end

#pragma mark - Now playing

@interface S6NowPlayingViewController ()
@property (nonatomic, strong) UIImageView *backdrop;
@property (nonatomic, strong) UIView *dim;
@property (nonatomic, strong) S6ImageView *art;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UILabel *contextLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *artistButton;
@property (nonatomic, strong) UIButton *heartButton;
@property (nonatomic, strong) UISlider *progress;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *remainingLabel;
@property (nonatomic, strong) UILabel *formatLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *repeatButton;
@property (nonatomic, strong) UIButton *lyricsButton;
@property (nonatomic, strong) UIButton *queueButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) MPVolumeView *volume;
@property (nonatomic, strong) S6LyricsViewController *lyrics;
@property (nonatomic, strong) S6QueueViewController *queue;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL scrubbing;
@property (nonatomic) BOOL liked;
@property (nonatomic, copy) NSString *shownURI;
@property (nonatomic, copy) NSString *backdropURL;
@end

@implementation S6NowPlayingViewController

- (UIButton *)button:(S6Icon)icon size:(CGFloat)size action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setImage:[[S6Theme shared] icon:icon size:size] forState:UIControlStateNormal];
    b.showsTouchWhenHighlighted = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    return b;
}

- (UILabel *)label:(UIFont *)font color:(UIColor *)color
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.font = font;
    l.textColor = color;
    l.backgroundColor = [UIColor clearColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
    l.shadowOffset = CGSizeMake(0, 1);
    [self.view addSubview:l];
    return l;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    S6Theme *theme = [S6Theme shared];
    self.view.backgroundColor = [theme plainBackgroundColor];
    self.backdrop = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backdrop.contentMode = UIViewContentModeScaleAspectFill;
    self.backdrop.clipsToBounds = YES;
    self.backdrop.alpha = 0.35;
    [self.view addSubview:self.backdrop];
    self.dim = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:self.dim];

    self.art = [[S6ImageView alloc] initWithFrame:CGRectZero];
    self.art.contentMode = UIViewContentModeScaleAspectFill;
    self.art.clipsToBounds = YES;
    self.art.maxPixels = 1024;
    [self.view addSubview:self.art];

    self.lyrics = [[S6LyricsViewController alloc] initWithStyle:UITableViewStylePlain];
    [self addChildViewController:self.lyrics];
    [self.view addSubview:self.lyrics.view];
    [self.lyrics didMoveToParentViewController:self];
    self.queue = [[S6QueueViewController alloc] init];
    [self addChildViewController:self.queue];
    [self.view addSubview:self.queue.view];
    [self.queue didMoveToParentViewController:self];

    self.closeButton = [self button:S6IconChevronDown size:24 action:@selector(close)];
    self.closeButton.accessibilityLabel = L(@"Close");
    self.moreButton = [self button:S6IconMore size:22 action:@selector(more)];
    self.contextLabel = [self label:[theme sectionFont] color:[theme secondaryTextColor]];
    self.contextLabel.numberOfLines = 2;
    self.titleLabel = [self label:[UIFont fontWithName:@"HelveticaNeue-Bold" size:S6IsPad() ? 24 : 19] ?: [UIFont boldSystemFontOfSize:20] color:[UIColor whiteColor]];
    self.artistButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.artistButton.titleLabel.font = [UIFont fontWithName:@"HelveticaNeue" size:S6IsPad() ? 17 : 15] ?: [UIFont systemFontOfSize:16];
    [self.artistButton setTitleColor:[theme secondaryTextColor] forState:UIControlStateNormal];
    [self.artistButton setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
    [self.artistButton addTarget:self action:@selector(openArtist) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.artistButton];
    self.heartButton = [self button:S6IconHeart size:24 action:@selector(toggleLike)];
    self.progress = [[UISlider alloc] initWithFrame:CGRectZero];
    [self.progress addTarget:self action:@selector(scrubStarted) forControlEvents:UIControlEventTouchDown];
    [self.progress addTarget:self action:@selector(scrubEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.progress addTarget:self action:@selector(scrubMoved) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.progress];
    self.elapsedLabel = [self label:[UIFont fontWithName:@"HelveticaNeue" size:12] ?: [UIFont systemFontOfSize:12] color:[theme secondaryTextColor]];
    self.elapsedLabel.textAlignment = NSTextAlignmentLeft;
    self.remainingLabel = [self label:[UIFont fontWithName:@"HelveticaNeue" size:12] ?: [UIFont systemFontOfSize:12] color:[theme secondaryTextColor]];
    self.remainingLabel.textAlignment = NSTextAlignmentRight;
    self.formatLabel = [self label:[UIFont fontWithName:@"HelveticaNeue" size:11] ?: [UIFont systemFontOfSize:11] color:[theme tertiaryTextColor]];
    self.playButton = [self button:S6IconPlay size:54 action:@selector(togglePlay)];
    self.previousButton = [self button:S6IconPrevious size:30 action:@selector(previous)];
    self.nextButton = [self button:S6IconNext size:30 action:@selector(next)];
    self.shuffleButton = [self button:S6IconShuffle size:24 action:@selector(toggleShuffle)];
    self.repeatButton = [self button:S6IconRepeat size:24 action:@selector(cycleRepeat)];
    self.lyricsButton = [self button:S6IconLyrics size:24 action:@selector(toggleLyrics)];
    self.queueButton = [self button:S6IconQueue size:24 action:@selector(toggleQueue)];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
    self.volume = [[MPVolumeView alloc] initWithFrame:CGRectZero];
    [self.volume setMinimumVolumeSliderImage:[theme sliderTrackImageFilled:YES] forState:UIControlStateNormal];
    [self.volume setMaximumVolumeSliderImage:[theme sliderTrackImageFilled:NO] forState:UIControlStateNormal];
    [self.volume setVolumeThumbImage:[theme sliderThumbImage] forState:UIControlStateNormal];
    [self.view addSubview:self.volume];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(update) name:S6PlayerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(libraryChanged) name:S6LibraryDidChangeNotification object:nil];
    [self update];
}

- (void)libraryChanged
{
    self.shownURI = nil;
    [self update];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self showPanel];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return S6IsPad() ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskPortrait; }

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGSize s = self.view.bounds.size;
    BOOL landscape = s.width > s.height;
    // iOS 6 puts the view under the status bar, iOS 7 and later behind it
    CGFloat top = [[[UIDevice currentDevice] systemVersion] integerValue] >= 7 ? 20 : 0;
    self.closeButton.frame = CGRectMake(8, top + 4, 44, 44);
    self.moreButton.frame = CGRectMake(s.width - 52, top + 4, 44, 44);
    self.contextLabel.frame = CGRectMake(60, top + 6, s.width - 120, 36);
    CGFloat controlsH = S6IsPad() ? 250 : 210;
    if (landscape && S6IsPad()) {
        // the cover (or lyrics/queue) on the left, everything else on the right
        CGFloat side = MIN(s.height - 120, s.width / 2 - 40);
        CGRect panel = CGRectMake(40, (s.height - side) / 2 + 10, side, side);
        self.art.frame = panel;
        self.lyrics.view.frame = panel;
        self.queue.view.frame = panel;
        CGFloat x = 40 + side + 40, w = s.width - x - 40;
        [self layoutControlsInRect:CGRectMake(x, (s.height - controlsH) / 2, w, controlsH)];
    } else {
        CGFloat side = MIN(s.width - (S6IsPad() ? 140 : 40), s.height - controlsH - 110);
        CGRect panel = CGRectMake((s.width - side) / 2, top + 60, side, side);
        self.art.frame = panel;
        self.lyrics.view.frame = CGRectMake(20, top + 50, s.width - 40, side + 20);
        self.queue.view.frame = CGRectMake(0, top + 50, s.width, side + 20);
        CGFloat w = MIN(s.width - 40, 560);
        [self layoutControlsInRect:CGRectMake((s.width - w) / 2, CGRectGetMaxY(panel) + 18, w, controlsH)];
    }
}

- (void)layoutControlsInRect:(CGRect)r
{
    CGFloat x = r.origin.x, w = r.size.width, y = r.origin.y;
    self.titleLabel.frame = CGRectMake(x + 40, y, w - 80, 28);
    self.heartButton.frame = CGRectMake(x + w - 40, y - 6, 40, 40);
    self.artistButton.frame = CGRectMake(x + 40, y + 28, w - 80, 24);
    y += 64;
    self.progress.frame = CGRectMake(x, y, w, 22);
    self.elapsedLabel.frame = CGRectMake(x, y + 22, 60, 16);
    self.remainingLabel.frame = CGRectMake(x + w - 60, y + 22, 60, 16);
    self.formatLabel.frame = CGRectMake(x + 60, y + 22, w - 120, 16);
    y += 48;
    CGFloat cx = x + w / 2;
    self.playButton.frame = CGRectMake(cx - 36, y, 72, 64);
    self.spinner.center = self.playButton.center;
    self.previousButton.frame = CGRectMake(cx - 110, y + 8, 56, 48);
    self.nextButton.frame = CGRectMake(cx + 54, y + 8, 56, 48);
    self.shuffleButton.frame = CGRectMake(x, y + 10, 44, 44);
    self.repeatButton.frame = CGRectMake(x + w - 44, y + 10, 44, 44);
    y += 74;
    self.lyricsButton.frame = CGRectMake(x, y, 44, 44);
    self.queueButton.frame = CGRectMake(x + w - 44, y, 44, 44);
    self.volume.frame = CGRectMake(x + 60, y + 12, w - 120, 22);
}

- (void)showPanel
{
    self.art.hidden = self.panel != S6NowPlayingArt;
    self.lyrics.view.hidden = self.panel != S6NowPlayingLyrics;
    self.queue.view.hidden = self.panel != S6NowPlayingQueue;
    S6Theme *theme = [S6Theme shared];
    [self.lyricsButton setImage:[theme icon:S6IconLyrics size:24 color:self.panel == S6NowPlayingLyrics ? [theme accentColor] : [UIColor whiteColor]] forState:UIControlStateNormal];
    [self.queueButton setImage:[theme icon:S6IconQueue size:24 color:self.panel == S6NowPlayingQueue ? [theme accentColor] : [UIColor whiteColor]] forState:UIControlStateNormal];
    if (self.panel == S6NowPlayingLyrics) [self.lyrics showTrack:[S6Player shared].currentTrack];
    if (self.panel == S6NowPlayingQueue) [self.queue refresh];
}

- (void)setPanel:(S6NowPlayingPanel)panel
{
    _panel = panel;
    if (self.isViewLoaded) [self showPanel];
}

#pragma mark - State

- (void)update
{
    S6Player *player = [S6Player shared];
    S6Theme *theme = [S6Theme shared];
    S6Track *t = player.currentTrack;
    if (!t) { [self close]; return; }
    self.titleLabel.text = [S6Utils displayText:t.name];
    [self.artistButton setTitle:[S6Utils displayText:[t artistNames]] forState:UIControlStateNormal];
    NSString *context = player.contextName.length ? player.contextName : t.album.name;
    self.contextLabel.text = context.length ? [NSString stringWithFormat:@"%@\n%@", [L(@"Playing from") uppercaseString], context] : @"";
    NSString *url = [t imageURLForSize:640];
    [self.art setImageURL:url placeholder:[theme artPlaceholderWithSize:300]];
    if (url && ![url isEqualToString:self.backdropURL]) {
        self.backdropURL = url;
        __weak S6NowPlayingViewController *weakSelf = self;
        [[S6ImageLoader shared] loadImage:url maxPixels:200 completion:^(UIImage *image) {
            if ([weakSelf.backdropURL isEqualToString:url]) weakSelf.backdrop.image = image;
        }];
    }
    [self.playButton setImage:[theme icon:player.playing ? S6IconPause : S6IconPlay size:54] forState:UIControlStateNormal];
    UIColor *on = [theme accentColor], *off = [UIColor whiteColor];
    [self.shuffleButton setImage:[theme icon:S6IconShuffle size:24 color:player.shuffle ? on : off] forState:UIControlStateNormal];
    [self.repeatButton setImage:[theme icon:player.repeat == S6RepeatOne ? S6IconRepeatOne : S6IconRepeat size:24 color:player.repeat != S6RepeatOff ? on : off] forState:UIControlStateNormal];
    if (![t.uri isEqualToString:self.shownURI]) {
        self.shownURI = t.uri;
        self.liked = NO;
        [self showLiked];
        NSString *uri = t.uri;
        if (t.trackId.length && !t.isEpisode) {
            [S6WebAPI isTrackSaved:t.trackId completion:^(BOOL saved) {
                if (![uri isEqualToString:self.shownURI]) return;
                self.liked = saved;
                [self showLiked];
            }];
        }
        if (self.panel == S6NowPlayingLyrics) [self.lyrics showTrack:t];
    }
    [self tick];
}

- (void)showLiked
{
    S6Theme *theme = [S6Theme shared];
    [self.heartButton setImage:[theme icon:self.liked ? S6IconHeartFilled : S6IconHeart size:24 color:self.liked ? [theme accentColor] : [UIColor whiteColor]] forState:UIControlStateNormal];
}

- (void)tick
{
    S6Player *player = [S6Player shared];
    NSInteger duration = player.durationMs, position = player.positionMs;
    if (!self.scrubbing) {
        self.progress.value = duration > 0 ? (float)position / (float)duration : 0;
        self.elapsedLabel.text = S6FormatDurationMs(position);
        self.remainingLabel.text = duration > 0 ? [@"-" stringByAppendingString:S6FormatDurationMs(MAX(0, duration - position))] : @"";
    }
    self.formatLabel.text = player.formatName ?: @"";
    if (player.buffering && player.playing) { [self.spinner startAnimating]; self.playButton.alpha = 0.15; }
    else { [self.spinner stopAnimating]; self.playButton.alpha = 1; }
    if (self.panel == S6NowPlayingLyrics) [self.lyrics tick];
}

#pragma mark - Actions

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)togglePlay { [[S6Player shared] togglePlay]; }
- (void)next { [[S6Player shared] next]; }
- (void)previous { [[S6Player shared] previous]; }
- (void)toggleShuffle { S6Player *p = [S6Player shared]; p.shuffle = !p.shuffle; }

- (void)cycleRepeat
{
    S6Player *p = [S6Player shared];
    p.repeat = p.repeat == S6RepeatOff ? S6RepeatAll : p.repeat == S6RepeatAll ? S6RepeatOne : S6RepeatOff;
}

- (void)toggleLyrics { self.panel = self.panel == S6NowPlayingLyrics ? S6NowPlayingArt : S6NowPlayingLyrics; }
- (void)toggleQueue { self.panel = self.panel == S6NowPlayingQueue ? S6NowPlayingArt : S6NowPlayingQueue; }

- (void)toggleLike
{
    S6Track *t = [S6Player shared].currentTrack;
    if (!t.trackId.length || t.isEpisode) return;
    BOOL like = !self.liked;
    self.liked = like;
    [self showLiked];
    [S6WebAPI setTrack:t.trackId saved:like completion:^(NSError *error) {
        if (error) { self.liked = !like; [self showLiked]; [S6Router toast:error.localizedDescription]; }
    }];
}

- (void)openArtist
{
    S6Artist *a = [S6Player shared].currentTrack.artists.firstObject;
    if (!a.artistId.length) return;
    [self dismissViewControllerAnimated:YES completion:^{ [S6Router openArtist:a]; }];
}

- (void)more
{
    S6Track *t = [S6Player shared].currentTrack;
    if (t) [S6Router showActionsForTrack:t fromView:self.moreButton inController:self playlist:nil];
}

- (void)scrubStarted { self.scrubbing = YES; }

- (void)scrubMoved
{
    NSInteger duration = [S6Player shared].durationMs;
    NSInteger at = (NSInteger)(self.progress.value * duration);
    self.elapsedLabel.text = S6FormatDurationMs(at);
    self.remainingLabel.text = [@"-" stringByAppendingString:S6FormatDurationMs(MAX(0, duration - at))];
}

- (void)scrubEnded
{
    NSInteger duration = [S6Player shared].durationMs;
    if (duration > 0) [[S6Player shared] seekToMs:(NSInteger)(self.progress.value * duration)];
    self.scrubbing = NO;
}

@end
