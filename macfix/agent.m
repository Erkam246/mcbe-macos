// Agent socket: line-delimited JSON over TCP on 127.0.0.1:$MACFIX_AGENT_PORT,
// the protocol of the bedrock-mc mcpelauncher fork's --agent-socket. Input is
// injected through the game's own GameController and pointer handlers on the
// main thread; frames are copied from the drawable right before present.
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <netinet/in.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <sys/socket.h>

extern CAFrameRateRange macfixGameFrameRate;

static CAFrameRateRange defaultFrameRate;  // macfix's rate, restored by cap 0
static int fpsCap;             // 0 = macfix default; main thread only
static double mouseX, mouseY;  // last absolute position, in screenshot pixels; main thread only

#pragma mark - Game objects

static UIViewController *gameViewController(void) {
    id delegate = UIApplication.sharedApplication.delegate;
    SEL sel = sel_registerName("viewController");
    return [delegate respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(delegate, sel) : nil;
}

static UIView *findFirstResponder(UIView *view) {
    if (view.isFirstResponder) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *found = findFirstResponder(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

// The focused text input (chat, sign, text fields), if any.
static UIView<UIKeyInput> *focusedTextInput(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *view = findFirstResponder(window);
            if ([view conformsToProtocol:@protocol(UIKeyInput)]) {
                return (UIView<UIKeyInput> *)view;
            }
        }
    }
    return nil;
}

#pragma mark - Frames

static atomic_bool captureRequested;
static dispatch_semaphore_t captureDone;
static id<MTLTexture> captureTexture;  // written by the render thread before captureDone signals
static atomic_int frameWidth, frameHeight;
static atomic_int presentsInWindow;
static _Atomic double windowStart, lastPresent, measuredFps;
static IMP origPresentDrawable;

static double now(void) {
    return CACurrentMediaTime();
}

static void countPresent(void) {
    double t = now();
    lastPresent = t;
    int n = atomic_fetch_add(&presentsInWindow, 1) + 1;
    double start = windowStart;
    if (t - start >= 1.0) {
        measuredFps = n / (t - start);
        presentsInWindow = 0;
        windowStart = t;
    }
}

static double currentFps(void) {
    return now() - lastPresent > 1.0 ? 0 : measuredFps;
}

static void presentDrawable(id self, SEL _cmd, id<MTLDrawable> drawable) {
    countPresent();
    if ([drawable conformsToProtocol:@protocol(CAMetalDrawable)]) {
        id<CAMetalDrawable> metal = (id<CAMetalDrawable>)drawable;
        id<MTLTexture> src = metal.texture;
        frameWidth = (int)src.width;
        frameHeight = (int)src.height;
        if (src.framebufferOnly) {
            // Readback needs a blittable drawable; this applies from the next one on.
            static atomic_flag once = ATOMIC_FLAG_INIT;
            if (!atomic_flag_test_and_set(&once)) {
                CAMetalLayer *layer = metal.layer;
                dispatch_async(dispatch_get_main_queue(), ^{
                    layer.framebufferOnly = NO;
                    NSLog(@"[macfix] agent: drawable readback enabled");
                });
            }
        } else if (atomic_exchange(&captureRequested, false)) {
            id<MTLCommandBuffer> buffer = self;
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                                            width:src.width
                                                                                           height:src.height
                                                                                        mipmapped:NO];
            desc.usage = MTLTextureUsageShaderRead;
            desc.storageMode = MTLStorageModePrivate;
            id<MTLTexture> copy = [buffer.device newTextureWithDescriptor:desc];
            id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
            [blit copyFromTexture:src toTexture:copy];
            [blit endEncoding];
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
                captureTexture = copy;
                dispatch_semaphore_signal(captureDone);
            }];
        }
    }
    ((void (*)(id, SEL, id))origPresentDrawable)(self, _cmd, drawable);
}

// The game's command buffers are a private driver class; hook the
// implementation that a buffer from the default device resolves to.
static void installPresentHook(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandBuffer> buffer = [[device newCommandQueue] commandBuffer];
    Method m = buffer ? class_getInstanceMethod([buffer class], @selector(presentDrawable:)) : NULL;
    if (!m) {
        NSLog(@"[macfix] agent: no presentDrawable: to hook, screenshots disabled");
        return;
    }
    origPresentDrawable = method_setImplementation(m, (IMP)presentDrawable);
    NSLog(@"[macfix] agent: present hook on %@", NSStringFromClass([buffer class]));
}

static NSData *encodePNG(CGImageRef image) {
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dest, image, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? data : nil;
}

static NSDictionary *screenshot(NSDictionary *req) {
    captureRequested = true;
    if (dispatch_semaphore_wait(captureDone, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        captureRequested = false;
        return @{@"ok": @NO, @"error": @"no frame rendered within 3s"};
    }
    id<MTLTexture> texture = captureTexture;
    captureTexture = nil;
    int srcW = (int)texture.width, srcH = (int)texture.height;
    int w = [req[@"width"] intValue], h = [req[@"height"] intValue];
    if (w <= 0 && h <= 0) {
        w = srcW;
        h = srcH;
    } else if (w <= 0) {
        w = MAX(1, srcW * h / srcH);
    } else if (h <= 0) {
        h = MAX(1, srcH * w / srcW);
    }
    w = MIN(w, srcW);
    h = MIN(h, srcH);

    static CIContext *context;
    static CGColorSpaceRef srgb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithMTLDevice:texture.device];
        srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    });
    // Metal textures are top-down; Core Image is bottom-up.
    CIImage *image = [[CIImage imageWithMTLTexture:texture options:@{kCIImageColorSpace: (__bridge id)srgb}]
        imageByApplyingOrientation:kCGImagePropertyOrientationDownMirrored];
    CGImageRef full = [context createCGImage:image fromRect:image.extent format:kCIFormatBGRA8 colorSpace:srgb];
    CGContextRef bitmap = CGBitmapContextCreate(NULL, w, h, 8, 0, srgb, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextSetInterpolationQuality(bitmap, kCGInterpolationHigh);
    CGContextDrawImage(bitmap, CGRectMake(0, 0, w, h), full);
    CGImageRef scaled = CGBitmapContextCreateImage(bitmap);
    NSData *png = encodePNG(scaled);
    CGImageRelease(scaled);
    CGContextRelease(bitmap);
    CGImageRelease(full);
    if (!png) {
        return @{@"ok": @NO, @"error": @"PNG encoding failed"};
    }
    return @{@"ok": @YES, @"width": @(w), @"height": @(h), @"source_width": @(srcW), @"source_height": @(srcH),
             @"png_base64": [png base64EncodedStringWithOptions:0]};
}

#pragma mark - Input

static void onMain(double delayMs, dispatch_block_t block) {
    if (delayMs <= 0) {
        dispatch_async(dispatch_get_main_queue(), block);
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), block);
    }
}

static id syncOnMain(id (^block)(void)) {
    __block id result;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = block(); });
    return result;
}

static GCKeyCode keyCodeFromName(NSString *name) {
    name = name.lowercaseString;
    if (name.length == 1) {
        unichar c = [name characterAtIndex:0];
        if (c >= 'a' && c <= 'z') {
            return GCKeyCodeKeyA + (c - 'a');
        }
        if (c >= '1' && c <= '9') {
            return GCKeyCodeOne + (c - '1');
        }
        if (c == '0') {
            return GCKeyCodeZero;
        }
        if (c == ' ') {
            return GCKeyCodeSpacebar;
        }
    }
    if (name.length >= 2 && [name characterAtIndex:0] == 'f') {
        int n = [name substringFromIndex:1].intValue;
        if (n >= 1 && n <= 12) {
            return GCKeyCodeF1 + (n - 1);
        }
    }
    static NSDictionary<NSString *, NSNumber *> *named;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        named = @{
            @"space": @(GCKeyCodeSpacebar), @"enter": @(GCKeyCodeReturnOrEnter), @"return": @(GCKeyCodeReturnOrEnter),
            @"escape": @(GCKeyCodeEscape), @"esc": @(GCKeyCodeEscape), @"tab": @(GCKeyCodeTab),
            @"backspace": @(GCKeyCodeDeleteOrBackspace), @"delete": @(GCKeyCodeDeleteForward), @"insert": @(GCKeyCodeInsert),
            @"shift": @(GCKeyCodeLeftShift), @"lshift": @(GCKeyCodeLeftShift), @"rshift": @(GCKeyCodeRightShift),
            @"ctrl": @(GCKeyCodeLeftControl), @"lctrl": @(GCKeyCodeLeftControl), @"rctrl": @(GCKeyCodeRightControl),
            @"alt": @(GCKeyCodeLeftAlt), @"lalt": @(GCKeyCodeLeftAlt), @"ralt": @(GCKeyCodeRightAlt),
            @"super": @(GCKeyCodeLeftGUI), @"cmd": @(GCKeyCodeLeftGUI), @"meta": @(GCKeyCodeLeftGUI),
            @"up": @(GCKeyCodeUpArrow), @"down": @(GCKeyCodeDownArrow), @"left": @(GCKeyCodeLeftArrow), @"right": @(GCKeyCodeRightArrow),
            @"home": @(GCKeyCodeHome), @"end": @(GCKeyCodeEnd), @"pageup": @(GCKeyCodePageUp), @"pagedown": @(GCKeyCodePageDown),
            @"capslock": @(GCKeyCodeCapsLock), @"pause": @(GCKeyCodePause),
            @"comma": @(GCKeyCodeComma), @"period": @(GCKeyCodePeriod), @"slash": @(GCKeyCodeSlash),
            @"semicolon": @(GCKeyCodeSemicolon), @"apostrophe": @(GCKeyCodeQuote), @"minus": @(GCKeyCodeHyphen),
            @"equal": @(GCKeyCodeEqualSign), @"grave": @(GCKeyCodeGraveAccentAndTilde), @"lbracket": @(GCKeyCodeOpenBracket),
            @"rbracket": @(GCKeyCodeCloseBracket), @"backslash": @(GCKeyCodeBackslash),
        };
    });
    return named[name].integerValue;
}

// Delivers a key the way GameController does; the game only listens to the handler.
static void sendKey(GCKeyCode code, BOOL pressed) {
    GCKeyboardInput *input = GCKeyboard.coalescedKeyboard.keyboardInput;
    GCKeyboardValueChangedHandler handler = input.keyChangedHandler;
    if (handler) {
        handler(input, [input buttonForKeyCode:code], code, pressed);
    }
}

// With a text field focused, Return and Backspace edit or submit through UIKit, not GameController.
static void sendTextKey(GCKeyCode code) {
    UIView<UIKeyInput> *input = focusedTextInput();
    if (!input) {
        return;
    }
    if (code == GCKeyCodeDeleteOrBackspace) {
        [input deleteBackward];
    } else if (code == GCKeyCodeReturnOrEnter) {
        SEL setPhysical = sel_registerName("setPhysicalReturnPressed:");
        BOOL physical = [input respondsToSelector:setPhysical];
        if (physical) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(input, setPhysical, YES);
        }
        [input insertText:@"\n"];
        if (physical) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(input, setPhysical, NO);
        }
    }
}

static NSDictionary *handleKey(NSDictionary *req) {
    GCKeyCode code = keyCodeFromName(req[@"key"] ?: @"");
    if (code == 0) {
        return @{@"ok": @NO, @"error": @"unknown key"};
    }
    NSNumber *ready = syncOnMain(^id { return @(GCKeyboard.coalescedKeyboard.keyboardInput.keyChangedHandler != nil); });
    if (!ready.boolValue) {
        return @{@"ok": @NO, @"error": @"the game has no keyboard handler yet"};
    }
    NSMutableArray<NSNumber *> *mods = [NSMutableArray array];
    for (NSString *m in [req[@"mods"] isKindOfClass:[NSArray class]] ? req[@"mods"] : @[]) {
        GCKeyCode mc = [m isEqual:@"super"] ? GCKeyCodeLeftGUI : keyCodeFromName(m);
        if (mc) {
            [mods addObject:@(mc)];
        }
    }
    NSString *action = req[@"action"] ?: @"tap";
    double hold = req[@"hold_ms"] ? [req[@"hold_ms"] doubleValue] : 60;
    BOOL tap = [action isEqual:@"tap"];
    if (tap || [action isEqual:@"press"]) {
        onMain(0, ^{
            for (NSNumber *m in mods) {
                sendKey(m.integerValue, YES);
            }
            sendKey(code, YES);
            sendTextKey(code);
        });
    }
    if (tap || [action isEqual:@"release"]) {
        onMain(tap ? hold : 0, ^{
            sendKey(code, NO);
            for (NSNumber *m in mods.reverseObjectEnumerator) {
                sendKey(m.integerValue, NO);
            }
        });
    }
    return @{@"ok": @YES};
}

static NSDictionary *handleText(NSDictionary *req) {
    NSString *text = req[@"text"] ?: @"";
    return syncOnMain(^id {
        UIView<UIKeyInput> *input = focusedTextInput();
        if (!input) {
            return @{@"ok": @NO, @"error": @"no text field is focused (open chat or click a text box first)"};
        }
        [input insertText:text];
        return @{@"ok": @YES};
    });
}

// Stands in for the UIPointerRegionRequest the game's hover handler reads.
@interface MacfixPointerRequest : NSObject
@property(nonatomic) CGPoint location;
@end
@implementation MacfixPointerRequest
@end

static CGPoint pixelsToPoints(UIView *view, double x, double y) {
    int w = frameWidth;
    double scale = w > 0 ? view.bounds.size.width / w : 1;
    return CGPointMake(x * scale, y * scale);
}

static NSString *movePointer(double x, double y) {
    UIViewController *vc = gameViewController();
    SEL sel = sel_registerName("pointerInteraction:regionForRequest:defaultRegion:");
    if (![vc respondsToSelector:sel]) {
        return @"the game view is not ready";
    }
    mouseX = x;
    mouseY = y;
    MacfixPointerRequest *request = [MacfixPointerRequest new];
    request.location = pixelsToPoints(vc.view, x, y);
    ((id (*)(id, SEL, id, id, id))objc_msgSend)(vc, sel, nil, request, nil);
    return nil;
}

static GCControllerButtonInput *mouseButton(int button) {
    GCMouseInput *input = GCMouse.current.mouseInput;
    switch (button) {
        case 2: return input.rightButton;
        case 3: return input.middleButton;
        default: return input.leftButton;
    }
}

static void sendButton(int button, BOOL pressed) {
    GCControllerButtonInput *b = mouseButton(button);
    GCControllerButtonValueChangedHandler handler = b.valueChangedHandler;
    if (handler) {
        handler(b, pressed ? 1 : 0, pressed);
    }
}

static int buttonFromRequest(NSDictionary *req) {
    id b = req[@"button"];
    if ([b isKindOfClass:[NSNumber class]]) {
        return [b intValue];
    }
    if ([b isEqual:@"right"]) {
        return 2;
    }
    if ([b isEqual:@"middle"]) {
        return 3;
    }
    return 1;
}

static NSDictionary *handleClick(NSDictionary *req) {
    int button = buttonFromRequest(req);
    NSString *error = syncOnMain(^id {
        if (!mouseButton(button).valueChangedHandler) {
            return GCMouse.current ? @"the game has no handler for that mouse button" : @"no mouse connected";
        }
        if (req[@"x"] && req[@"y"]) {
            return movePointer([req[@"x"] doubleValue], [req[@"y"] doubleValue]);
        }
        return nil;
    });
    if (error) {
        return @{@"ok": @NO, @"error": error};
    }
    // The UI hit-tests against the pointer position it saw last frame; let the move land first.
    double settle = req[@"x"] && req[@"y"] ? (req[@"settle_ms"] ? [req[@"settle_ms"] doubleValue] : 300) : 0;
    NSString *action = req[@"action"] ?: @"tap";
    double hold = req[@"hold_ms"] ? [req[@"hold_ms"] doubleValue] : 60;
    BOOL tap = [action isEqual:@"tap"];
    if (tap || [action isEqual:@"press"]) {
        onMain(settle, ^{ sendButton(button, YES); });
    }
    if (tap || [action isEqual:@"release"]) {
        onMain(tap ? settle + hold : 0, ^{ sendButton(button, NO); });
    }
    return @{@"ok": @YES};
}

static NSDictionary *handleMouseMove(NSDictionary *req) {
    float dx = [req[@"dx"] floatValue], dy = [req[@"dy"] floatValue];
    return syncOnMain(^id {
        GCMouseInput *input = GCMouse.current.mouseInput;
        GCMouseMoved handler = input.mouseMovedHandler;
        if (!handler) {
            return @{@"ok": @NO, @"error": input ? @"the game has no mouse-move handler" : @"no mouse connected"};
        }
        // GameController deltas are y-up; the protocol's are screen-space.
        handler(input, dx, -dy);
        return @{@"ok": @YES};
    });
}

static NSDictionary *handleScroll(NSDictionary *req) {
    float dy = [req[@"dy"] floatValue];
    return syncOnMain(^id {
        GCDeviceCursor *scroll = GCMouse.current.mouseInput.scroll;
        GCControllerDirectionPadValueChangedHandler handler = scroll.valueChangedHandler;
        if (!handler) {
            return @{@"ok": @NO, @"error": @"the game has no scroll handler"};
        }
        // The game reads the wheel from the first value only (one notch per event, by sign); no horizontal scroll.
        handler(scroll, dy, 0);
        return @{@"ok": @YES};
    });
}

#pragma mark - Commands

static void applyFrameCap(int cap) {
    fpsCap = MAX(cap, 0);
    macfixGameFrameRate = fpsCap > 0 ? CAFrameRateRangeMake(fpsCap, fpsCap, fpsCap) : defaultFrameRate;
    UIViewController *vc = gameViewController();
    SEL sel = sel_registerName("displayLink");
    CADisplayLink *link = [vc respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(vc, sel) : nil;
    if ([link isKindOfClass:[CADisplayLink class]]) {
        link.preferredFrameRateRange = macfixGameFrameRate;
    }
}

static NSDictionary *state(void) {
    return syncOnMain(^id {
        UIViewController *vc = gameViewController();
        UIWindow *window = vc.view.window;
        BOOL focused = UIApplication.sharedApplication.applicationState == UIApplicationStateActive && window.isKeyWindow;
        // True only while macOS actually captures the pointer (full screen); the game asks for it in-world.
        BOOL locked = window.windowScene.pointerLockState.isLocked;
        BOOL wantsLock = [vc respondsToSelector:@selector(prefersPointerLocked)] && vc.prefersPointerLocked;
        BOOL typing = focusedTextInput() != nil;
        return @{@"ok": @YES, @"width": @(frameWidth), @"height": @(frameHeight), @"focused": @(focused),
                 @"fps": @(round(currentFps() * 10) / 10), @"fps_cap": @(fpsCap), @"cursor_locked": @(locked),
                 @"pointer_lock_requested": @(wantsLock), @"text_input": @(typing),
                 @"mouse_x": @(mouseX), @"mouse_y": @(mouseY)};
    });
}

static NSDictionary *handleURI(NSDictionary *req) {
    NSString *uri = req[@"uri"] ?: @"";
    if (![uri hasPrefix:@"minecraft:"]) {
        return @{@"ok": @NO, @"error": @"uri must start with minecraft:"};
    }
    NSURL *url;
    if (@available(macCatalyst 17.0, *)) {
        url = [NSURL URLWithString:uri encodingInvalidCharacters:YES];  // add_server links carry a raw '|'
    } else {
        url = [NSURL URLWithString:uri];
    }
    if (!url) {
        return @{@"ok": @NO, @"error": @"invalid uri"};
    }
    return syncOnMain(^id {
        UIApplication *app = UIApplication.sharedApplication;
        id<UIApplicationDelegate> delegate = app.delegate;
        if (![delegate respondsToSelector:@selector(application:openURL:options:)]) {
            return @{@"ok": @NO, @"error": @"the game does not handle URLs"};
        }
        BOOL handled = [delegate application:app openURL:url options:@{}];
        return @{@"ok": @YES, @"handled": @(handled)};
    });
}

static NSDictionary *handle(NSDictionary *req) {
    NSString *cmd = req[@"cmd"];
    if ([cmd isEqual:@"ping"]) {
        return @{@"ok": @YES};
    }
    if ([cmd isEqual:@"state"]) {
        return state();
    }
    if ([cmd isEqual:@"screenshot"]) {
        return screenshot(req);
    }
    if ([cmd isEqual:@"key"]) {
        return handleKey(req);
    }
    if ([cmd isEqual:@"text"]) {
        return handleText(req);
    }
    if ([cmd isEqual:@"mouse_move"]) {
        return handleMouseMove(req);
    }
    if ([cmd isEqual:@"mouse_pos"]) {
        double x = [req[@"x"] doubleValue], y = [req[@"y"] doubleValue];
        NSString *error = syncOnMain(^id { return movePointer(x, y); });
        return error ? @{@"ok": @NO, @"error": error} : @{@"ok": @YES};
    }
    if ([cmd isEqual:@"click"]) {
        return handleClick(req);
    }
    if ([cmd isEqual:@"scroll"]) {
        return handleScroll(req);
    }
    if ([cmd isEqual:@"uri"]) {
        return handleURI(req);
    }
    if ([cmd isEqual:@"fps"]) {
        int cap = [req[@"cap"] intValue];
        return syncOnMain(^id {
            applyFrameCap(cap);
            return @{@"ok": @YES, @"fps_cap": @(fpsCap)};
        });
    }
    if ([cmd isEqual:@"quit"]) {
        // The app menu's Quit path, so the game saves and shuts down normally.
        onMain(0, ^{
            id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
            ((void (*)(id, SEL, id))objc_msgSend)(app, sel_registerName("terminate:"), nil);
        });
        return @{@"ok": @YES};
    }
    return @{@"ok": @NO, @"error": @"unknown cmd"};
}

#pragma mark - Server

static BOOL sendAll(int fd, NSData *data) {
    const uint8_t *p = data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = send(fd, p, left, 0);
        if (n <= 0) {
            return NO;
        }
        p += n;
        left -= (size_t)n;
    }
    return YES;
}

static NSData *replyLine(NSDictionary *res) {
    NSMutableData *out = [[NSJSONSerialization dataWithJSONObject:res options:0 error:NULL] mutableCopy];
    [out appendBytes:"\n" length:1];
    return out;
}

static void serveClient(int fd) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    NSMutableData *buf = [NSMutableData data];
    char chunk[4096];
    for (;;) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) {
            break;
        }
        [buf appendBytes:chunk length:(NSUInteger)n];
        for (;;) {
            NSRange nl = [buf rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buf.length)];
            if (nl.location == NSNotFound) {
                break;
            }
            NSData *line = [buf subdataWithRange:NSMakeRange(0, nl.location)];
            [buf replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
            if (line.length == 0) {
                continue;
            }
            @autoreleasepool {
                NSDictionary *res;
                id req = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
                if (![req isKindOfClass:[NSDictionary class]]) {
                    res = @{@"ok": @NO, @"error": @"invalid JSON"};
                } else {
                    @try {
                        res = handle(req);
                    } @catch (NSException *e) {
                        res = @{@"ok": @NO, @"error": e.reason ?: e.name};
                    }
                    if (req[@"id"]) {
                        NSMutableDictionary *withId = [res mutableCopy];
                        withId[@"id"] = req[@"id"];
                        res = withId;
                    }
                }
                if (!sendAll(fd, replyLine(res))) {
                    close(fd);
                    return;
                }
            }
        }
    }
    close(fd);
}

void agentStart(void) {
    const char *portEnv = getenv("MACFIX_AGENT_PORT");
    int port = portEnv ? atoi(portEnv) : 0;
    if (port <= 0 || port > 65535) {
        return;
    }
    captureDone = dispatch_semaphore_create(0);
    defaultFrameRate = macfixGameFrameRate;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {.sin_len = sizeof(addr), .sin_family = AF_INET, .sin_port = htons(port),
                               .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 4) < 0) {
        NSLog(@"[macfix] agent: cannot listen on 127.0.0.1:%d: %s", port, strerror(errno));
        if (fd >= 0) {
            close(fd);
        }
        return;
    }
    NSLog(@"[macfix] agent: listening on 127.0.0.1:%d", port);
    dispatch_async(dispatch_get_main_queue(), ^{ installPresentHook(); });
    [NSThread detachNewThreadWithBlock:^{
        for (;;) {
            int client = accept(fd, NULL, NULL);
            if (client >= 0) {
                [NSThread detachNewThreadWithBlock:^{ serveClient(client); }];
            }
        }
    }];
}
