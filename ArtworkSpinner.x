@import UIKit;

#import <notify.h>
#import <Foundation/NSUserDefaults+Private.h>
#import <MediaRemote/MediaRemote+Private.h>

#define PREF_PATH "/var/mobile/Library/Preferences/com.82flex.artworkspinnerprefs.plist"
#define PREF_NOTIFY_NAME "com.82flex.artworkspinnerprefs/saved"

@protocol ASRotator <NSObject>
- (void)as_rotate;
- (void)as_beginRotation;
- (void)as_endRotation;
@end

@interface ASMediaRemoteObserver : NSObject
- (void)registerRotator:(id<ASRotator>)rotator;
@end

static ASMediaRemoteObserver *gObserver = nil;

static BOOL kIsEnabled = YES;
static BOOL kIsEnabledInMediaControls = YES;
static BOOL kIsEnabledInCoverSheetBackground = YES;
static BOOL kIsEnabledInDynamicIsland = YES;
static CGFloat kSpeedExponent = 1.0;

static void ReloadPrefs() {
    static NSUserDefaults *prefs = nil;
    if (!prefs) {
        prefs = [[NSUserDefaults alloc] _initWithSuiteName:@PREF_PATH container:nil];
    }

    NSDictionary *settings = [prefs dictionaryRepresentation];

    kIsEnabled = settings[@"IsEnabled"] ? [settings[@"IsEnabled"] boolValue] : YES;
    kIsEnabledInMediaControls = settings[@"IsEnabledInMediaControls"] ? [settings[@"IsEnabledInMediaControls"] boolValue] : YES;
    kIsEnabledInCoverSheetBackground = settings[@"IsEnabledInCoverSheetBackground"] ? [settings[@"IsEnabledInCoverSheetBackground"] boolValue] : YES;
    kIsEnabledInDynamicIsland = settings[@"IsEnabledInDynamicIsland"] ? [settings[@"IsEnabledInDynamicIsland"] boolValue] : YES;
    kSpeedExponent = settings[@"SpeedExponent"] ? [settings[@"SpeedExponent"] doubleValue] : 1.0;
}

@interface MRUArtworkView : UIView <ASRotator>
@property (nonatomic, strong) UIView *packageView;  // <- MRUActivityArtworkView?
@property (nonatomic, strong) UIImageView *artworkImageView;
@property (nonatomic, strong) UIViewPropertyAnimator *as_propertyAnimator;
@end

%hook MRUArtworkView

%property (nonatomic, strong) UIViewPropertyAnimator *as_propertyAnimator;

- (void)dealloc {
    if (self.as_propertyAnimator) {
        [self.as_propertyAnimator stopAnimation:YES];
        self.as_propertyAnimator = nil;
    }
    %orig;
}

%new
- (void)as_rotate {
    UIView *targetView = nil;
    if ([self respondsToSelector:@selector(packageView)]) {
        targetView = self.packageView;
    } else if ([self respondsToSelector:@selector(artworkImageView)]) {
        targetView = self.artworkImageView;
    } else {
        return;
    }
    if (!targetView) {
        return;
    }
    int repeatTimes = 10;
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:4.0 * repeatTimes / kSpeedExponent curve:UIViewAnimationCurveLinear animations:^{
        targetView.transform = CGAffineTransformRotate(targetView.transform, M_PI);
    }];
    while (--repeatTimes) {
        [animator addAnimations:^{
            targetView.transform = CGAffineTransformRotate(targetView.transform, M_PI);
        }];
    }
    __weak __typeof(self) weakSelf = self;
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf as_rotate];
    }];
    [animator startAnimation];
    self.as_propertyAnimator = animator;
}

%new
- (void)as_beginRotation {
    if (!self.as_propertyAnimator) {
        [self as_rotate];
    } else {
        [self.as_propertyAnimator startAnimation];
    }
}

%new
- (void)as_endRotation {
    [self.as_propertyAnimator pauseAnimation];
}

%end

@interface _TtC13MediaRemoteUI34CoverSheetBackgroundViewController : UIViewController
- (MRUArtworkView *)artworkView;
@end

%hook _TtC13MediaRemoteUI34CoverSheetBackgroundViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!kIsEnabled || !kIsEnabledInCoverSheetBackground ||
        ![self respondsToSelector:@selector(artworkView)] ||
        ![self.artworkView respondsToSelector:@selector(artworkImageView)]
    ) {
        return;
    }
    [gObserver registerRotator:self.artworkView];
}

%end

@interface MRUNowPlayingViewController : UIViewController
- (MRUArtworkView *)artworkView;
@end

%hook MRUNowPlayingViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!kIsEnabled || !kIsEnabledInMediaControls ||
        ![self respondsToSelector:@selector(artworkView)] ||
        ![self.artworkView respondsToSelector:@selector(artworkImageView)]
    ) {
        return;
    }
    [gObserver registerRotator:self.artworkView];
}

%end

@interface MRUActivityNowPlayingView : UIView <ASRotator>
@property (nonatomic, strong) NSArray<MRUArtworkView *> *artworkViews;
@end

%hook MRUActivityNowPlayingView

- (instancetype)initWithWaveformView:(id)arg1 {
    id ret = %orig;
    if (!kIsEnabled || !kIsEnabledInDynamicIsland ||
        ![self respondsToSelector:@selector(artworkViews)]
    ) {
        return ret;
    }
    for (MRUArtworkView *artworkView in self.artworkViews) {
        if (![artworkView respondsToSelector:@selector(packageView)]) {
            continue;
        }
        [gObserver registerRotator:artworkView];
    }
    return ret;
}

%end

@interface ASWeakContainer : NSObject
@property (nonatomic, weak) NSObject *object;
@end

@implementation ASWeakContainer
@end

@implementation ASMediaRemoteObserver {
    BOOL _isNowPlaying;
    NSMutableSet<ASWeakContainer *> *_weakContainers;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isNowPlaying = NO;
        _weakContainers = [[NSMutableSet alloc] init];

        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(handleSessionEvent:)
                   name:(__bridge NSNotificationName)kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification
                 object:nil];

        MRMediaRemoteSetWantsNowPlayingNotifications(true);
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
            _isNowPlaying = isPlaying;
            [self toggleArtworkAnimations];
        });
    }
    return self;
}

- (void)handleSessionEvent:(NSNotification *_Nullable)aNotification {
    NSDictionary *userInfo = aNotification.userInfo;
    BOOL isPlaying = [userInfo[(__bridge NSNotificationName)kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        _isNowPlaying = isPlaying;
        [self toggleArtworkAnimations];
    });
}

- (void)registerRotator:(id<ASRotator>)rotator {
    if (!rotator) {
        return;
    }

#if DEBUG
    NSLog(@"[ASMediaRemoteObserver] Registering rotator: %@", rotator);
#endif

    NSMutableSet<ASWeakContainer *> *containersToRemove = [NSMutableSet set];
    for (ASWeakContainer *container in _weakContainers) {
        if (!container.object || container.object == rotator) {
            [containersToRemove addObject:container];
        }
    }
    [_weakContainers minusSet:containersToRemove];

    ASWeakContainer *container = [[ASWeakContainer alloc] init];
    container.object = rotator;
    [_weakContainers addObject:container];

    [self toggleArtworkAnimation:rotator];
}

- (void)toggleArtworkAnimations {
    if (_isNowPlaying) {
        [self resumeArtworkAnimations];
    } else {
        [self pauseArtworkAnimations];
    }
}

- (void)pauseArtworkAnimations {
    for (ASWeakContainer *container in _weakContainers) {
        id<ASRotator> rotator = (id<ASRotator>)container.object;
        [self pauseArtworkAnimation:rotator];
    }
}

- (void)resumeArtworkAnimations {
    for (ASWeakContainer *container in _weakContainers) {
        id<ASRotator> rotator = (id<ASRotator>)container.object;
        [self resumeArtworkAnimation:rotator];
    }
}

- (void)toggleArtworkAnimation:(id<ASRotator>)rotator {
    if (_isNowPlaying) {
        [self resumeArtworkAnimation:rotator];
    } else {
        [self pauseArtworkAnimation:rotator];
    }
}

- (void)pauseArtworkAnimation:(id<ASRotator>)rotator {
    if (!rotator) {
        return;
    }
    [rotator as_endRotation];
}

- (void)resumeArtworkAnimation:(id<ASRotator>)rotator {
    if (!rotator) {
        return;
    }
    [rotator as_beginRotation];
}

@end

%ctor {
    ReloadPrefs();
    int _gNotifyToken;
    notify_register_dispatch(PREF_NOTIFY_NAME, &_gNotifyToken, dispatch_get_main_queue(), ^(int token) {
      ReloadPrefs();
    });

    gObserver = [[ASMediaRemoteObserver alloc] init];
    (void)gObserver;
}
