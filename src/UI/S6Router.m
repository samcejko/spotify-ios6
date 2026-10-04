#import "S6Router.h"
#import "S6RootViewController.h"
#import "S6TrackListViewController.h"
#import "S6ArtistViewController.h"
#import "S6PlaylistPickerViewController.h"
#import "S6Models.h"
#import "S6Player.h"
#import "S6WebAPI.h"
#import "S6SpClient.h"
#import "S6Theme.h"
#import "S6Common.h"

@interface S6ActionSheet () <UIActionSheetDelegate>
@property (nonatomic, strong) UIActionSheet *sheet;
@property (nonatomic, strong) NSMutableArray *actions;
@property (nonatomic, strong) S6ActionSheet *keepAlive;
@end

@implementation S6ActionSheet

- (instancetype)initWithTitle:(NSString *)title
{
    if ((self = [super init])) {
        _sheet = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
        _sheet.actionSheetStyle = UIActionSheetStyleBlackTranslucent;
        _actions = [NSMutableArray array];
    }
    return self;
}

- (void)addButton:(NSString *)title action:(dispatch_block_t)action
{
    [self.sheet addButtonWithTitle:title];
    [self.actions addObject:[action copy] ?: [NSNull null]];
}

- (void)addDestructiveButton:(NSString *)title action:(dispatch_block_t)action
{
    self.sheet.destructiveButtonIndex = [self.sheet addButtonWithTitle:title];
    [self.actions addObject:[action copy] ?: [NSNull null]];
}

- (void)showFromView:(UIView *)view inController:(UIViewController *)controller
{
    self.sheet.cancelButtonIndex = [self.sheet addButtonWithTitle:L(@"Cancel")];
    [self.actions addObject:[NSNull null]];
    self.keepAlive = self;
    if (S6IsPad() && view.window) [self.sheet showFromRect:view.bounds inView:view animated:YES];
    else [self.sheet showInView:controller.view.window ?: controller.view];
}

- (void)actionSheet:(UIActionSheet *)sheet didDismissWithButtonIndex:(NSInteger)index
{
    if (index >= 0 && index < (NSInteger)self.actions.count) {
        id action = self.actions[(NSUInteger)index];
        if (action != [NSNull null]) ((dispatch_block_t)action)();
    }
    self.keepAlive = nil;
}

@end

@implementation S6Router

+ (void)push:(UIViewController *)controller
{
    [[S6RootViewController shared] pushViewController:controller];
}

+ (void)openAlbum:(S6Album *)album
{
    if (album.albumId.length) [self push:[[S6TrackListViewController alloc] initWithAlbum:album]];
}

+ (void)openArtist:(S6Artist *)artist
{
    if (artist.artistId.length) [self push:[[S6ArtistViewController alloc] initWithArtist:artist]];
}

+ (void)openPlaylist:(S6Playlist *)playlist
{
    if (playlist.playlistId.length) [self push:[[S6TrackListViewController alloc] initWithPlaylist:playlist]];
}

+ (void)openShow:(S6Show *)show
{
    if (show.showId.length) [self push:[[S6TrackListViewController alloc] initWithShow:show]];
}

+ (void)openLikedSongs
{
    [self push:[[S6TrackListViewController alloc] initLikedSongs]];
}

+ (void)openURI:(NSString *)uri
{
    NSString *u = [uri stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // https://open.spotify.com/album/<id>?si=... -> spotify:album:<id>
    NSRange host = [u rangeOfString:@"open.spotify.com/"];
    if (host.location != NSNotFound) {
        NSString *rest = [u substringFromIndex:host.location + host.length];
        rest = [[rest componentsSeparatedByString:@"?"] firstObject];
        NSMutableArray *parts = [[rest componentsSeparatedByString:@"/"] mutableCopy];
        if (parts.count && [parts[0] hasPrefix:@"intl-"]) [parts removeObjectAtIndex:0];
        if (parts.count >= 2) u = [NSString stringWithFormat:@"spotify:%@:%@", parts[0], parts[1]];
    }
    NSString *type = S6URIType(u), *identifier = S6URIId(u);
    if (!identifier.length) return;
    if ([type isEqualToString:@"album"]) {
        S6Album *a = [[S6Album alloc] init];
        a.albumId = identifier;
        a.uri = u;
        [self openAlbum:a];
    } else if ([type isEqualToString:@"artist"]) {
        S6Artist *a = [[S6Artist alloc] init];
        a.artistId = identifier;
        a.uri = u;
        [self openArtist:a];
    } else if ([type isEqualToString:@"playlist"]) {
        S6Playlist *p = [[S6Playlist alloc] init];
        p.playlistId = identifier;
        p.uri = u;
        [self openPlaylist:p];
    } else if ([type isEqualToString:@"show"]) {
        S6Show *s = [[S6Show alloc] init];
        s.showId = identifier;
        s.uri = u;
        [self openShow:s];
    } else if ([type isEqualToString:@"track"]) {
        [S6WebAPI get:[@"/tracks/" stringByAppendingString:identifier] completion:^(id json, NSError *error) {
            S6Track *t = error ? nil : [S6Track trackFromJSON:json];
            if (!t) { [self toast:error.localizedDescription ?: L(@"This song is not available.")]; return; }
            [[S6Player shared] playTracks:@[ t ] startingAt:0 contextURI:t.uri contextName:t.name];
            if (t.album.albumId.length) [self openAlbum:t.album];
        }];
    }
}

+ (void)showNowPlaying
{
    [[S6RootViewController shared] presentNowPlaying];
}

+ (void)toast:(NSString *)text
{
    [[S6RootViewController shared] showToast:text];
}

+ (void)showActionsForTrack:(S6Track *)track fromView:(UIView *)view inController:(UIViewController *)controller playlist:(S6Playlist *)playlist
{
    if (!track) return;
    S6ActionSheet *sheet = [[S6ActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"%@\n%@", track.name ?: @"", [track artistNames] ?: @""]];
    S6Player *player = [S6Player shared];
    if (track.playable) {
        [sheet addButton:L(@"Play next") action:^{ [player playNext:track]; [self toast:L(@"Plays next")]; }];
        [sheet addButton:L(@"Add to queue") action:^{ [player addToQueue:track]; [self toast:L(@"Added to queue")]; }];
    }
    if (!track.isEpisode && track.trackId.length) {
        [sheet addButton:L(@"Save to Liked Songs") action:^{
            [S6WebAPI setTrack:track.trackId saved:YES completion:^(NSError *error) { [self toast:error ? error.localizedDescription : L(@"Added to Liked Songs")]; }];
        }];
        [sheet addButton:L(@"Add to playlist") action:^{ [self addTrackToPlaylist:track]; }];
        [sheet addButton:L(@"Song radio") action:^{
            [self toast:L(@"Starting radio…")];
            [S6SpClient radioForURI:track.uri completion:^(NSArray *uris, NSError *error) {
                NSMutableArray *ids = [NSMutableArray array];
                for (NSString *u in uris) if (ids.count < 50 && S6URIId(u).length) [ids addObject:S6URIId(u)];
                if (!ids.count) { [self toast:error.localizedDescription ?: L(@"No radio for this.")]; return; }
                [S6WebAPI get:[NSString stringWithFormat:@"/tracks?ids=%@", [ids componentsJoinedByString:@","]] completion:^(id json, NSError *e) {
                    NSMutableArray *tracks = [NSMutableArray arrayWithObject:track];
                    for (id t in S6Arr(S6Dict(json)[@"tracks"])) {
                        S6Track *x = [S6Track trackFromJSON:t];
                        if (x.uri.length && ![x.uri isEqualToString:track.uri]) [tracks addObject:x];
                    }
                    [player playTracks:tracks startingAt:0 contextURI:[@"spotify:radio:" stringByAppendingString:track.trackId]
                           contextName:[NSString stringWithFormat:L(@"%@ Radio"), track.name]];
                }];
            }];
        }];
    }
    if (track.album.albumId.length) [sheet addButton:L(@"Go to album") action:^{ [self openAlbum:track.album]; }];
    S6Artist *artist = track.artists.firstObject;
    if (artist.artistId.length) [sheet addButton:L(@"Go to artist") action:^{ [self openArtist:artist]; }];
    if (track.trackId.length) {
        [sheet addButton:L(@"Copy link") action:^{
            [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"https://open.spotify.com/%@/%@", track.isEpisode ? @"episode" : @"track", track.trackId];
            [self toast:L(@"Link copied")];
        }];
    }
    if (playlist.playlistId.length && track.uri.length) {
        [sheet addDestructiveButton:L(@"Remove from this playlist") action:^{
            [S6WebAPI removeTrackURI:track.uri fromPlaylist:playlist.playlistId completion:^(NSError *error) {
                [self toast:error ? error.localizedDescription : L(@"Removed")];
            }];
        }];
    }
    [sheet showFromView:view inController:controller];
}

+ (void)addTrackToPlaylist:(S6Track *)track
{
    if (!track.uri.length) return;
    S6PlaylistPickerViewController *picker = [[S6PlaylistPickerViewController alloc] initWithCompletion:^(S6Playlist *playlist) {
        if (!playlist) return;
        [S6WebAPI addTrackURIs:@[ track.uri ] toPlaylist:playlist.playlistId completion:^(NSError *error) {
            [self toast:error ? error.localizedDescription : [NSString stringWithFormat:L(@"Added to %@"), playlist.name]];
        }];
    }];
    [[S6RootViewController shared] presentSheet:picker];
}

@end
