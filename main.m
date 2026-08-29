// ClaudeUsageBar — a macOS menu bar gauge for Claude plan usage.
//
// Menu bar shows a battery-style meter for whichever limit is closest to its
// cap. Click for a popover with one row per limit, mirroring the desktop app's
// "Plan usage limits" panel.
//
// Data: GET https://api.anthropic.com/api/oauth/usage
// Auth: the OAuth token Claude Code stores in the login Keychain under the
//       service "Claude Code-credentials" (key claudeAiOauth.accessToken).
//
// Objective-C rather than Swift on purpose: it compiles against the SDK's C
// headers, so it is immune to swiftinterface/compiler version mismatches on
// stock Command Line Tools installs.

#import <Cocoa/Cocoa.h>

static NSString *const kUsageURL   = @"https://api.anthropic.com/api/oauth/usage";
static NSString *const kProfileURL = @"https://api.anthropic.com/api/oauth/profile";
// Deliberately conservative. This endpoint is internal and rate limited; it is
// not built for polling. Opening the popover reuses data under 60s old rather
// than making a request.
static const NSTimeInterval kRefreshInterval = 900.0;   // 15 minutes
static const NSTimeInterval kFreshnessWindow = 60.0;

typedef NS_ENUM(NSInteger, UsageState) {
    UsageStateLoading,
    UsageStateOK,
    UsageStateNoCredentials,
    UsageStateExpired,
    UsageStateError
};

#pragma mark - Model

@interface LimitInfo : NSObject
@property (nonatomic, copy)   NSString *title;
@property (nonatomic)         double    fraction;   // 0...1
@property (nonatomic, strong) NSDate   *resets;
@property (nonatomic, copy)   NSString *severity;
@end

@implementation LimitInfo
@end

#pragma mark - Credentials

static NSString *RunSecurity(NSString *service) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/security"];
    task.arguments = @[@"find-generic-password", @"-s", service, @"-w"];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSPipe pipe];

    NSError *err = nil;
    if (![task launchAndReturnError:&err]) return nil;
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL IsHexString(NSString *s) {
    if (s.length == 0 || s.length % 2 != 0) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    NSCharacterSet *other = [hex invertedSet];
    return [s rangeOfCharacterFromSet:other].location == NSNotFound;
}

static NSString *DecodeHex(NSString *s) {
    NSMutableData *bytes = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < s.length; i += 2) {
        NSString *pair = [s substringWithRange:NSMakeRange(i, 2)];
        unsigned int value = 0;
        [[NSScanner scannerWithString:pair] scanHexInt:&value];
        unsigned char b = (unsigned char)value;
        [bytes appendBytes:&b length:1];
    }
    return [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
}

static NSString *TokenFromJSONText(NSString *text) {
    if (text.length == 0) return nil;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *dict = obj;
    id inner = dict[@"claudeAiOauth"];
    if ([inner isKindOfClass:[NSDictionary class]]) {
        id t = ((NSDictionary *)inner)[@"accessToken"];
        if ([t isKindOfClass:[NSString class]] && [t length] > 0) return t;
    }
    id t2 = dict[@"accessToken"];
    if ([t2 isKindOfClass:[NSString class]] && [t2 length] > 0) return t2;
    return nil;
}

static NSString *ReadOAuthToken(void) {
    NSArray *services = @[@"Claude Code-credentials", @"Claude Code"];
    for (NSString *service in services) {
        NSString *raw = RunSecurity(service);
        if (raw.length == 0) continue;
        raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (raw.length == 0) continue;

        // `security` prints hex when the blob isn't printable text.
        if (![raw hasPrefix:@"{"] && IsHexString(raw)) {
            NSString *decoded = DecodeHex(raw);
            if (decoded) raw = decoded;
        }
        NSString *token = TokenFromJSONText(raw);
        if (token) return token;
    }

    NSString *path = [@"~/.claude/.credentials.json" stringByExpandingTildeInPath];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    return TokenFromJSONText(text);
}

#pragma mark - Parsing

static NSDate *ParseDate(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        double n = [value doubleValue];
        return [NSDate dateWithTimeIntervalSince1970:(n > 1e12 ? n / 1000.0 : n)];
    }
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *s = value;
    if (s.length == 0) return nil;

    // The API sends 6-digit fractional seconds; strip them for the plain parse.
    static NSRegularExpression *frac = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        frac = [NSRegularExpression regularExpressionWithPattern:@"\\.\\d+" options:0 error:NULL];
    });
    NSString *stripped = [frac stringByReplacingMatchesInString:s
                                                        options:0
                                                          range:NSMakeRange(0, s.length)
                                                   withTemplate:@""];

    NSISO8601DateFormatter *f = [[NSISO8601DateFormatter alloc] init];
    f.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSDate *d = [f dateFromString:stripped];
    if (d) return d;

    NSISO8601DateFormatter *f2 = [[NSISO8601DateFormatter alloc] init];
    f2.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return [f2 dateFromString:s];
}

static NSString *Prettify(NSString *key) {
    NSString *spaced = [key stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    if (spaced.length == 0) return spaced;
    return [[[spaced substringToIndex:1] uppercaseString]
            stringByAppendingString:[spaced substringFromIndex:1]];
}

static NSNumber *Numeric(id value) {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static NSArray<LimitInfo *> *ParseLimits(id root) {
    if (![root isKindOfClass:[NSDictionary class]]) return @[];
    NSDictionary *dict = root;
    NSMutableArray<LimitInfo *> *out = [NSMutableArray array];

    id arr = dict[@"limits"];
    if ([arr isKindOfClass:[NSArray class]] && [arr count] > 0) {
        for (id element in (NSArray *)arr) {
            if (![element isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *item = element;
            NSNumber *pct = Numeric(item[@"percent"]);
            if (!pct) continue;

            NSString *kind = [item[@"kind"] isKindOfClass:[NSString class]] ? item[@"kind"] : @"";
            NSString *title;
            if ([kind isEqualToString:@"session"]) {
                title = @"5-hour limit";
            } else if ([kind isEqualToString:@"weekly_all"]) {
                title = @"Weekly · all models";
            } else if ([kind isEqualToString:@"weekly_scoped"]) {
                NSString *name = @"scoped";
                id scope = item[@"scope"];
                if ([scope isKindOfClass:[NSDictionary class]]) {
                    id model = ((NSDictionary *)scope)[@"model"];
                    id surface = ((NSDictionary *)scope)[@"surface"];
                    if ([model isKindOfClass:[NSDictionary class]] &&
                        [((NSDictionary *)model)[@"display_name"] isKindOfClass:[NSString class]]) {
                        name = ((NSDictionary *)model)[@"display_name"];
                    } else if ([surface isKindOfClass:[NSDictionary class]] &&
                               [((NSDictionary *)surface)[@"display_name"] isKindOfClass:[NSString class]]) {
                        name = ((NSDictionary *)surface)[@"display_name"];
                    }
                }
                title = [NSString stringWithFormat:@"Weekly · %@", name];
            } else {
                title = Prettify(kind);
            }

            LimitInfo *limit = [[LimitInfo alloc] init];
            limit.title = title;
            limit.fraction = MAX(0.0, MIN(1.0, [pct doubleValue] / 100.0));
            limit.resets = ParseDate(item[@"resets_at"]);
            limit.severity = [item[@"severity"] isKindOfClass:[NSString class]] ? item[@"severity"] : @"normal";
            [out addObject:limit];
        }
        if (out.count > 0) return out;
    }

    // Fallback shape.
    NSArray *fallback = @[@[@"five_hour", @"5-hour limit"],
                          @[@"seven_day", @"Weekly · all models"],
                          @[@"seven_day_opus", @"Weekly · Opus"]];
    for (NSArray *pair in fallback) {
        id obj = dict[pair[0]];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *pct = Numeric(((NSDictionary *)obj)[@"utilization"]);
        if (!pct) continue;
        LimitInfo *limit = [[LimitInfo alloc] init];
        limit.title = pair[1];
        limit.fraction = MAX(0.0, MIN(1.0, [pct doubleValue] / 100.0));
        limit.resets = ParseDate(((NSDictionary *)obj)[@"resets_at"]);
        limit.severity = @"normal";
        [out addObject:limit];
    }
    return out;
}

static NSString *PrettyPlan(NSString *tier) {
    if (![tier isKindOfClass:[NSString class]] || tier.length == 0) return nil;
    if ([tier isEqualToString:@"default_claude_max_20x"]) return @"Max (20x)";
    if ([tier isEqualToString:@"default_claude_max_5x"])  return @"Max (5x)";
    if ([tier isEqualToString:@"default_claude_pro"])     return @"Pro";
    NSString *s = [tier stringByReplacingOccurrencesOfString:@"default_" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"claude_" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    return [s capitalizedString];
}

#pragma mark - Formatting

static NSString *ResetText(NSDate *date) {
    if (!date) return @"";
    NSTimeInterval delta = [date timeIntervalSinceNow];
    if (delta <= 0) return @"Resets soon";
    if (delta < 24 * 3600) {
        NSInteger total = (NSInteger)delta;
        NSInteger h = total / 3600;
        NSInteger m = (total % 3600) / 60;
        if (h > 0) return [NSString stringWithFormat:@"Resets in %ld hr %ld min", (long)h, (long)m];
        return [NSString stringWithFormat:@"Resets in %ld min", (long)m];
    }
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"EEE h:mm a";
    return [@"Resets " stringByAppendingString:[f stringFromDate:date]];
}

static NSColor *ColorForLimit(LimitInfo *limit) {
    if ([limit.severity isEqualToString:@"critical"]) return [NSColor systemRedColor];
    if ([limit.severity isEqualToString:@"warning"])  return [NSColor systemOrangeColor];
    if (limit.fraction >= 0.90) return [NSColor systemRedColor];
    if (limit.fraction >= 0.75) return [NSColor systemOrangeColor];
    return [NSColor systemBlueColor];
}

#pragma mark - Menu bar gauge

static NSImage *GaugeImage(NSNumber *fraction, NSColor *tint) {
    CGFloat w = 25, h = 13;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [image lockFocus];

    NSColor *outline = [[NSColor labelColor] colorWithAlphaComponent:0.55];
    NSRect body = NSMakeRect(0.5, 1.5, w - 4.5, h - 3);
    NSBezierPath *bodyPath = [NSBezierPath bezierPathWithRoundedRect:body xRadius:3 yRadius:3];
    bodyPath.lineWidth = 1;
    [outline setStroke];
    [bodyPath stroke];

    NSBezierPath *cap = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(w - 3.2, h / 2 - 2, 2.2, 4)
                                                        xRadius:1 yRadius:1];
    [outline setFill];
    [cap fill];

    if (fraction) {
        NSRect inner = NSInsetRect(body, 2, 2);
        CGFloat f = MAX(0.0, MIN(1.0, [fraction doubleValue]));
        CGFloat fw = f * inner.size.width;
        if (fw > 0.75) {
            NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:
                                  NSMakeRect(NSMinX(inner), NSMinY(inner), fw, inner.size.height)
                                                                 xRadius:1.5 yRadius:1.5];
            [tint setFill];
            [fill fill];
        }
    } else {
        [outline setFill];
        NSRectFill(NSMakeRect(NSMidX(body) - 3, h / 2 - 0.5, 6, 1));
    }

    [image unlockFocus];
    image.template = NO;
    return image;
}

#pragma mark - Bar view

@interface BarView : NSView
@property (nonatomic)         double   fraction;
@property (nonatomic, strong) NSColor *tint;
@end

@implementation BarView

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat h = 6;
    CGFloat y = (self.bounds.size.height - h) / 2;

    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:
                           NSMakeRect(0, y, self.bounds.size.width, h)
                                                          xRadius:h / 2 yRadius:h / 2];
    [[[NSColor labelColor] colorWithAlphaComponent:0.12] setFill];
    [track fill];

    CGFloat w = MAX(0.0, MIN(1.0, self.fraction)) * self.bounds.size.width;
    if (w > 1) {
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, y, w, h)
                                                             xRadius:h / 2 yRadius:h / 2];
        [(self.tint ?: [NSColor systemBlueColor]) setFill];
        [fill fill];
    }
}

@end

#pragma mark - Popover controller

@interface UsageViewController : NSViewController
@property (nonatomic)         UsageState        state;
@property (nonatomic, strong) NSArray<LimitInfo *> *limits;
@property (nonatomic, copy)   NSString         *plan;
@property (nonatomic, copy)   NSString         *message;
@property (nonatomic, copy)   void (^onRefresh)(void);
- (void)refreshUI;
@end

@implementation UsageViewController {
    CGFloat _width;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _width = 330;
        _state = UsageStateLoading;
        _limits = @[];
    }
    return self;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, _width, 140)];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self refreshUI];
}

- (NSTextField *)labelWithText:(NSString *)text
                          size:(CGFloat)size
                          bold:(BOOL)bold
                          tone:(NSColor *)tone
                         align:(NSTextAlignment)align {
    NSTextField *f = [NSTextField labelWithString:text ?: @""];
    f.font = bold ? [NSFont systemFontOfSize:size weight:NSFontWeightSemibold]
                  : [NSFont systemFontOfSize:size];
    f.textColor = tone;
    f.alignment = align;
    f.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    f.cell.usesSingleLineMode = YES;
    return f;
}

- (NSView *)messageBlock:(NSString *)text width:(CGFloat)width {
    NSFont *font = [NSFont systemFontOfSize:12];
    NSTextField *f = [NSTextField wrappingLabelWithString:text ?: @""];
    f.font = font;
    f.textColor = [NSColor secondaryLabelColor];
    f.preferredMaxLayoutWidth = width;

    NSRect rect = [(text ?: @"") boundingRectWithSize:NSMakeSize(width, 600)
                                              options:NSStringDrawingUsesLineFragmentOrigin |
                                                      NSStringDrawingUsesFontLeading
                                           attributes:@{NSFontAttributeName: font}];
    f.frame = NSMakeRect(0, 0, width, MAX(18.0, ceil(rect.size.height) + 4));
    return f;
}

- (NSView *)limitBlock:(LimitInfo *)limit width:(CGFloat)width {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 42)];

    NSString *pctText = [NSString stringWithFormat:@"%ld%%", (long)lround(limit.fraction * 100)];
    NSTextField *pct = [self labelWithText:pctText size:13 bold:NO
                                      tone:[NSColor secondaryLabelColor]
                                     align:NSTextAlignmentRight];
    pct.frame = NSMakeRect(width - 42, 22, 42, 18);

    NSTextField *reset = [self labelWithText:ResetText(limit.resets) size:12 bold:NO
                                        tone:[NSColor tertiaryLabelColor]
                                       align:NSTextAlignmentRight];
    reset.frame = NSMakeRect(width - 218, 23, 168, 16);

    NSTextField *title = [self labelWithText:limit.title size:14 bold:YES
                                        tone:[NSColor labelColor]
                                       align:NSTextAlignmentLeft];
    title.frame = NSMakeRect(0, 22, width - 224, 18);

    BarView *bar = [[BarView alloc] initWithFrame:NSMakeRect(0, 4, width, 10)];
    bar.fraction = limit.fraction;
    bar.tint = ColorForLimit(limit);

    [container addSubview:title];
    [container addSubview:reset];
    [container addSubview:pct];
    [container addSubview:bar];
    return container;
}

- (void)refreshUI {
    NSView *root = self.view;   // loads the view if needed
    for (NSView *sub in [root.subviews copy]) [sub removeFromSuperview];

    CGFloat pad = 16;
    CGFloat contentWidth = _width - pad * 2;
    NSMutableArray<NSView *> *blocks = [NSMutableArray array];

    NSString *headerText = @"Claude usage";
    if (self.state == UsageStateOK) {
        headerText = self.plan.length
            ? [NSString stringWithFormat:@"Plan usage limits · %@", self.plan]
            : @"Plan usage limits";
    }
    NSTextField *header = [self labelWithText:headerText size:12 bold:NO
                                         tone:[NSColor secondaryLabelColor]
                                        align:NSTextAlignmentLeft];
    header.frame = NSMakeRect(0, 0, contentWidth, 16);
    [blocks addObject:header];

    switch (self.state) {
        case UsageStateLoading:
            [blocks addObject:[self messageBlock:@"Loading…" width:contentWidth]];
            break;
        case UsageStateNoCredentials:
            [blocks addObject:[self messageBlock:
                @"No Claude token found.\nRun `claude` in Terminal and sign in, then refresh."
                                            width:contentWidth]];
            break;
        case UsageStateExpired:
            [blocks addObject:[self messageBlock:
                @"Token expired.\nRun `claude` in Terminal once to refresh it, then refresh here."
                                            width:contentWidth]];
            break;
        case UsageStateError:
            [blocks addObject:[self messageBlock:(self.message ?: @"Something went wrong.")
                                            width:contentWidth]];
            break;
        case UsageStateOK:
            for (LimitInfo *limit in self.limits) {
                [blocks addObject:[self limitBlock:limit width:contentWidth]];
            }
            if (self.message.length) {
                [blocks addObject:[self messageBlock:self.message width:contentWidth]];
            }
            break;
    }

    NSView *footer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, contentWidth, 22)];
    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshTapped)];
    refresh.bezelStyle = NSBezelStyleInline;
    refresh.controlSize = NSControlSizeSmall;
    refresh.font = [NSFont systemFontOfSize:11];
    [refresh sizeToFit];
    refresh.frame = NSMakeRect(0, 0, MAX(62.0, refresh.frame.size.width), 20);
    [footer addSubview:refresh];

    NSButton *quit = [NSButton buttonWithTitle:@"Quit" target:NSApp action:@selector(terminate:)];
    quit.bezelStyle = NSBezelStyleInline;
    quit.controlSize = NSControlSizeSmall;
    quit.font = [NSFont systemFontOfSize:11];
    [quit sizeToFit];
    CGFloat qw = MAX(50.0, quit.frame.size.width);
    quit.frame = NSMakeRect(contentWidth - qw, 0, qw, 20);
    [footer addSubview:quit];
    [blocks addObject:footer];

    CGFloat total = pad * 2;
    for (NSUInteger i = 0; i < blocks.count; i++) {
        total += blocks[i].frame.size.height;
        if (i > 0) total += 12;
    }

    root.frame = NSMakeRect(0, 0, _width, total);
    CGFloat y = total - pad;
    for (NSView *b in blocks) {
        y -= b.frame.size.height;
        b.frame = NSMakeRect(pad, y, b.frame.size.width, b.frame.size.height);
        [root addSubview:b];
        y -= 12;
    }
    self.preferredContentSize = NSMakeSize(_width, total);
}

- (void)refreshTapped {
    if (self.onRefresh) self.onRefresh();
}

@end

#pragma mark - App delegate

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@interface AppDelegate ()
- (void)refreshForced:(BOOL)forced;
- (void)fetchUsageWithToken:(NSString *)token;
- (void)renderState:(UsageState)state
             limits:(NSArray<LimitInfo *> *)limits
            message:(NSString *)message;
- (void)renderDegradedWithNote:(NSString *)note;
- (NSString *)waitNote;
- (void)cacheResponse:(NSData *)data;
- (BOOL)loadCachedResponse;
@end

static NSString *CachePath(void) {
    return [@"~/Library/Application Support/ClaudeUsageBar/last-response.json"
            stringByExpandingTildeInPath];
}

/// Honour a server-supplied Retry-After when there is one.
static NSTimeInterval RetryAfterSeconds(NSHTTPURLResponse *http) {
    if (!http) return 0;
    id value = http.allHeaderFields[@"Retry-After"];
    if (![value isKindOfClass:[NSString class]]) return 0;
    double n = [(NSString *)value doubleValue];
    return (n > 0 && n < 86400) ? n : 0;
}

@implementation AppDelegate {
    NSStatusItem         *_statusItem;
    NSPopover            *_popover;
    UsageViewController  *_controller;
    NSTimer              *_timer;
    NSString             *_planName;

    // Rate-limit discipline. This endpoint is internal and unpublished; it
    // will 429 if polled casually. Cache aggressively, back off on refusal,
    // and keep showing the last good numbers rather than an error.
    NSArray<LimitInfo *> *_lastLimits;
    NSDate               *_lastSuccess;
    NSDate               *_nextAllowed;
    NSTimeInterval        _backoff;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _controller = [[UsageViewController alloc] init];

    _popover = [[NSPopover alloc] init];
    _popover.contentViewController = _controller;
    _popover.behavior = NSPopoverBehaviorTransient;

    _planName = [[NSUserDefaults standardUserDefaults] stringForKey:@"PlanName"];
    _lastLimits = @[];
    _backoff = 0;

    __weak AppDelegate *weakSelf = self;
    _controller.onRefresh = ^{ [weakSelf refreshForced:YES]; };

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.image = GaugeImage(nil, [NSColor systemBlueColor]);
    _statusItem.button.imagePosition = NSImageLeading;
    _statusItem.button.title = @" —";
    _statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    _statusItem.button.target = self;
    _statusItem.button.action = @selector(togglePopover);

    // Show yesterday's numbers immediately rather than an empty popover. This
    // costs no request, and the live fetch below replaces them if it succeeds.
    [self loadCachedResponse];
    [self refreshForced:YES];

    _timer = [NSTimer scheduledTimerWithTimeInterval:kRefreshInterval
                                             repeats:YES
                                               block:^(NSTimer *t) {
        [weakSelf refreshForced:NO];
    }];
}

- (void)togglePopover {
    NSStatusBarButton *button = _statusItem.button;
    if (!button) return;
    if (_popover.isShown) {
        [_popover performClose:nil];
    } else {
        // Opening the popover must not mean a network call every time.
        [self refreshForced:NO];
        [_popover showRelativeToRect:button.bounds ofView:button preferredEdge:NSRectEdgeMinY];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

#pragma mark Networking

- (void)request:(NSString *)urlString
          token:(NSString *)token
           done:(void (^)(NSInteger code, NSData *data, NSError *error,
                          NSHTTPURLResponse *http))done {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { done(0, nil, nil, nil); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 20;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"oauth-2025-04-20" forHTTPHeaderField:@"anthropic-beta"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"ClaudeUsageBar/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                        completionHandler:^(NSData *data,
                                                            NSURLResponse *response,
                                                            NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                                ? (NSHTTPURLResponse *)response : nil;
        done(http ? http.statusCode : 0, data, error, http);
    }];
    [task resume];
}

/// `forced` skips the freshness check (the Refresh button), but never skips an
/// active backoff — retrying into a 429 is what keeps it tripped.
- (void)refreshForced:(BOOL)forced {
    NSDate *now = [NSDate date];

    if (_nextAllowed && [now compare:_nextAllowed] == NSOrderedAscending) {
        [self renderDegradedWithNote:[self waitNote]];
        return;
    }
    if (!forced && _lastSuccess && [now timeIntervalSinceDate:_lastSuccess] < kFreshnessWindow) {
        return;  // recent enough — leave the UI as it is, make no request
    }

    NSString *token = ReadOAuthToken();
    if (token.length == 0) {
        [self renderState:UsageStateNoCredentials limits:@[] message:nil];
        return;
    }

    __weak AppDelegate *weakSelf = self;
    if (_planName.length == 0) {
        [self request:kProfileURL token:token done:^(NSInteger code, NSData *data,
                                                     NSError *error, NSHTTPURLResponse *http) {
            AppDelegate *strong = weakSelf;
            if (!strong) return;
            if (code == 200 && data) {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    id org = ((NSDictionary *)obj)[@"organization"];
                    if ([org isKindOfClass:[NSDictionary class]]) {
                        NSString *plan = PrettyPlan(((NSDictionary *)org)[@"rate_limit_tier"]);
                        if (plan) {
                            strong->_planName = plan;
                            // Persisted: the plan almost never changes, and this
                            // saves one request on every future launch.
                            [[NSUserDefaults standardUserDefaults] setObject:plan
                                                                      forKey:@"PlanName"];
                        }
                    }
                }
            }
            [strong fetchUsageWithToken:token];
        }];
    } else {
        [self fetchUsageWithToken:token];
    }
}

- (void)fetchUsageWithToken:(NSString *)token {
    __weak AppDelegate *weakSelf = self;
    [self request:kUsageURL token:token done:^(NSInteger code, NSData *data,
                                               NSError *error, NSHTTPURLResponse *http) {
        AppDelegate *strong = weakSelf;
        if (!strong) return;

        if (error) {
            [strong renderDegradedWithNote:[NSString stringWithFormat:@"Network error: %@",
                                            error.localizedDescription]];
            return;
        }
        if (code == 401 || code == 403) {
            [strong renderState:UsageStateExpired limits:@[] message:nil];
            return;
        }
        if (code == 429 || code >= 500) {
            NSTimeInterval retryAfter = RetryAfterSeconds(http);
            if (retryAfter > 0) {
                strong->_backoff = retryAfter;
            } else {
                strong->_backoff = strong->_backoff > 0
                    ? MIN(strong->_backoff * 2, 1800)   // cap at 30 minutes
                    : 120;                              // first refusal: 2 minutes
            }
            strong->_nextAllowed = [NSDate dateWithTimeIntervalSinceNow:strong->_backoff];
            [strong renderDegradedWithNote:[strong waitNote]];
            return;
        }
        if (code != 200 || !data) {
            NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            if (body.length > 160) body = [body substringToIndex:160];
            [strong renderDegradedWithNote:[NSString stringWithFormat:@"HTTP %ld · %@",
                                            (long)code, body]];
            return;
        }

        [strong cacheResponse:data];

        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (!obj) {
            [strong renderDegradedWithNote:@"Response was not JSON."];
            return;
        }
        NSArray<LimitInfo *> *limits = ParseLimits(obj);
        if (limits.count == 0) {
            [strong renderDegradedWithNote:
                @"No limits found in the response. Raw response saved to "
                 "~/Library/Application Support/ClaudeUsageBar/"];
            return;
        }

        strong->_backoff     = 0;
        strong->_nextAllowed = nil;
        strong->_lastSuccess = [NSDate date];
        strong->_lastLimits  = limits;
        [strong renderState:UsageStateOK limits:limits message:nil];
    }];
}

/// Keep the last good numbers on screen when a fetch fails, with a footnote
/// explaining why they might be stale. Better than a wall of JSON.
- (void)renderDegradedWithNote:(NSString *)note {
    if (_lastLimits.count > 0) {
        [self renderState:UsageStateOK limits:_lastLimits message:note];
    } else {
        [self renderState:UsageStateError limits:@[] message:note];
    }
}

- (NSString *)waitNote {
    NSTimeInterval remaining = _nextAllowed ? [_nextAllowed timeIntervalSinceNow] : 0;
    if (remaining < 0) remaining = 0;
    long minutes = (long)ceil(remaining / 60.0);
    NSString *when = minutes <= 1 ? @"under a minute"
                                  : [NSString stringWithFormat:@"%ld minutes", minutes];

    if (_lastSuccess) {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"h:mm a";
        return [NSString stringWithFormat:
                @"Rate limited. Showing values from %@ — retrying in %@.",
                [f stringFromDate:_lastSuccess], when];
    }
    return [NSString stringWithFormat:@"Rate limited by the server. Retrying in %@.", when];
}

- (void)cacheResponse:(NSData *)data {
    NSString *dir = [@"~/Library/Application Support/ClaudeUsageBar" stringByExpandingTildeInPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    [data writeToFile:CachePath() atomically:YES];
}

/// Renders the last response saved to disk, so a relaunch during a rate-limit
/// window still shows numbers. Deliberately does NOT set `_lastSuccess` — that
/// would make the freshness gate suppress the first live fetch.
- (BOOL)loadCachedResponse {
    NSString *path = CachePath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return NO;

    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (!obj) return NO;

    NSArray<LimitInfo *> *limits = ParseLimits(obj);
    if (limits.count == 0) return NO;

    NSDate *when = [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                                   error:NULL][NSFileModificationDate];
    NSString *note;
    if (when) {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"EEE h:mm a";
        note = [NSString stringWithFormat:@"Saved values from %@ — checking…",
                [f stringFromDate:when]];
    } else {
        note = @"Saved values — checking…";
    }

    _lastLimits = limits;
    [self renderState:UsageStateOK limits:limits message:note];
    return YES;
}

#pragma mark Rendering

- (void)renderState:(UsageState)state
             limits:(NSArray<LimitInfo *> *)limits
            message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_controller.state   = state;
        self->_controller.limits  = limits ?: @[];
        self->_controller.plan    = self->_planName;
        self->_controller.message = message;
        [self->_controller refreshUI];

        NSStatusBarButton *button = self->_statusItem.button;
        if (!button) return;

        if (state == UsageStateOK && limits.count > 0) {
            LimitInfo *worst = limits[0];
            for (LimitInfo *l in limits) if (l.fraction > worst.fraction) worst = l;

            button.image = GaugeImage(@(worst.fraction), ColorForLimit(worst));
            button.title = [NSString stringWithFormat:@" %ld%%", (long)lround(worst.fraction * 100)];

            NSMutableArray *lines = [NSMutableArray array];
            for (LimitInfo *l in limits) {
                [lines addObject:[NSString stringWithFormat:@"%@: %ld%% · %@",
                                  l.title, (long)lround(l.fraction * 100), ResetText(l.resets)]];
            }
            button.toolTip = [lines componentsJoinedByString:@"\n"];
        } else if (state == UsageStateLoading) {
            button.image = GaugeImage(nil, [NSColor systemBlueColor]);
            button.title = @" …";
            button.toolTip = @"Loading Claude usage…";
        } else if (state == UsageStateExpired) {
            button.image = GaugeImage(nil, [NSColor systemBlueColor]);
            button.title = @" !";
            button.toolTip = @"Claude token expired — run `claude` in Terminal once";
        } else {
            button.image = GaugeImage(nil, [NSColor systemBlueColor]);
            button.title = @" —";
            button.toolTip = @"Claude usage unavailable — click for details";
        }
    });
}

@end

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
