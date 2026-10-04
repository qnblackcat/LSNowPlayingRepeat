// LSNowPlayingRepeat — iOS 17.1 Lock Screen and Control Center Now Playing: the Favorite
// (⭐) button becomes a Repeat button for Apple Music and YouTube Music. Tap cycles
// Off → All → One; long-press toggles Favorite where the player offers it.
//
// On 17.1.1 the Lock Screen platter is not drawn by SpringBoard: it lives in the
// MediaRemoteUI app (MRULockscreenViewController). Control Center's module lives in
// SpringBoard (MRUControlCenterViewController). Both reuse MediaControls'
// MRUNowPlayingTransportControlsView; StandBy (MediaRemoteUI) and the Dynamic Island
// (SpringBoard) keep the stock ⭐.
//
// How the leading button works on 17.1.1:
//   -[MRUTransportControls leadingItemFromResponse:] builds the ⭐ item once per
//   MPCPlayerResponse. MRUNowPlayingTransportControlsView never stores that item on
//   the button: -configureLeadingButton (icon), -showLeadingButton / -updateVisibility
//   (visibility) and -didSelectLeadingButton: → leadingButtonHandler (tap) all read
//   transportControls.leadingItem at call time.
// So a Repeat item is built next to the ⭐ item, and -leadingItem returns it only while
// one of those view methods runs for a Lock Screen or Control Center instance.

%config(generator=internal)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#pragma mark - Private interfaces (iOS 17.1)

@interface MPCPlayerPath : NSObject
@property (nonatomic, readonly) NSString *bundleID;
@end

@interface _MPCPlayerRepeatCommand : NSObject
@property (nonatomic) long long currentRepeatType;
@property (nonatomic, retain) NSArray<NSNumber *> *supportedRepeatTypes;
@property (nonatomic) BOOL supportsAdvanceRepeat;
@property (nonatomic) BOOL supportsChangeRepeat;
- (id)advance;
- (id)setRepeatType:(long long)type;
@end

@interface MPCPlayerResponseTracklist : NSObject
- (_MPCPlayerRepeatCommand *)repeatCommand;
@end

@interface MPCPlayerResponse : NSObject
@property (nonatomic, readonly) MPCPlayerPath *playerPath;
@property (nonatomic, readonly) MPCPlayerResponseTracklist *tracklist;
@end

@interface MPCPlayerChangeRequest : NSObject
+ (void)performRequest:(id)request completion:(void (^)(NSError *error))completion;
@end

@interface MRUAsset : NSObject
+ (instancetype)image:(UIImage *)image;
@end

@interface MRUTransportControlItem : NSObject
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) void (^mainAction)(void);
- (instancetype)initWithIdentifier:(NSString *)identifier asset:(MRUAsset *)asset mainAction:(void (^)(void))mainAction;
@end

@interface MRUTransportControls : NSObject
@property (nonatomic, readonly) MRUTransportControlItem *leadingItem;
@end

@interface MRUTransportButton : UIButton
@end

@interface MRUNowPlayingTransportControlsView : UIView
@property (nonatomic, retain) MRUTransportButton *leadingButton;
@property (nonatomic, retain) MRUTransportControls *transportControls;
@end

@interface MRUNowPlayingTransportControlsView (LSNowPlayingRepeat)
- (void)lsr_handleLongPress:(UILongPressGestureRecognizer *)recognizer;
@end

#pragma mark - Constants

// MPRepeatType values used by MediaPlaybackCore; Music advances Off → All → One.
typedef NS_ENUM(long long, LSRRepeatType) {
	LSRRepeatTypeOff = 0,
	LSRRepeatTypeOne = 1,
	LSRRepeatTypeAll = 2,
};

static NSSet<NSString *> *LSRSupportedBundleIDs(void) {
	static NSSet<NSString *> *bundleIDs;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		bundleIDs = [NSSet setWithObjects:@"com.apple.Music", @"com.google.ios.youtubemusic", nil];
	});
	return bundleIDs;
}

typedef NS_ENUM(NSInteger, LSRHost) {
	LSRHostOther,
	LSRHostMediaRemoteUI,
	LSRHostSpringBoard,
};

static LSRHost gLSRHost;

static const void *kLSRRepeatItemKey = &kLSRRepeatItemKey;

// > 0 while a Repeat-enabled transport-controls method runs on this thread.
static __thread NSInteger gLSRRepeatScope;

#pragma mark - Repeat item

static NSString *LSRSymbolNameForRepeatType(long long type) {
	switch (type) {
		case LSRRepeatTypeOne: return @"repeat.1.circle.fill";
		case LSRRepeatTypeAll: return @"repeat.circle.fill";
		default: return @"repeat";
	}
}

// Players that only accept an explicit mode get the next one in Music's order.
static id LSRNextRepeatRequest(_MPCPlayerRepeatCommand *command) {
	if (command.supportsAdvanceRepeat) return [command advance];
	if (!command.supportsChangeRepeat) return nil;

	NSArray<NSNumber *> *supported = command.supportedRepeatTypes;
	NSMutableArray<NSNumber *> *cycle = [NSMutableArray array];
	for (NSNumber *type in @[@(LSRRepeatTypeOff), @(LSRRepeatTypeAll), @(LSRRepeatTypeOne)]) {
		if (!supported.count || [supported containsObject:type]) [cycle addObject:type];
	}
	if (cycle.count < 2) return nil;

	NSUInteger index = [cycle indexOfObject:@(command.currentRepeatType)];
	NSUInteger next = index == NSNotFound ? 0 : (index + 1) % cycle.count;
	return [command setRepeatType:cycle[next].longLongValue];
}

static MRUTransportControlItem *LSRRepeatItemForResponse(MPCPlayerResponse *response) {
	NSString *bundleID = response.playerPath.bundleID;
	if (!bundleID || ![LSRSupportedBundleIDs() containsObject:bundleID]) return nil;

	_MPCPlayerRepeatCommand *command = response.tracklist.repeatCommand;

	// Built up front like Apple's ⭐ item does with -changeValue:, while the response is alive.
	id request = LSRNextRepeatRequest(command);
	if (!request) return nil;

	long long type = command.currentRepeatType;
	MRUAsset *asset = [%c(MRUAsset) image:[UIImage systemImageNamed:LSRSymbolNameForRepeatType(type)]];
	NSString *identifier = [NSString stringWithFormat:@"lsnowplayingrepeat.%lld", type];
	return [[%c(MRUTransportControlItem) alloc] initWithIdentifier:identifier asset:asset mainAction:^{
		[%c(MPCPlayerChangeRequest) performRequest:request completion:^(NSError *error) {
			if (error) NSLog(@"[LSNowPlayingRepeat] changing repeat failed: %@", error);
		}];
	}];
}

#pragma mark - Repeat scope

static BOOL LSRResponderChainContains(UIView *view, NSString *marker) {
	for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
		if ([NSStringFromClass([responder class]) containsString:marker]) return YES;
	}
	return NO;
}

static BOOL LSRShouldUseRepeat(UIView *view) {
	switch (gLSRHost) {
		// Lock Screen; StandBy (MRUAmbient…) keeps ⭐.
		case LSRHostMediaRemoteUI: return !LSRResponderChainContains(view, @"Ambient");
		// Control Center (MRUControlCenter…); the Dynamic Island keeps ⭐.
		case LSRHostSpringBoard: return LSRResponderChainContains(view, @"ControlCenter");
		default: return NO;
	}
}

static BOOL LSREnterRepeatScope(UIView *view) {
	BOOL entered = LSRShouldUseRepeat(view);
	if (entered) gLSRRepeatScope++;
	return entered;
}

static void LSRExitRepeatScope(BOOL entered) {
	if (entered) gLSRRepeatScope--;
}

#pragma mark - Long-press → Favorite

@interface LSRLongPressGestureRecognizer : UILongPressGestureRecognizer
@end

@implementation LSRLongPressGestureRecognizer
@end

static void LSRInstallLongPress(MRUNowPlayingTransportControlsView *view) {
	UIButton *button = view.leadingButton;
	if (!button) return;
	for (UIGestureRecognizer *recognizer in button.gestureRecognizers) {
		if ([recognizer isKindOfClass:[LSRLongPressGestureRecognizer class]]) return;
	}
	[button addGestureRecognizer:[[LSRLongPressGestureRecognizer alloc] initWithTarget:view action:@selector(lsr_handleLongPress:)]];
}

#pragma mark - Hooks

%hook MRUTransportControls

- (id)leadingItemFromResponse:(id)response {
	id item = %orig;
	objc_setAssociatedObject(self, kLSRRepeatItemKey, LSRRepeatItemForResponse(response), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return item;
}

- (MRUTransportControlItem *)leadingItem {
	if (gLSRRepeatScope > 0) {
		MRUTransportControlItem *repeatItem = objc_getAssociatedObject(self, kLSRRepeatItemKey);
		if (repeatItem) return repeatItem;
	}
	return %orig;
}

// New controls that compare equal are dropped before reaching the view, so a repeat
// change that leaves ⭐ untouched would never update the Lock Screen without this.
- (BOOL)isEqual:(id)object {
	if (!%orig) return NO;
	NSString *mine = [objc_getAssociatedObject(self, kLSRRepeatItemKey) identifier];
	NSString *theirs = [objc_getAssociatedObject(object, kLSRRepeatItemKey) identifier];
	return mine == theirs || [mine isEqualToString:theirs];
}

%end

%hook MRUNowPlayingTransportControlsView

- (void)configureLeadingButton {
	BOOL repeat = LSREnterRepeatScope(self);
	%orig;
	LSRExitRepeatScope(repeat);
	if (repeat) LSRInstallLongPress(self);
}

- (BOOL)showLeadingButton {
	BOOL repeat = LSREnterRepeatScope(self);
	BOOL show = %orig;
	LSRExitRepeatScope(repeat);
	return show;
}

- (void)updateVisibility {
	BOOL repeat = LSREnterRepeatScope(self);
	%orig;
	LSRExitRepeatScope(repeat);
}

- (void)didSelectLeadingButton:(id)button {
	BOOL repeat = LSREnterRepeatScope(self);
	%orig;
	LSRExitRepeatScope(repeat);
}

%new
- (void)lsr_handleLongPress:(UILongPressGestureRecognizer *)recognizer {
	if (recognizer.state != UIGestureRecognizerStateBegan || !LSRShouldUseRepeat(self)) return;

	// Outside the scope, -leadingItem is the stock ⭐ item.
	MRUTransportControlItem *favoriteItem = self.transportControls.leadingItem;
	NSLog(@"[LSNowPlayingRepeat] long press, favorite item=%@", favoriteItem.identifier);
	if (![favoriteItem.identifier hasPrefix:@"favorite."] || !favoriteItem.mainAction) return;

	if ([favoriteItem.identifier isEqualToString:@"favorite.Off"]) {
		[[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
	} else {
		[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
	}
	favoriteItem.mainAction();
}

%end

%hook MRUTransportButton

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
	if ([recognizer isKindOfClass:[LSRLongPressGestureRecognizer class]]) return YES;
	return %orig;
}

%end

#pragma mark - Init

%ctor {
	// The Favorite button this replaces first shipped in iOS 17.1.
	if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){17, 1, 0}]) return;

	NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
	if ([bundleID isEqualToString:@"com.apple.MediaRemoteUI"]) {
		gLSRHost = LSRHostMediaRemoteUI;
	} else if ([bundleID isEqualToString:@"com.apple.springboard"]) {
		gLSRHost = LSRHostSpringBoard;
	} else {
		return;
	}

	dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_LAZY);
	dlopen("/System/Library/PrivateFrameworks/MediaPlaybackCore.framework/MediaPlaybackCore", RTLD_LAZY);

	// Everything below was checked on 17.1.1; bail out instead of crashing the host elsewhere.
	NSArray<NSArray<NSString *> *> *required = @[
		@[@"-", @"MRUTransportControls", @"leadingItemFromResponse:"],
		@[@"-", @"MRUTransportControls", @"leadingItem"],
		@[@"-", @"MRUNowPlayingTransportControlsView", @"configureLeadingButton"],
		@[@"-", @"MRUNowPlayingTransportControlsView", @"showLeadingButton"],
		@[@"-", @"MRUNowPlayingTransportControlsView", @"updateVisibility"],
		@[@"-", @"MRUNowPlayingTransportControlsView", @"didSelectLeadingButton:"],
		@[@"-", @"MRUNowPlayingTransportControlsView", @"leadingButton"],
		@[@"-", @"MRUTransportButton", @"gestureRecognizerShouldBegin:"],
		@[@"-", @"MRUTransportControlItem", @"initWithIdentifier:asset:mainAction:"],
		@[@"+", @"MRUAsset", @"image:"],
		@[@"-", @"MPCPlayerResponseTracklist", @"repeatCommand"],
		@[@"-", @"_MPCPlayerRepeatCommand", @"advance"],
		@[@"-", @"_MPCPlayerRepeatCommand", @"setRepeatType:"],
		@[@"-", @"_MPCPlayerRepeatCommand", @"supportedRepeatTypes"],
		@[@"-", @"_MPCPlayerRepeatCommand", @"supportsChangeRepeat"],
		@[@"+", @"MPCPlayerChangeRequest", @"performRequest:completion:"],
	];
	NSMutableArray<NSString *> *missing = [NSMutableArray array];
	for (NSArray<NSString *> *entry in required) {
		Class cls = NSClassFromString(entry[1]);
		SEL selector = NSSelectorFromString(entry[2]);
		BOOL found = [entry[0] isEqualToString:@"+"] ? class_getClassMethod(cls, selector) != NULL : class_getInstanceMethod(cls, selector) != NULL;
		if (!cls || !found) [missing addObject:[NSString stringWithFormat:@"%@[%@ %@]", entry[0], entry[1], entry[2]]];
	}
	if (missing.count) {
		NSLog(@"[LSNowPlayingRepeat] not hooking, missing: %@", [missing componentsJoinedByString:@", "]);
		return;
	}

	%init;
}
