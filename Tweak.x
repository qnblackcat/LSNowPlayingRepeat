// LSNowPlayingRepeat — Lock Screen and Control Center Now Playing get a Repeat button for
// Apple Music, YouTube Music and Spotify. Tap cycles Off → All → One.
//
//   iOS 17.1+     the Favorite (⭐) button becomes Repeat; long-press toggles Favorite.
//   iOS 16–17.0   the audio output (AirPlay) button becomes Repeat; long-press opens the
//                 output picker as before.
//
// The Lock Screen platter is drawn by the MediaRemoteUI app (verified on 16.3.1 and
// 17.1.1); Control Center's module lives in SpringBoard. Both reuse MediaControls'
// MRUNowPlayingTransportControlsView. StandBy (MediaRemoteUI) and the Dynamic Island
// (SpringBoard) keep the stock controls.
//
// 17.1+ (Favorite path): -[MRUTransportControls leadingItemFromResponse:] builds the ⭐
//   item once per MPCPlayerResponse, and the transport controls view reads
//   transportControls.leadingItem at call time for its icon, visibility and tap. A Repeat
//   item is built next to it, and -leadingItem returns it only while one of those view
//   methods runs for a Lock Screen or Control Center instance.
//
// 16–17.0 (Routing path): there is no leading item. The routing button's glyph only ever
//   changes through -[MRUTransportButton setAsset:animated:], and a tap goes through
//   -[MRUNowPlayingTransportControlsView didSelectRoutingButton:]. The glyph is swapped
//   for the Repeat icon there, and the tap runs the Repeat item instead.

%config(generator=internal)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#pragma mark - Private interfaces (iOS 16.3.1 / 17.1.1)

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
@property (nonatomic, readonly) MRUAsset *asset;
@property (nonatomic, readonly) void (^mainAction)(void);
- (instancetype)initWithIdentifier:(NSString *)identifier asset:(MRUAsset *)asset mainAction:(void (^)(void))mainAction;
@end

@interface MRUTransportControls : NSObject
@property (nonatomic, readonly) MRUTransportControlItem *leadingItem;
@end

@interface MRUTransportButton : UIButton
- (void)setAsset:(MRUAsset *)asset animated:(BOOL)animated;
@end

@interface MRUNowPlayingTransportControlsView : UIView
@property (nonatomic, retain) MRUTransportButton *leadingButton;
@property (nonatomic, readonly) MRUTransportButton *routingButton;
@property (nonatomic, retain) MRUTransportControls *transportControls;
- (void)didSelectRoutingButton:(id)button;
@end

@interface MRUNowPlayingTransportControlsView (LSNowPlayingRepeat)
- (void)lsr_handleFavoriteLongPress:(UILongPressGestureRecognizer *)recognizer;
- (void)lsr_handleRoutingLongPress:(UILongPressGestureRecognizer *)recognizer;
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
		bundleIDs = [NSSet setWithObjects:@"com.apple.Music", @"com.google.ios.youtubemusic", @"com.spotify.client", nil];
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
static const void *kLSRRouteAssetKey = &kLSRRouteAssetKey;

// > 0 while a Repeat-enabled transport-controls method runs on this thread (Favorite path).
static __thread NSInteger gLSRRepeatScope;

// Set while the routing long-press forwards to the stock output picker (Routing path).
static __thread BOOL gLSRForwardRoutingTap;

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

static MRUTransportControlItem *LSRRepeatItem(MRUTransportControls *controls) {
	return controls ? objc_getAssociatedObject(controls, kLSRRepeatItemKey) : nil;
}

#pragma mark - Where Repeat applies

static BOOL LSRResponderChainContains(UIView *view, NSString *marker) {
	for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
		if ([NSStringFromClass([responder class]) containsString:marker]) return YES;
	}
	return NO;
}

static BOOL LSRShouldUseRepeat(UIView *view) {
	switch (gLSRHost) {
		// Lock Screen; StandBy (MRUAmbient…) keeps the stock button.
		case LSRHostMediaRemoteUI: return !LSRResponderChainContains(view, @"Ambient");
		// Control Center (MRUControlCenter…); the Dynamic Island keeps the stock button.
		case LSRHostSpringBoard: return LSRResponderChainContains(view, @"ControlCenter");
		default: return NO;
	}
}

#pragma mark - Long press

@interface LSRLongPressGestureRecognizer : UILongPressGestureRecognizer
@end

@implementation LSRLongPressGestureRecognizer
@end

static void LSRInstallLongPress(UIButton *button, id target, SEL action) {
	if (!button) return;
	for (UIGestureRecognizer *recognizer in button.gestureRecognizers) {
		if ([recognizer isKindOfClass:[LSRLongPressGestureRecognizer class]]) return;
	}
	[button addGestureRecognizer:[[LSRLongPressGestureRecognizer alloc] initWithTarget:target action:action]];
}

#pragma mark - Shared hooks

%group G_Shared

%hook MRUTransportControls

// New controls that compare equal are dropped before reaching the view, so a repeat
// change that leaves the stock items untouched would never update the button without this.
- (BOOL)isEqual:(id)object {
	if (!%orig) return NO;
	NSString *mine = [objc_getAssociatedObject(self, kLSRRepeatItemKey) identifier];
	NSString *theirs = [objc_getAssociatedObject(object, kLSRRepeatItemKey) identifier];
	return mine == theirs || [mine isEqualToString:theirs];
}

%end

%hook MRUTransportButton

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
	if ([recognizer isKindOfClass:[LSRLongPressGestureRecognizer class]]) return YES;
	return %orig;
}

%end

%end

#pragma mark - Favorite path (iOS 17.1+)

static BOOL LSREnterRepeatScope(UIView *view) {
	BOOL entered = LSRShouldUseRepeat(view);
	if (entered) gLSRRepeatScope++;
	return entered;
}

static void LSRExitRepeatScope(BOOL entered) {
	if (entered) gLSRRepeatScope--;
}

%group G_Favorite

%hook MRUTransportControls

- (id)leadingItemFromResponse:(id)response {
	id item = %orig;
	objc_setAssociatedObject(self, kLSRRepeatItemKey, LSRRepeatItemForResponse(response), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return item;
}

- (MRUTransportControlItem *)leadingItem {
	if (gLSRRepeatScope > 0) {
		MRUTransportControlItem *repeatItem = LSRRepeatItem(self);
		if (repeatItem) return repeatItem;
	}
	return %orig;
}

%end

%hook MRUNowPlayingTransportControlsView

- (void)configureLeadingButton {
	BOOL repeat = LSREnterRepeatScope(self);
	%orig;
	LSRExitRepeatScope(repeat);
	if (repeat) LSRInstallLongPress(self.leadingButton, self, @selector(lsr_handleFavoriteLongPress:));
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
- (void)lsr_handleFavoriteLongPress:(UILongPressGestureRecognizer *)recognizer {
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

%end

#pragma mark - Routing path (iOS 16.0 – 17.0.x)

// The transport controls view owning `button` as its routing button, or nil.
static MRUNowPlayingTransportControlsView *LSRRoutingOwner(UIView *button) {
	Class viewClass = %c(MRUNowPlayingTransportControlsView);
	for (UIView *ancestor = button.superview; ancestor; ancestor = ancestor.superview) {
		if ([ancestor isKindOfClass:viewClass]) {
			MRUNowPlayingTransportControlsView *view = (MRUNowPlayingTransportControlsView *)ancestor;
			return view.routingButton == button ? view : nil;
		}
	}
	return nil;
}

// The Repeat item to show on `view`'s routing button, or nil to keep the stock button.
static MRUTransportControlItem *LSRRoutingRepeatItem(MRUNowPlayingTransportControlsView *view) {
	return view && LSRShouldUseRepeat(view) ? LSRRepeatItem(view.transportControls) : nil;
}

// Re-applies the right glyph: the setAsset:animated: hook swaps in Repeat when it applies,
// otherwise Apple's last route glyph comes back.
static void LSRRefreshRoutingGlyph(MRUNowPlayingTransportControlsView *view) {
	MRUTransportButton *button = view.routingButton;
	MRUAsset *routeAsset = objc_getAssociatedObject(button, kLSRRouteAssetKey);
	MRUTransportControlItem *repeatItem = LSRRoutingRepeatItem(view);
	if (repeatItem || routeAsset) [button setAsset:repeatItem.asset ?: routeAsset animated:NO];
	if (repeatItem) LSRInstallLongPress(button, view, @selector(lsr_handleRoutingLongPress:));
}

%group G_Routing

%hook MRUTransportControls

- (id)initWithMPCResponse:(id)response {
	self = %orig;
	if (self) objc_setAssociatedObject(self, kLSRRepeatItemKey, LSRRepeatItemForResponse(response), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return self;
}

%end

%hook MRUTransportButton

// Every route glyph change (AirPods, speaker, AirPlay…) lands here on 16.3.1.
- (void)setAsset:(MRUAsset *)asset animated:(BOOL)animated {
	MRUNowPlayingTransportControlsView *owner = LSRRoutingOwner(self);
	if (owner) {
		MRUTransportControlItem *repeatItem = LSRRoutingRepeatItem(owner);
		if (asset && asset != repeatItem.asset && ![repeatItem.asset isEqual:asset]) {
			objc_setAssociatedObject(self, kLSRRouteAssetKey, asset, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		if (repeatItem) asset = repeatItem.asset;
	}
	%orig(asset, animated);
}

%end

%hook MRUNowPlayingTransportControlsView

- (void)setTransportControls:(MRUTransportControls *)controls {
	%orig;
	LSRRefreshRoutingGlyph(self);
}

// Control Center's view gets its controls before it joins the Control Center hierarchy,
// so the Repeat check only passes once it is on screen.
- (void)didMoveToWindow {
	%orig;
	if (self.window) LSRRefreshRoutingGlyph(self);
}

- (void)didSelectRoutingButton:(id)button {
	MRUTransportControlItem *repeatItem = gLSRForwardRoutingTap ? nil : LSRRoutingRepeatItem(self);
	if (repeatItem.mainAction) {
		repeatItem.mainAction();
		return;
	}
	%orig;
}

%new
- (void)lsr_handleRoutingLongPress:(UILongPressGestureRecognizer *)recognizer {
	if (recognizer.state != UIGestureRecognizerStateBegan || !LSRRoutingRepeatItem(self)) return;

	[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
	gLSRForwardRoutingTap = YES;
	[self didSelectRoutingButton:self.routingButton];
	gLSRForwardRoutingTap = NO;
}

%end

%end

#pragma mark - Init

static NSArray<NSString *> *LSRMissingMethods(NSArray<NSArray<NSString *> *> *required) {
	NSMutableArray<NSString *> *missing = [NSMutableArray array];
	for (NSArray<NSString *> *entry in required) {
		Class cls = NSClassFromString(entry[1]);
		SEL selector = NSSelectorFromString(entry[2]);
		BOOL found = [entry[0] isEqualToString:@"+"] ? class_getClassMethod(cls, selector) != NULL : class_getInstanceMethod(cls, selector) != NULL;
		if (!cls || !found) [missing addObject:[NSString stringWithFormat:@"%@[%@ %@]", entry[0], entry[1], entry[2]]];
	}
	return missing;
}

%ctor {
	NSProcessInfo *process = [NSProcessInfo processInfo];
	if (![process isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}]) return;
	// The Favorite button this replaces on the Lock Screen first shipped in iOS 17.1.
	BOOL favoritePath = [process isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){17, 1, 0}];

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

	// Checked on 16.3.1 and 17.1.1; bail out instead of crashing the host elsewhere.
	NSMutableArray<NSArray<NSString *> *> *required = [@[
		@[@"-", @"MRUTransportControls", @"isEqual:"],
		@[@"-", @"MRUTransportControlItem", @"initWithIdentifier:asset:mainAction:"],
		@[@"+", @"MRUAsset", @"image:"],
		@[@"-", @"MPCPlayerResponseTracklist", @"repeatCommand"],
		@[@"-", @"_MPCPlayerRepeatCommand", @"advance"],
		@[@"-", @"_MPCPlayerRepeatCommand", @"setRepeatType:"],
		@[@"-", @"_MPCPlayerRepeatCommand", @"supportedRepeatTypes"],
		@[@"-", @"_MPCPlayerRepeatCommand", @"supportsChangeRepeat"],
		@[@"+", @"MPCPlayerChangeRequest", @"performRequest:completion:"],
	] mutableCopy];
	if (favoritePath) {
		[required addObjectsFromArray:@[
			@[@"-", @"MRUTransportControls", @"leadingItemFromResponse:"],
			@[@"-", @"MRUTransportControls", @"leadingItem"],
			@[@"-", @"MRUNowPlayingTransportControlsView", @"configureLeadingButton"],
			@[@"-", @"MRUNowPlayingTransportControlsView", @"showLeadingButton"],
			@[@"-", @"MRUNowPlayingTransportControlsView", @"updateVisibility"],
			@[@"-", @"MRUNowPlayingTransportControlsView", @"didSelectLeadingButton:"],
			@[@"-", @"MRUNowPlayingTransportControlsView", @"leadingButton"],
			@[@"-", @"MRUTransportButton", @"gestureRecognizerShouldBegin:"],
		]];
	} else {
		[required addObjectsFromArray:@[
			@[@"-", @"MRUTransportControls", @"initWithMPCResponse:"],
			@[@"-", @"MRUTransportButton", @"setAsset:animated:"],
			@[@"-", @"MRUNowPlayingTransportControlsView", @"setTransportControls:"],
			@[@"-", @"MRUNowPlayingTransportControlsView", @"didSelectRoutingButton:"],
			@[@"-", @"MRUNowPlayingTransportControlsView", @"routingButton"],
			@[@"-", @"MRUNowPlayingTransportControlsView", @"transportControls"],
		]];
	}

	NSArray<NSString *> *missing = LSRMissingMethods(required);
	if (missing.count) {
		NSLog(@"[LSNowPlayingRepeat] not hooking, missing: %@", [missing componentsJoinedByString:@", "]);
		return;
	}

	%init(G_Shared);
	if (favoritePath) {
		%init(G_Favorite);
	} else {
		%init(G_Routing);
	}
}
