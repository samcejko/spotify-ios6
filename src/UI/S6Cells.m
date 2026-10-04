#import "S6Cells.h"
#import "S6Theme.h"
#import "S6ImageLoader.h"
#import "S6Models.h"
#import "S6Player.h"
#import "S6Utils.h"
#import "S6Common.h"

UIView *S6SectionHeader(NSString *title, CGFloat width)
{
    S6Theme *theme = [S6Theme shared];
    UIImageView *bar = [[UIImageView alloc] initWithImage:[theme sectionHeaderImage]];
    bar.frame = CGRectMake(0, 0, width, 26);
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, width - 24, 26)];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    l.backgroundColor = [UIColor clearColor];
    l.font = [theme sectionFont];
    l.textColor = [theme secondaryTextColor];
    l.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    l.shadowOffset = CGSizeMake(0, -1);
    l.text = [title uppercaseString];
    [bar addSubview:l];
    return bar;
}

@interface S6TrackCell ()
@property (nonatomic, strong) S6ImageView *art;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UILabel *numberLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UIImageView *explicitView;
@property (nonatomic, strong) UIImageView *playingView;
@end

@implementation S6TrackCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        S6Theme *theme = [S6Theme shared];
        [theme styleCell:self];
        _showsArt = YES;
        _art = [[S6ImageView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        [self.contentView addSubview:_art];
        _numberLabel = [self label:[theme smallFont] color:[theme secondaryTextColor]];
        _numberLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel = [self label:[theme bodyFont] color:[theme primaryTextColor]];
        _subtitleLabel = [self label:[theme smallFont] color:[theme secondaryTextColor]];
        _durationLabel = [self label:[theme smallFont] color:[theme tertiaryTextColor]];
        _durationLabel.textAlignment = NSTextAlignmentRight;
        _explicitView = [[UIImageView alloc] initWithImage:[theme explicitBadge]];
        [self.contentView addSubview:_explicitView];
        _playingView = [[UIImageView alloc] initWithImage:[theme icon:S6IconSpeaker size:16 color:[theme accentColor]]];
        [self.contentView addSubview:_playingView];
        _moreButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_moreButton setImage:[theme icon:S6IconMore size:18 color:[theme secondaryTextColor]] forState:UIControlStateNormal];
        _moreButton.accessibilityLabel = L(@"More");
        [self.contentView addSubview:_moreButton];
    }
    return self;
}

- (UILabel *)label:(UIFont *)font color:(UIColor *)color
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.font = font;
    l.textColor = color;
    l.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:l];
    return l;
}

- (void)showTrack:(S6Track *)track number:(NSInteger)number
{
    S6Theme *theme = [S6Theme shared];
    S6Track *current = [S6Player shared].currentTrack;
    BOOL playing = current && ([current.uri isEqualToString:track.uri] || (current.trackId.length && [current.trackId isEqualToString:track.trackId]));
    self.titleLabel.text = [S6Utils displayText:track.name];
    self.titleLabel.textColor = playing ? [theme accentTextColor] : (track.playable ? [theme primaryTextColor] : [theme tertiaryTextColor]);
    NSString *sub = [track artistNames];
    if (self.showsArt && track.album.name.length && !track.isEpisode) sub = [NSString stringWithFormat:@"%@ · %@", sub, track.album.name];
    self.subtitleLabel.text = [S6Utils displayText:sub];
    self.durationLabel.text = track.durationMs ? S6FormatDurationMs(track.durationMs) : @"";
    self.numberLabel.text = number > 0 ? [NSString stringWithFormat:@"%ld", (long)number] : @"";
    self.explicitView.hidden = !track.explicitContent;
    self.playingView.hidden = !playing;
    self.art.hidden = !self.showsArt;
    self.numberLabel.hidden = self.showsArt || playing;
    if (self.showsArt) [self.art setImageURL:[track imageURLForSize:80] placeholder:[theme artPlaceholderWithSize:40]];
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGSize s = self.contentView.bounds.size;
    CGFloat x = 10;
    if (self.showsArt) {
        self.art.frame = CGRectMake(x, floorf((s.height - 40) / 2), 40, 40);
        x += 50;
    } else {
        self.numberLabel.frame = CGRectMake(4, 0, 34, s.height);
        x = 42;
    }
    self.playingView.frame = self.showsArt ? CGRectMake(x - 4, floorf((s.height - 16) / 2), 16, 16) : CGRectMake(13, floorf((s.height - 16) / 2), 16, 16);
    if (self.showsArt && !self.playingView.hidden) x += 16;
    self.moreButton.frame = CGRectMake(s.width - 40, 0, 40, s.height);
    CGFloat right = s.width - 40;
    CGSize d = [self.durationLabel.text sizeWithFont:self.durationLabel.font];
    self.durationLabel.frame = CGRectMake(right - ceilf(d.width) - 4, 0, ceilf(d.width), s.height);
    right -= ceilf(d.width) + 12;
    CGFloat textX = x;
    if (!self.explicitView.hidden) {
        self.explicitView.frame = CGRectMake(textX, floorf(s.height / 2) + 4, 14, 14);
        textX += 18;
    }
    self.titleLabel.frame = CGRectMake(x, floorf(s.height / 2) - 19, right - x, 20);
    self.subtitleLabel.frame = CGRectMake(textX, floorf(s.height / 2) + 2, right - textX, 17);
}

@end

@interface S6MediaCell ()
@property (nonatomic, strong) S6ImageView *art;
@end

@implementation S6MediaCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier])) {
        S6Theme *theme = [S6Theme shared];
        [theme styleCell:self];
        self.textLabel.font = [theme boldBodyFont];
        self.detailTextLabel.font = [theme smallFont];
        _art = [[S6ImageView alloc] initWithFrame:CGRectMake(0, 0, 52, 52)];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        [self.contentView addSubview:_art];
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return self;
}

- (void)setRound:(BOOL)round
{
    _round = round;
    self.art.layer.cornerRadius = round ? 26 : 0;
}

- (void)showTitle:(NSString *)title subtitle:(NSString *)subtitle imageURL:(NSString *)url
{
    S6Theme *theme = [S6Theme shared];
    self.textLabel.text = [S6Utils displayText:title];
    self.detailTextLabel.text = [S6Utils displayText:subtitle];
    [self.art setImageURL:url placeholder:self.round ? [theme artistPlaceholderWithSize:52] : [theme artPlaceholderWithSize:52]];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGSize s = self.contentView.bounds.size;
    self.art.frame = CGRectMake(10, floorf((s.height - 52) / 2), 52, 52);
    CGFloat x = 74, w = s.width - x - 6;
    self.textLabel.frame = CGRectMake(x, floorf(s.height / 2) - 20, w, 20);
    self.detailTextLabel.frame = CGRectMake(x, floorf(s.height / 2) + 2, w, 18);
}

@end

@interface S6CardView ()
@property (nonatomic, strong) S6ImageView *art;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation S6CardView

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        S6Theme *theme = [S6Theme shared];
        _art = [[S6ImageView alloc] initWithFrame:CGRectZero];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        _art.userInteractionEnabled = NO;
        [self addSubview:_art];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:13] ?: [UIFont boldSystemFontOfSize:13];
        _titleLabel.textColor = [theme primaryTextColor];
        _titleLabel.backgroundColor = [UIColor clearColor];
        [self addSubview:_titleLabel];
        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.font = [UIFont fontWithName:@"HelveticaNeue" size:12] ?: [UIFont systemFontOfSize:12];
        _subtitleLabel.textColor = [theme secondaryTextColor];
        _subtitleLabel.backgroundColor = [UIColor clearColor];
        [self addSubview:_subtitleLabel];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    self.art.alpha = highlighted ? 0.6 : 1;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    self.art.frame = CGRectMake(0, 0, w, w);
    self.art.layer.cornerRadius = self.round ? w / 2 : 0;
    self.titleLabel.frame = CGRectMake(0, w + 6, w, 17);
    self.subtitleLabel.frame = CGRectMake(0, w + 23, w, 16);
    self.titleLabel.textAlignment = self.round ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    self.subtitleLabel.textAlignment = self.titleLabel.textAlignment;
}

@end

@interface S6ShelfCell ()
@property (nonatomic, strong) UIScrollView *scroller;
@property (nonatomic, strong) NSMutableArray *cards;
@end

@implementation S6ShelfCell

+ (CGFloat)heightForCardWidth:(CGFloat)width { return width + 58; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _scroller = [[UIScrollView alloc] initWithFrame:self.contentView.bounds];
        _scroller.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _scroller.showsHorizontalScrollIndicator = NO;
        _scroller.alwaysBounceHorizontal = YES;
        _scroller.scrollsToTop = NO;
        [self.contentView addSubview:_scroller];
        _cards = [NSMutableArray array];
    }
    return self;
}

- (void)showItems:(NSArray *)items cardWidth:(CGFloat)width
{
    S6Theme *theme = [S6Theme shared];
    while (self.cards.count < items.count) {
        S6CardView *card = [[S6CardView alloc] initWithFrame:CGRectZero];
        [card addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.scroller addSubview:card];
        [self.cards addObject:card];
    }
    CGFloat x = 12, gap = 14;
    for (NSUInteger i = 0; i < self.cards.count; i++) {
        S6CardView *card = self.cards[i];
        card.hidden = i >= items.count;
        if (card.hidden) continue;
        NSDictionary *d = items[i];
        card.round = [d[@"round"] boolValue];
        card.item = d[@"item"];
        card.titleLabel.text = [S6Utils displayText:d[@"title"]];
        card.subtitleLabel.text = [S6Utils displayText:d[@"subtitle"]];
        [card.art setImageURL:d[@"image"] placeholder:card.round ? [theme artistPlaceholderWithSize:width] : [theme artPlaceholderWithSize:width]];
        card.frame = CGRectMake(x, 10, width, width + 44);
        [card setNeedsLayout];
        x += width + gap;
    }
    self.scroller.contentSize = CGSizeMake(x, width + 54);
    self.scroller.contentOffset = CGPointZero;
}

- (void)tapped:(S6CardView *)card
{
    if (self.onSelect && card.item) self.onSelect(card.item);
}

@end
