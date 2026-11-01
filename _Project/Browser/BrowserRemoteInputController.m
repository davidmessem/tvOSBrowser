#import "BrowserRemoteInputController.h"

static UIImage *BrowserDefaultCursor(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage imageNamed:@"Cursor"];
    });
    return image;
}

static UIImage *BrowserPointerCursor(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage imageNamed:@"Pointer"];
    });
    return image;
}

static NSString *BrowserPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

@interface BrowserRemoteInputController ()

@property (nonatomic, weak) id<BrowserRemoteInputControllerHost> host;
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, readwrite) UIImageView *cursorView;
@property (nonatomic, readwrite) UITapGestureRecognizer *playPauseDoubleTapRecognizer;
@property (nonatomic, readwrite, getter=isCursorModeEnabled) BOOL cursorModeEnabled;
@property (nonatomic) BOOL directSelectPending;
@property (nonatomic) CFTimeInterval lastDirectSelectPressTimestamp;
@property (nonatomic) NSMutableSet<NSNumber *> *heldArrowPressTypes;
@property (nonatomic) CADisplayLink *arrowDisplayLink;
@property (nonatomic) CFTimeInterval arrowLastTimestamp;
@property (nonatomic) CFTimeInterval arrowHoldStartTimestamp;
@property (nonatomic) CFTimeInterval lastHoverCheckTimestamp;
@property (nonatomic) BOOL arrowDidScroll;
// Arrow presses whose release we must swallow even after movement stopped.
@property (nonatomic) NSMutableSet<NSNumber *> *consumedArrowPressTypes;
@property (nonatomic) CGPoint arrowLastDirection;

@end

@implementation BrowserRemoteInputController

- (instancetype)initWithHost:(id<BrowserRemoteInputControllerHost>)host
                    rootView:(UIView *)rootView {
    self = [super init];
    if (self) {
        _host = host;
        _rootView = rootView;
        _cursorModeEnabled = YES;
        _heldArrowPressTypes = [NSMutableSet set];
        _consumedArrowPressTypes = [NSMutableSet set];

        _cursorView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
        _cursorView.center = CGPointMake(CGRectGetMidX([UIScreen mainScreen].bounds), CGRectGetMidY([UIScreen mainScreen].bounds));
        _cursorView.image = BrowserDefaultCursor();

        _playPauseDoubleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePlayPauseDoubleTap:)];
        _playPauseDoubleTapRecognizer.numberOfTapsRequired = 2;
        _playPauseDoubleTapRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        [rootView addGestureRecognizer:_playPauseDoubleTapRecognizer];
    }
    return self;
}

- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled {
    BOOL wasCursorModeEnabled = self.cursorModeEnabled;
    _cursorModeEnabled = cursorModeEnabled;
    [self stopArrowMovement];
    [self refreshInteractionState];
    if (!wasCursorModeEnabled && cursorModeEnabled) {
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)refreshInteractionState {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    BOOL topBarFocusActive = [self.host browserRemoteInputControllerTopBarFocusActive];
    BOOL shouldAllowWebInteraction = !self.cursorModeEnabled &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        !topBarFocusActive;
    scrollView.scrollEnabled = shouldAllowWebInteraction;
    [self.host browserRemoteInputControllerSetWebInteractionEnabled:shouldAllowWebInteraction];
    self.cursorView.hidden = !self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        topBarFocusActive;
}

- (BOOL)applyManualScrollDelta:(CGPoint)delta {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    if (scrollView == nil) {
        return NO;
    }

    CGPoint contentOffset = scrollView.contentOffset;
    CGFloat maxOffsetX = MAX(0.0, scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds));
    CGFloat maxOffsetY = MAX(0.0, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds));
    CGFloat nextOffsetX = MIN(MAX(contentOffset.x + delta.x, 0.0), maxOffsetX);
    CGFloat nextOffsetY = MIN(MAX(contentOffset.y + delta.y, 0.0), maxOffsetY);
    CGPoint nextOffset = CGPointMake(nextOffsetX, nextOffsetY);
    [scrollView setContentOffset:nextOffset animated:NO];
    return !CGPointEqualToPoint(contentOffset, nextOffset);
}

- (void)handleGlobalSelectPressEndedNotification {
    // The app-level hook posts this once per Select release. If this controller
    // already handled that release directly, consume the flag and do nothing.
    // The 1s expiry only guards against a notification that never arrives.
    if (self.directSelectPending) {
        self.directSelectPending = NO;
        if ((CACurrentMediaTime() - self.lastDirectSelectPressTimestamp) < 1.0) {
            return;
        }
    }

    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }

    [self handleSelectPressEnded];
}

- (void)handleSelectPressEnded {
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
        return;
    }

    [self.host browserRemoteInputControllerHandlePrimaryAction];
}

#pragma mark - Arrow-driven pointer

static BOOL BrowserIsArrowPress(UIPressType type) {
    return type == UIPressTypeUpArrow || type == UIPressTypeDownArrow ||
        type == UIPressTypeLeftArrow || type == UIPressTypeRightArrow;
}

- (BOOL)arrowPointerActive {
    return self.cursorModeEnabled &&
        [self.host browserRemoteInputControllerPresentedViewController] == nil &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        ![self.host browserRemoteInputControllerTopBarFocusActive];
}

- (void)stopArrowMovement {
    // Releases of these presses are still swallowed (see consumedArrowPressTypes).
    [self.heldArrowPressTypes removeAllObjects];
    [self.arrowDisplayLink invalidate];
    self.arrowDisplayLink = nil;
    self.arrowLastTimestamp = 0;
    self.arrowLastDirection = CGPointZero;
    if (self.arrowDidScroll) {
        self.arrowDidScroll = NO;
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)startArrowMovementIfNeeded {
    if (self.arrowDisplayLink != nil) {
        return;
    }
    self.arrowHoldStartTimestamp = CACurrentMediaTime();
    self.arrowLastTimestamp = 0;
    self.arrowDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleArrowDisplayLink:)];
    [self.arrowDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    // Nudge immediately so a quick tap still moves the pointer a little.
    [self moveCursorForHeldArrowsWithDeltaTime:1.0 / 30.0];
}

- (void)handleArrowDisplayLink:(CADisplayLink *)displayLink {
    if (![self arrowPointerActive] || self.heldArrowPressTypes.count == 0) {
        [self stopArrowMovement];
        return;
    }
    if (self.arrowLastTimestamp <= 0) {
        self.arrowLastTimestamp = displayLink.timestamp;
        return;
    }
    CFTimeInterval deltaTime = MIN(displayLink.timestamp - self.arrowLastTimestamp, 0.05);
    self.arrowLastTimestamp = displayLink.timestamp;
    [self moveCursorForHeldArrowsWithDeltaTime:deltaTime];
}

- (void)moveCursorForHeldArrowsWithDeltaTime:(CFTimeInterval)deltaTime {
    CGFloat dx = 0, dy = 0;
    if ([self.heldArrowPressTypes containsObject:@(UIPressTypeLeftArrow)]) dx -= 1;
    if ([self.heldArrowPressTypes containsObject:@(UIPressTypeRightArrow)]) dx += 1;
    if ([self.heldArrowPressTypes containsObject:@(UIPressTypeUpArrow)]) dy -= 1;
    if ([self.heldArrowPressTypes containsObject:@(UIPressTypeDownArrow)]) dy += 1;
    if (dx == 0 && dy == 0) {
        return;
    }
    CGPoint direction = CGPointMake(dx, dy);
    if (!CGPointEqualToPoint(direction, self.arrowLastDirection)) {
        // New direction: drop back to the slow, precise speed.
        self.arrowLastDirection = direction;
        self.arrowHoldStartTimestamp = CACurrentMediaTime();
    }

    // Start slow for precision, accelerate the longer the arrow is held.
    CFTimeInterval held = CACurrentMediaTime() - self.arrowHoldStartTimestamp;
    CGFloat speed = 350.0 + MIN(held / 1.2, 1.0) * 1250.0; // points per second
    CGFloat step = speed * deltaTime;

    CGRect bounds = self.rootView.bounds;
    // The hotspot is the image's top-left, so stop short of the right/bottom
    // edge to keep the pointer visible while edge-scrolling that way.
    static const CGFloat kVisibleMargin = 24.0;
    CGFloat maxX = CGRectGetWidth(bounds) - kVisibleMargin;
    CGFloat maxY = CGRectGetHeight(bounds) - kVisibleMargin;
    CGRect rect = self.cursorView.frame;
    CGFloat wantedX = rect.origin.x + dx * step;
    CGFloat wantedY = rect.origin.y + dy * step;
    rect.origin.x = MIN(MAX(wantedX, 0.0), maxX);
    rect.origin.y = MIN(MAX(wantedY, 0.0), maxY);
    self.cursorView.frame = rect;

    // Whatever movement the screen edge blocked becomes page scrolling.
    CGPoint overflow = CGPointMake(wantedX - rect.origin.x, wantedY - rect.origin.y);
    if (!CGPointEqualToPoint(overflow, CGPointZero)) {
        UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
        CGFloat offsetYBefore = scrollView.contentOffset.y;
        BOOL didScroll = [self applyManualScrollDelta:overflow];
        self.arrowDidScroll = self.arrowDidScroll || didScroll;
        BOOL didScrollVertically = scrollView != nil && scrollView.contentOffset.y != offsetYBefore;
        BOOL atTopOfPage = scrollView == nil ||
            scrollView.contentOffset.y <= 0.0; // matches the clamp in applyManualScrollDelta
        if (overflow.y < 0 && !didScrollVertically && atTopOfPage &&
            [self.host browserRemoteInputControllerCanActivateTopBarFocus]) {
            // Pushing up past the top of the page moves focus to the top bar.
            [self stopArrowMovement];
            [self.host browserRemoteInputControllerActivateTopBarFocus];
            return;
        }
    }

    // Hover detection runs JS synchronously, so keep it infrequent and skip it
    // while the page is scrolling under the pointer.
    CFTimeInterval now = CACurrentMediaTime();
    if (CGPointEqualToPoint(overflow, CGPointZero) && now - self.lastHoverCheckTimestamp > 0.15) {
        self.lastHoverCheckTimestamp = now;
        [self updateCursorImage];
    }
}

- (void)updateCursorImage {
    self.cursorView.image = BrowserDefaultCursor();
    NSString *containsLink = [self.host browserRemoteInputControllerHoverStateAtCursorPoint:self.cursorView.frame.origin];
    if ([containsLink isEqualToString:@"true"]) {
        self.cursorView.image = BrowserPointerCursor();
    }
}

- (void)handlePlayPauseDoubleTap:(UITapGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateEnded) {
        return;
    }
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerDismissTabOverview];
        return;
    }
    [self.host browserRemoteInputControllerHandleAdvancedMenuPress];
}

- (BOOL)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"[InputTrace][Root] pressesBegan type=%@ phase=%@ presented=%@",
              BrowserPressTypeString(press.type),
              BrowserPressPhaseString(press.phase),
              [self.host browserRemoteInputControllerPresentedViewController] == nil ? @"(nil)" : NSStringFromClass([[self.host browserRemoteInputControllerPresentedViewController] class]));
    }
    (void)event;
    BOOL consumed = NO;
    for (UIPress *downPress in presses) {
        if (downPress.type == UIPressTypeDownArrow &&
            [self.host browserRemoteInputControllerTopBarFocusActive] &&
            [self.host browserRemoteInputControllerPresentedViewController] == nil) {
            // Leave the top bar on press-down so a held Down keeps moving the pointer.
            [self.host browserRemoteInputControllerDeactivateTopBarFocus];
            break;
        }
    }
    for (UIPress *arrowPress in presses) {
        if (BrowserIsArrowPress(arrowPress.type) && [self arrowPointerActive]) {
            [self.heldArrowPressTypes addObject:@(arrowPress.type)];
            [self.consumedArrowPressTypes addObject:@(arrowPress.type)];
            [self startArrowMovementIfNeeded];
            consumed = YES;
        }
    }
    return consumed;
}

- (BOOL)releaseArrowPresses:(NSSet<UIPress *> *)presses {
    BOOL handledArrow = NO;
    for (UIPress *arrowPress in presses) {
        NSNumber *type = @(arrowPress.type);
        if (BrowserIsArrowPress(arrowPress.type) && [self.consumedArrowPressTypes containsObject:type]) {
            [self.consumedArrowPressTypes removeObject:type];
            [self.heldArrowPressTypes removeObject:type];
            handledArrow = YES;
        }
    }
    if (handledArrow && self.heldArrowPressTypes.count == 0) {
        [self stopArrowMovement];
        if ([self arrowPointerActive]) {
            [self updateCursorImage];
        }
    }
    return handledArrow;
}

- (BOOL)handlePressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    return [self releaseArrowPresses:presses];
}

- (void)resetHeldPresses {
    [self stopArrowMovement];
    [self.consumedArrowPressTypes removeAllObjects];
}

- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    UIPress *press = presses.anyObject;
    if (press == nil) {
        return NO;
    }

    if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
        NSLog(@"[InputTrace][Root] pressesEnded type=%@ phase=%@ presented=%@ tabOverview=%@",
              BrowserPressTypeString(press.type),
              BrowserPressPhaseString(press.phase),
              [self.host browserRemoteInputControllerPresentedViewController] == nil ? @"(nil)" : NSStringFromClass([[self.host browserRemoteInputControllerPresentedViewController] class]),
              [self.host browserRemoteInputControllerTabOverviewVisible] ? @"YES" : @"NO");
    }

    if ([self releaseArrowPresses:presses]) {
        return YES;
    }

    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypeDownArrow) {
            [self.host browserRemoteInputControllerDeactivateTopBarFocus];
            return YES;
        }
        if (press.type == UIPressTypePlayPause) {
            return YES;
        }
        if (press.type == UIPressTypeSelect ||
            press.type == UIPressTypeLeftArrow ||
            press.type == UIPressTypeRightArrow ||
            press.type == UIPressTypeUpArrow) {
            return NO;
        }
    }

    UIViewController *presentedViewController = [self.host browserRemoteInputControllerPresentedViewController];
    if (presentedViewController != nil && ![presentedViewController isKindOfClass:[UIAlertController class]]) {
        if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
            if (press.type == UIPressTypeMenu) {
                [self.host browserRemoteInputControllerDismissTabOverview];
                return YES;
            }
            if (press.type == UIPressTypePlayPause) {
                [self.host browserRemoteInputControllerHandleTabOverviewAlternateAction];
                return YES;
            }
            return NO;
        }
        if (press.type == UIPressTypeMenu) {
            [presentedViewController dismissViewControllerAnimated:YES completion:nil];
            return YES;
        }
        return YES;
    }

    if (press.type == UIPressTypeSelect) {
        self.lastDirectSelectPressTimestamp = CACurrentMediaTime();
        self.directSelectPending = YES;
        [self handleSelectPressEnded];
        return YES;
    }

    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause) {
            [self.host browserRemoteInputControllerDismissTabOverview];
            return YES;
        }
        if (press.type == UIPressTypeSelect) {
            [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
            return YES;
        }
    }

    if (press.type == UIPressTypeMenu) {
        [self.host browserRemoteInputControllerHandleMenuPress];
        return YES;
    }
    if (press.type == UIPressTypePlayPause) {
        [self.host browserRemoteInputControllerHandlePlayPausePress];
        return YES;
    }
    return NO;
}

- (BOOL)handleTouches {
    // The touch surface is intentionally ignored: the pointer is driven by the
    // arrows only. Swallow touches so the page doesn't react to them either.
    return self.cursorModeEnabled &&
        ![self.host browserRemoteInputControllerTopBarFocusActive] &&
        ![self.host browserRemoteInputControllerTabOverviewVisible];
}

@end
