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

// Token renewal. Both values are lifted verbatim from the installed Claude Code
// binary (2.1.251): its refresh is POST {grant_type, refresh_token, client_id,
// scope} as JSON to TOKEN_URL, and it stores the result back into the same
// keychain item via `security -i` with a hex-encoded payload. Doing exactly
// what it does — same item, same field names, same encoding — is what makes
// sharing the credential safe.
static NSString *const kTokenURL      = @"https://platform.claude.com/v1/oauth/token";
static NSString *const kClientID      = @"9d1c250a-e61b-44d9-88ed-5944d1962f5e";
static NSString *const kBackupService = @"ClaudeUsageBar-credentials-backup";
static NSString *const kDefaultScope  = @"user:profile user:inference";
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
@property (nonatomic, copy)   NSString *kind;       // server's key: session, weekly_all, ...
@property (nonatomic)         double    fraction;   // 0...1, the portion USED
@property (nonatomic, strong) NSDate   *resets;
@property (nonatomic, copy)   NSString *severity;
@end

/// The menu bar alone is phrased as what's left rather than what's spent: the
/// icon is a battery, and a battery reading 0% on an untouched plan looks
/// broken. The popover and its tooltip keep showing usage, matching the desktop
/// app's panel. `fraction` stays as usage throughout — it is what the API sends
/// and what the severity thresholds are written against.
static double RemainingFraction(LimitInfo *limit) {
    return MAX(0.0, MIN(1.0, 1.0 - limit.fraction));
}

static long RemainingPercent(LimitInfo *limit) {
    return (long)lround(RemainingFraction(limit) * 100);
}

/// How much menu bar to occupy. On a notched Mac with a crowded bar, macOS
/// silently drops whatever doesn't fit, so width is the difference between the
/// widget existing and the widget being visible.
///
///   compact  just the number, ~26pt   (default)
///   gauge    battery + number, ~55pt  (the original)
///   icon     battery only, ~29pt
///
/// Change with: defaults write com.haicreative.claudeusagebar MenuBarStyle gauge
static NSString *MenuBarStyle(void) {
    NSString *style = [[NSUserDefaults standardUserDefaults] stringForKey:@"MenuBarStyle"];
    if ([style isEqualToString:@"gauge"] || [style isEqualToString:@"icon"]) return style;
    return @"compact";
}

/// Solid colour for the compact style, which has no bar to carry the gradient.
/// Normal reads as ordinary menu bar text on purpose — colour should mean
/// "look at me", so it should be absent until there is something to look at.
static NSColor *TextColorForLimit(LimitInfo *limit) {
    if ([limit.severity isEqualToString:@"critical"] || limit.fraction >= 0.90) {
        return [NSColor systemRedColor];
    }
    if ([limit.severity isEqualToString:@"warning"] || limit.fraction >= 0.75) {
        return [NSColor systemOrangeColor];
    }
    return [NSColor labelColor];
}

/// Which limit the menu bar speaks for. The 5-hour window is the one that
/// actually stops you working, so it wins outright. If the server ever stops
/// sending a session limit, fall back to whichever is closest to its cap.
static LimitInfo *MenuBarLimit(NSArray<LimitInfo *> *limits) {
    if (limits.count == 0) return nil;
    for (LimitInfo *l in limits) {
        if ([l.kind isEqualToString:@"session"]) return l;
    }
    LimitInfo *worst = limits[0];
    for (LimitInfo *l in limits) if (l.fraction > worst.fraction) worst = l;
    return worst;
}

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

/// The token plus the expiry that ships alongside it in the same blob.
///
/// Reading `expiresAt` is what keeps this app out of trouble. An expired token
/// earns a 401, and enough 401s earn a 429 with a flat one-hour Retry-After —
/// the server rate limits failed auth. Knowing the token is dead *before*
/// spending a request means that cascade can never start.
///
/// And reading `refreshToken` is what makes the widget self-sufficient. An
/// expired access token is renewed the way Claude Code renews it, and the
/// result goes back into the same keychain item, so both apps keep working
/// from one credential. The whole stored blob is kept, not just the OAuth
/// fields: Claude Code keeps MCP server tokens beside them, and a write that
/// dropped those would break something unrelated to us.
@interface Credentials : NSObject
@property (nonatomic, strong) NSMutableDictionary *blob;   // entire stored JSON
@property (nonatomic, copy)   NSString *accessToken;
@property (nonatomic, copy)   NSString *refreshToken;        // nil when absent
@property (nonatomic, strong) NSDate   *expires;             // nil when absent
@property (nonatomic, copy)   NSString *scope;               // space-separated
@property (nonatomic, copy)   NSString *service;             // keychain svc; nil = file
@property (nonatomic, copy)   NSString *account;             // keychain acct
- (BOOL)isExpired;
@end

@implementation Credentials
/// A minute of slack: a token expiring while the request is in flight comes
/// back as a 401 just the same.
- (BOOL)isExpired {
    return self.expires != nil && [self.expires timeIntervalSinceNow] <= 60.0;
}
@end

static NSNumber *Numeric(id value) {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static NSDate *ExpiryFrom(id value) {
    NSNumber *n = Numeric(value);
    if (!n || [n doubleValue] <= 0) return nil;
    double v = [n doubleValue];
    return [NSDate dateWithTimeIntervalSince1970:(v > 1e12 ? v / 1000.0 : v)];
}

/// Which dictionary carries the OAuth fields: `claudeAiOauth` in the keychain
/// blob, or the top level in the legacy credentials file. nil for anything
/// else — which is how the `mcpOAuth`-only decoy items are rejected.
static NSString *OAuthContainerKey(NSDictionary *blob) {
    id inner = blob[@"claudeAiOauth"];
    if ([inner isKindOfClass:[NSDictionary class]] &&
        [((NSDictionary *)inner)[@"accessToken"] isKindOfClass:[NSString class]]) {
        return @"claudeAiOauth";
    }
    if ([blob[@"accessToken"] isKindOfClass:[NSString class]]) return @"";
    return nil;
}

static Credentials *CredentialsFromJSONText(NSString *text) {
    if (text.length == 0) return nil;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data
                                             options:NSJSONReadingMutableContainers
                                               error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;

    NSMutableDictionary *blob = obj;
    NSString *key = OAuthContainerKey(blob);
    if (!key) return nil;
    NSDictionary *o = key.length ? blob[key] : blob;

    NSString *access = o[@"accessToken"];
    if (access.length == 0) return nil;

    Credentials *c = [[Credentials alloc] init];
    c.blob        = blob;
    c.accessToken = access;
    id refresh = o[@"refreshToken"];
    c.refreshToken = ([refresh isKindOfClass:[NSString class]] && [refresh length]) ? refresh : nil;
    c.expires     = ExpiryFrom(o[@"expiresAt"]);
    id scopes = o[@"scopes"];
    c.scope = ([scopes isKindOfClass:[NSArray class]] && [scopes count])
              ? [(NSArray *)scopes componentsJoinedByString:@" "]
              : kDefaultScope;
    return c;
}

/// The `acct` attribute of the keychain item, needed to write it back.
/// `security` prints it as "acct"<blob>="text", or as 0x-prefixed hex when it
/// isn't plain ASCII.
static NSString *KeychainAccount(NSString *service) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/security"];
    task.arguments = @[@"find-generic-password", @"-s", service];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSPipe pipe];
    if (![task launchAndReturnError:NULL]) return nil;
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return nil;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"\"acct\"<blob>=(?:\"((?:[^\"\\\\]|\\\\.)*)\"|0x([0-9A-Fa-f]+))" options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:text options:0
                                               range:NSMakeRange(0, text.length)];
    if (!m) return nil;
    if ([m rangeAtIndex:1].location != NSNotFound) {
        return [[text substringWithRange:[m rangeAtIndex:1]]
                stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
    }
    return DecodeHex([text substringWithRange:[m rangeAtIndex:2]]);
}

static Credentials *ReadCredentials(void) {
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
        Credentials *c = CredentialsFromJSONText(raw);
        if (c) {
            c.service = service;
            c.account = KeychainAccount(service);
            return c;
        }
    }

    NSString *path = [@"~/.claude/.credentials.json" stringByExpandingTildeInPath];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    return CredentialsFromJSONText(text);   // service stays nil: file-backed
}

#pragma mark - Credential write-back

static NSString *HexEncode(NSData *data) {
    const unsigned char *b = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", b[i]];
    return hex;
}

/// Exactly Claude Code's own write: one `add-generic-password -U` line fed to
/// `security -i` on stdin, payload hex-encoded so quoting can never bite. Same
/// account and service, so the item is updated rather than duplicated and its
/// existing access control applies unchanged. Pure, so it can be tested.
static NSString *KeychainWriteScript(NSString *service, NSString *account, NSString *json) {
    return [NSString stringWithFormat:@"add-generic-password -U -a \"%@\" -s \"%@\" -X \"%@\" \n",
            account, service, HexEncode([json dataUsingEncoding:NSUTF8StringEncoding])];
}

/// Never let credential material reach a log. `security` echoes the offending
/// command back in its error text, and the command carries the whole payload.
static NSString *RedactHex(NSString *s) {
    if (s.length == 0) return @"";
    static NSRegularExpression *hexRun = nil, *token = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Hex payloads echoed back by `security`, and Anthropic-shaped tokens
        // (sk-ant-oat01-…, sk-ant-ort01-…) should they ever land in a body.
        hexRun = [NSRegularExpression regularExpressionWithPattern:@"[0-9a-fA-F]{32,}"
                                                            options:0 error:NULL];
        token  = [NSRegularExpression regularExpressionWithPattern:@"sk-ant-[A-Za-z0-9_-]{8,}"
                                                            options:0 error:NULL];
    });
    NSString *out = [hexRun stringByReplacingMatchesInString:s options:0
                                                       range:NSMakeRange(0, s.length)
                                                withTemplate:@"<hex redacted>"];
    out = [token stringByReplacingMatchesInString:out options:0
                                            range:NSMakeRange(0, out.length)
                                     withTemplate:@"<token redacted>"];
    return out.length > 300 ? [out substringToIndex:300] : out;
}

/// `security -i` reads one command per line through a fixed buffer. A line
/// past it is split: the head runs with a truncated value and the tail is
/// rejected as unknown commands — which writes a corrupt item and reports a
/// failure. Claude Code guards this with a length check and falls back to
/// passing the value in argv; so does this. The stdin path is used only when
/// it is certainly safe.
static const NSUInteger kSecurityStdinLimit = 2000;

static BOOL WriteKeychainItem(NSString *service, NSString *account, NSString *json,
                              NSString **failure) {
    NSString *hex    = HexEncode([json dataUsingEncoding:NSUTF8StringEncoding]);
    NSString *script = KeychainWriteScript(service, account, json);
    BOOL viaStdin    = script.length <= kSecurityStdinLimit;

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/security"];
    task.arguments = viaStdin
        ? @[@"-i"]
        : @[@"add-generic-password", @"-U", @"-a", account, @"-s", service, @"-X", hex];
    NSPipe *in = [NSPipe pipe], *err = [NSPipe pipe];
    task.standardInput  = viaStdin ? in : [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSPipe pipe];
    task.standardError  = err;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (failure) *failure = launchError.localizedDescription ?: @"could not run security";
        return NO;
    }
    if (viaStdin) {
        [in.fileHandleForWriting writeData:[script dataUsingEncoding:NSUTF8StringEncoding]];
        [in.fileHandleForWriting closeFile];
    }
    NSData *errData = [err.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];

    if (task.terminationStatus != 0) {
        NSString *msg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
        if (failure) *failure = [NSString stringWithFormat:@"security exited %d: %@",
                                 task.terminationStatus, RedactHex(msg)];
        return NO;
    }

    // Read it straight back. A write that "succeeded" but stored something
    // other than what we sent is the one failure this must never be quiet
    // about — it is exactly how the item got corrupted once already.
    NSString *back = [RunSecurity(service) stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (back.length && ![back hasPrefix:@"{"] && IsHexString(back)) back = DecodeHex(back);
    if (![back isEqualToString:json]) {
        if (failure) *failure = @"read-back mismatch: stored item differs from what was written";
        return NO;
    }
    return YES;
}

/// The stored blob with a token response folded in, the way Claude Code folds
/// it: the OAuth container gets the new access token and expiry, keeps its
/// refresh token unless the server rotated it, and every other key — theirs
/// and ours — is carried through untouched. Pure, so it can be tested without
/// a keychain.
static NSDictionary *MergeRefreshResponse(NSDictionary *blob, NSDictionary *response, NSDate *now) {
    NSString *key = OAuthContainerKey(blob);
    if (!key) return nil;
    NSString *access = response[@"access_token"];
    NSNumber *expiresIn = Numeric(response[@"expires_in"]);
    if (![access isKindOfClass:[NSString class]] || access.length == 0 || !expiresIn) return nil;

    NSMutableDictionary *out = [blob mutableCopy];
    NSMutableDictionary *o = [(key.length ? blob[key] : blob) mutableCopy];

    o[@"accessToken"] = access;
    o[@"expiresAt"]   = @((long long)(([now timeIntervalSince1970] + [expiresIn doubleValue]) * 1000.0));

    NSString *rotated = response[@"refresh_token"];
    if ([rotated isKindOfClass:[NSString class]] && rotated.length) o[@"refreshToken"] = rotated;

    NSNumber *rtExpiresIn = Numeric(response[@"refresh_token_expires_in"]);
    if (rtExpiresIn) {
        o[@"refreshTokenExpiresAt"] =
            @((long long)(([now timeIntervalSince1970] + [rtExpiresIn doubleValue]) * 1000.0));
    }
    NSString *scope = response[@"scope"];
    if ([scope isKindOfClass:[NSString class]] && scope.length) {
        o[@"scopes"] = [scope componentsSeparatedByString:@" "];
    }

    if (key.length) out[key] = o; else [out addEntriesFromDictionary:o];
    return out;
}

static NSString *JSONText(id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
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
            limit.kind = kind;
            limit.fraction = MAX(0.0, MIN(1.0, [pct doubleValue] / 100.0));
            limit.resets = ParseDate(item[@"resets_at"]);
            limit.severity = [item[@"severity"] isKindOfClass:[NSString class]] ? item[@"severity"] : @"normal";
            [out addObject:limit];
        }
        if (out.count > 0) return out;
    }

    // Fallback shape.
    NSArray *fallback = @[@[@"five_hour",      @"5-hour limit",        @"session"],
                          @[@"seven_day",      @"Weekly · all models", @"weekly_all"],
                          @[@"seven_day_opus", @"Weekly · Opus",       @"weekly_scoped"]];
    for (NSArray *pair in fallback) {
        id obj = dict[pair[0]];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *pct = Numeric(((NSDictionary *)obj)[@"utilization"]);
        if (!pct) continue;
        LimitInfo *limit = [[LimitInfo alloc] init];
        limit.title = pair[1];
        limit.kind = pair[2];
        limit.fraction = MAX(0.0, MIN(1.0, [pct doubleValue] / 100.0));
        limit.resets = ParseDate(((NSDictionary *)obj)[@"resets_at"]);
        limit.severity = @"normal";
        [out addObject:limit];
    }
    return out;
}

/// Claude Code keeps its own copy of this exact payload in ~/.claude.json under
/// `cachedUsageUtilization`, wrapped with a `fetchedAtMs` stamp. Same schema, so
/// ParseLimits handles it unchanged.
///
/// It is not a live feed — Claude Code refreshes it on its own schedule and it
/// can be days stale — but it costs no request, and the stamp means its age is
/// known rather than assumed. Worth having as a second source precisely because
/// the one thing we cannot do while rate limited is ask the server.
static NSArray<LimitInfo *> *LimitsFromClaudeCode(NSDate **fetchedAt) {
    NSString *path = [@"~/.claude.json" stringByExpandingTildeInPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;

    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id cached = ((NSDictionary *)obj)[@"cachedUsageUtilization"];
    if (![cached isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *wrapper = cached;
    NSArray<LimitInfo *> *limits = ParseLimits(wrapper[@"utilization"]);
    if (limits.count == 0) return nil;

    if (fetchedAt) {
        NSNumber *ms = Numeric(wrapper[@"fetchedAtMs"]);
        *fetchedAt = ms ? [NSDate dateWithTimeIntervalSince1970:[ms doubleValue] / 1000.0] : nil;
    }
    return limits;
}

/// "3 days ago" beats a bare clock time once numbers are more than a few hours
/// old — the age is the thing that decides whether to trust them.
static NSString *AgeText(NSDate *when) {
    if (!when) return @"unknown age";
    NSTimeInterval s = -[when timeIntervalSinceNow];
    if (s < 90)    return @"just now";
    if (s < 3600)  return [NSString stringWithFormat:@"%ld min ago", (long)(s / 60)];
    if (s < 86400) return [NSString stringWithFormat:@"%ld hr ago",  (long)(s / 3600)];
    return [NSString stringWithFormat:@"%ld days ago", (long)(s / 86400)];
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

#pragma mark - Palette

static NSColor *RGB(double r, double g, double b) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
}

/// Violet, matching the accent the desktop app uses rather than system blue.
/// Swept across the filled portion of each bar so that short bars show the
/// whole ramp too, rather than only its bluest end.
static NSGradient *PurpleGradient(void) {
    static NSGradient *g = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g = [[NSGradient alloc] initWithStartingColor:RGB(0.52, 0.35, 0.96)
                                          endingColor:RGB(0.74, 0.34, 0.95)];
    });
    return g;
}

/// Purple normally; warmer once the limit is close enough to matter. The
/// escalation is the whole point of the colour, so it survives the restyle.
static NSGradient *GradientForLimit(LimitInfo *limit) {
    BOOL critical = [limit.severity isEqualToString:@"critical"] || limit.fraction >= 0.90;
    BOOL warning  = [limit.severity isEqualToString:@"warning"]  || limit.fraction >= 0.75;

    if (critical) {
        return [[NSGradient alloc] initWithStartingColor:RGB(0.98, 0.35, 0.38)
                                             endingColor:RGB(0.90, 0.22, 0.42)];
    }
    if (warning) {
        return [[NSGradient alloc] initWithStartingColor:RGB(0.98, 0.62, 0.20)
                                             endingColor:RGB(0.99, 0.45, 0.22)];
    }
    return PurpleGradient();
}

#pragma mark - Menu bar gauge

static NSImage *GaugeImage(NSNumber *fraction, NSGradient *fill) {
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
            NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:
                                  NSMakeRect(NSMinX(inner), NSMinY(inner), fw, inner.size.height)
                                                                 xRadius:1.5 yRadius:1.5];
            [(fill ?: PurpleGradient()) drawInBezierPath:clip angle:0];
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
@property (nonatomic)         double      fraction;
@property (nonatomic, strong) NSGradient *fillGradient;
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
        [(self.fillGradient ?: PurpleGradient()) drawInBezierPath:fill angle:0];
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
@property (nonatomic)         BOOL              busy;
- (void)refreshUI;
@end

@implementation UsageViewController {
    CGFloat              _width;
    NSStackView         *_stack;
    NSButton            *_refreshButton;
    NSProgressIndicator *_spinner;
    NSDate              *_busySince;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _width = 380;
        _state = UsageStateLoading;
        _limits = @[];
    }
    return self;
}

// Auto Layout throughout, deliberately. The previous version placed every block
// with absolute frames and set the root view's frame by hand. NSPopover moves
// that view for its own reasons once it is really on screen, which left the
// content hard against the left edge with both margins stacked up on the right.
// Constraints are measured against whatever bounds the popover actually hands
// us, so the padding stays symmetric no matter what AppKit does.
- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, _width, 140)];

    _stack = [[NSStackView alloc] init];
    _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _stack.alignment   = NSLayoutAttributeLeading;
    _stack.spacing     = 12;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_stack];

    // No width constraint on the root view: NSPopover sizes and positions it
    // itself, and pinning it here is what knocked the content off-centre.
    [NSLayoutConstraint activateConstraints:@[
        [_stack.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor  constant:16],
        [_stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],
        [_stack.topAnchor      constraintEqualToAnchor:root.topAnchor      constant:16],
        [_stack.bottomAnchor   constraintEqualToAnchor:root.bottomAnchor   constant:-16],
    ]];

    self.view = root;
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
    f.translatesAutoresizingMaskIntoConstraints = NO;
    return f;
}

/// Wraps to the column width on its own now — no hand-measured bounding rect.
- (NSView *)messageBlock:(NSString *)text {
    NSTextField *f = [NSTextField wrappingLabelWithString:text ?: @""];
    f.font = [NSFont systemFontOfSize:12];
    f.textColor = [NSColor secondaryLabelColor];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    return f;
}

- (NSView *)limitBlock:(LimitInfo *)limit {
    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *title = [self labelWithText:limit.title size:14 bold:YES
                                        tone:[NSColor labelColor]
                                       align:NSTextAlignmentLeft];
    NSTextField *reset = [self labelWithText:ResetText(limit.resets) size:12 bold:NO
                                        tone:[NSColor tertiaryLabelColor]
                                       align:NSTextAlignmentRight];
    NSString *pctText = [NSString stringWithFormat:@"%ld%%", (long)lround(limit.fraction * 100)];
    NSTextField *pct = [self labelWithText:pctText size:13 bold:NO
                                      tone:[NSColor secondaryLabelColor]
                                     align:NSTextAlignmentRight];

    BarView *bar = [[BarView alloc] initWithFrame:NSZeroRect];
    bar.fraction     = limit.fraction;
    bar.fillGradient = GradientForLimit(limit);
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *v in @[title, reset, pct, bar]) [row addSubview:v];

    // The reset time and percentage hug their text; the title absorbs the slack
    // and is the only column allowed to truncate.
    NSLayoutConstraintOrientation hz = NSLayoutConstraintOrientationHorizontal;
    [title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:hz];
    for (NSTextField *f in @[reset, pct]) {
        [f setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:hz];
        [f setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:hz];
    }

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [title.topAnchor     constraintEqualToAnchor:row.topAnchor],

        [pct.trailingAnchor      constraintEqualToAnchor:row.trailingAnchor],
        [pct.firstBaselineAnchor constraintEqualToAnchor:title.firstBaselineAnchor],

        [reset.trailingAnchor      constraintEqualToAnchor:pct.leadingAnchor constant:-8],
        [reset.firstBaselineAnchor constraintEqualToAnchor:title.firstBaselineAnchor],
        [reset.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8],

        [bar.leadingAnchor  constraintEqualToAnchor:row.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [bar.topAnchor      constraintEqualToAnchor:title.bottomAnchor constant:8],
        [bar.heightAnchor   constraintEqualToConstant:8],
        [bar.bottomAnchor   constraintEqualToAnchor:row.bottomAnchor],
    ]];
    return row;
}

/// One click instead of a remembered command. The widget cannot renew the
/// token itself — see the README on why refreshing it here could invalidate the
/// user's CLI login — but it can start the thing that does.
- (NSView *)fixItButton {
    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *fix = [NSButton buttonWithTitle:@"Open Terminal and run claude"
                                       target:self action:@selector(runClaudeTapped)];
    fix.bezelStyle  = NSBezelStyleRounded;
    fix.controlSize = NSControlSizeSmall;
    fix.font        = [NSFont systemFontOfSize:11];
    fix.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:fix];

    [NSLayoutConstraint activateConstraints:@[
        [fix.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [fix.topAnchor     constraintEqualToAnchor:row.topAnchor],
        [fix.bottomAnchor  constraintEqualToAnchor:row.bottomAnchor],
        [fix.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor],
    ]];
    return row;
}

- (void)runClaudeTapped {
    NSString *script = @"tell application \"Terminal\"\n"
                        "activate\n"
                        "do script \"claude\"\n"
                        "end tell";
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    task.arguments = @[@"-e", script];
    [task launchAndReturnError:NULL];
    // The keychain write lands when Claude Code finishes starting; the timer
    // picks it up, and this makes it feel immediate rather than eventual.
    if (self.onRefresh) {
        __weak UsageViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UsageViewController *strong = weakSelf;
            if (strong.onRefresh) strong.onRefresh();
        });
    }
}

- (NSView *)footerBlock {
    NSView *footer = [[NSView alloc] initWithFrame:NSZeroRect];
    footer.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshTapped)];
    NSButton *quit    = [NSButton buttonWithTitle:@"Quit" target:NSApp action:@selector(terminate:)];
    for (NSButton *b in @[refresh, quit]) {
        b.bezelStyle  = NSBezelStyleInline;
        b.controlSize = NSControlSizeSmall;
        b.font        = [NSFont systemFontOfSize:11];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [footer addSubview:b];
    }
    // Fixed width, so swapping the title to "Refreshing…" doesn't shove the
    // footer around mid-click.
    [[refresh.widthAnchor constraintGreaterThanOrEqualToConstant:86] setActive:YES];

    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.indeterminate = YES;
    spinner.displayedWhenStopped = NO;
    spinner.hidden = YES;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:spinner];

    [NSLayoutConstraint activateConstraints:@[
        [refresh.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor],
        [refresh.topAnchor     constraintEqualToAnchor:footer.topAnchor],
        [refresh.bottomAnchor  constraintEqualToAnchor:footer.bottomAnchor],
        [spinner.leadingAnchor constraintEqualToAnchor:refresh.trailingAnchor constant:8],
        [spinner.centerYAnchor constraintEqualToAnchor:refresh.centerYAnchor],
        [spinner.widthAnchor   constraintEqualToConstant:14],
        [spinner.heightAnchor  constraintEqualToConstant:14],
        [quit.trailingAnchor      constraintEqualToAnchor:footer.trailingAnchor],
        [quit.firstBaselineAnchor constraintEqualToAnchor:refresh.firstBaselineAnchor],
    ]];

    // The footer is rebuilt on every render; carry the current state across.
    _refreshButton = refresh;
    _spinner = spinner;
    [self applyBusyState];
    return footer;
}

/// Every row spans the full column. Pinned explicitly, because the stack view's
/// own Width alignment leaves single-line labels at their intrinsic width.
- (void)addRow:(NSView *)row {
    [_stack addArrangedSubview:row];
    [[row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor] setActive:YES];
}

- (void)refreshUI {
    // Touching self.view loads it, and viewDidLoad calls straight back here
    // with the stack in place. Without this the first render built everything
    // twice.
    if (!_stack) { (void)self.view; return; }

    for (NSView *v in [_stack.arrangedSubviews copy]) {
        [_stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSString *headerText = @"Claude usage";
    if (self.state == UsageStateOK) {
        headerText = self.plan.length
            ? [NSString stringWithFormat:@"Plan usage limits · %@", self.plan]
            : @"Plan usage limits";
    }
    [self addRow:[self labelWithText:headerText size:12 bold:NO
                                tone:[NSColor secondaryLabelColor]
                               align:NSTextAlignmentLeft]];

    switch (self.state) {
        case UsageStateLoading:
            [self addRow:[self messageBlock:@"Loading…"]];
            break;
        case UsageStateNoCredentials:
            [self addRow:[self messageBlock:
                @"No Claude token found.\nRun `claude` in Terminal and sign in, then refresh."]];
            break;
        case UsageStateExpired:
            [self addRow:[self messageBlock:(self.message.length
                ? [NSString stringWithFormat:
                   @"Sign-in expired and couldn't be renewed automatically (%@). "
                    "Signing in again fixes it.", self.message]
                : @"Sign-in expired and couldn't be renewed automatically. "
                   "Signing in again fixes it.")]];
            [self addRow:[self fixItButton]];
            break;
        case UsageStateError:
            [self addRow:[self messageBlock:(self.message ?: @"Something went wrong.")]];
            break;
        case UsageStateOK:
            for (LimitInfo *limit in self.limits) {
                [self addRow:[self limitBlock:limit]];
            }
            if (self.message.length) {
                [self addRow:[self messageBlock:self.message]];
            }
            break;
    }

    [self addRow:[self footerBlock]];

    // Measure the column at its intended width with a throwaway constraint.
    // refreshUI runs while the popover is on screen, so resizing the live view
    // to measure it would flicker.
    NSLayoutConstraint *probe = [_stack.widthAnchor constraintEqualToConstant:_width - 32];
    probe.priority = NSLayoutPriorityDefaultHigh;
    probe.active = YES;
    [_stack layoutSubtreeIfNeeded];
    CGFloat height = [_stack fittingSize].height;
    probe.active = NO;
    self.preferredContentSize = NSMakeSize(_width, height + 32);
}

/// Held for a beat on the way down. A cached or fast response returns in well
/// under a frame, and an indicator that appears and vanishes that quickly reads
/// as nothing having happened at all.
- (void)setBusy:(BOOL)busy {
    if (busy) {
        _busy = YES;
        _busySince = [NSDate date];
        [self applyBusyState];
        return;
    }

    NSTimeInterval shown = _busySince ? -[_busySince timeIntervalSinceNow] : 1.0;
    NSTimeInterval remaining = MAX(0.0, 0.45 - shown);
    if (remaining <= 0) {
        _busy = NO;
        [self applyBusyState];
        return;
    }

    __weak UsageViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UsageViewController *strong = weakSelf;
        if (!strong) return;
        strong->_busy = NO;
        [strong applyBusyState];
    });
}

- (void)applyBusyState {
    _refreshButton.enabled = !_busy;
    _refreshButton.title   = _busy ? @"Refreshing…" : @"Refresh";
    if (_busy) {
        _spinner.hidden = NO;
        [_spinner startAnimation:nil];
    } else {
        [_spinner stopAnimation:nil];
        _spinner.hidden = YES;
    }
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
- (void)continueWithCredentials:(Credentials *)creds;
- (void)renewCredentials:(Credentials *)creds
                    then:(void (^)(Credentials *fresh, NSString *failure, BOOL transient))done;
- (BOOL)renewalAlreadyFailedFor:(Credentials *)creds;
- (void)rememberRenewalFailedFor:(Credentials *)creds;
- (void)clearRenewalFailure;
- (void)renderState:(UsageState)state
             limits:(NSArray<LimitInfo *> *)limits
            message:(NSString *)message;
- (void)renderDegradedWithNote:(NSString *)note;
- (BOOL)adoptClaudeCodeCacheIfNewer;
- (void)markInFlight:(BOOL)flag;
- (void)backOffAfter:(NSInteger)code http:(NSHTTPURLResponse *)http;
- (NSString *)waitNote;
- (NSString *)offlineNote;
- (void)cacheResponse:(NSData *)data;
- (BOOL)loadCachedResponse;
@end

static NSString *CachePath(void) {
    return [@"~/Library/Application Support/ClaudeUsageBar/last-response.json"
            stringByExpandingTildeInPath];
}

/// Honour a server-supplied Retry-After when there is one.
///
/// Read through -valueForHTTPHeaderField:, which is documented case-insensitive.
/// Subscripting allHeaderFields is NOT: this endpoint is served over HTTP/2,
/// where header names travel lowercased, so `allHeaderFields[@"Retry-After"]`
/// can miss entirely. Missing it means ignoring a long server-set cooldown and
/// retrying into it on our own much shorter ladder, which is how a client stays
/// blocked indefinitely.
static NSTimeInterval RetryAfterSeconds(NSHTTPURLResponse *http) {
    if (!http) return 0;
    NSString *value = [http valueForHTTPHeaderField:@"Retry-After"];
    if (value.length == 0) return 0;

    // RFC 9110 allows delta-seconds...
    double n = [value doubleValue];
    if (n > 0 && n < 86400) return n;

    // ...or an HTTP-date, which doubleValue silently reads as 0.
    static NSDateFormatter *rfc1123 = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rfc1123 = [[NSDateFormatter alloc] init];
        rfc1123.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        rfc1123.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        rfc1123.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
    });
    NSDate *when = [rfc1123 dateFromString:value];
    if (!when) return 0;
    NSTimeInterval delta = [when timeIntervalSinceNow];
    return (delta > 0 && delta < 86400) ? delta : 0;
}

/// Appends one line per failure to a log beside the cached response, so a stuck
/// widget can be diagnosed after the fact instead of guessed at.
static void LogFailure(NSInteger code, NSHTTPURLResponse *http, NSData *body, NSString *what) {
    NSString *dir = [@"~/Library/Application Support/ClaudeUsageBar" stringByExpandingTildeInPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:NULL];

    NSString *snippet = @"";
    if (body.length) {
        snippet = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"";
        if (snippet.length > 200) snippet = [snippet substringToIndex:200];
        snippet = [snippet stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    }

    // Belt and braces: nothing that looks like a token or a hex payload goes
    // in, whatever the caller passed.
    NSISO8601DateFormatter *stamp = [[NSISO8601DateFormatter alloc] init];
    NSString *line = [NSString stringWithFormat:@"%@\tHTTP %ld\t%@\tretry-after=%@\t%@\n",
                      [stamp stringFromDate:[NSDate date]], (long)code, RedactHex(what),
                      [http valueForHTTPHeaderField:@"Retry-After"] ?: @"(none)",
                      RedactHex(snippet)];

    NSString *path = [dir stringByAppendingPathComponent:@"failures.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
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
    NSDate               *_lastSuccess;   // gates fetching
    NSDate               *_dataAsOf;      // when the displayed numbers were true
    NSDate               *_nextAllowed;
    NSTimeInterval        _backoff;
    BOOL                  _inFlight;    // exactly one request chain at a time
    BOOL                  _serverAsked;  // the wait came from Retry-After, not us
    BOOL                  _authExpired;  // 401 seen; polling on is pointless and harmful
    BOOL                  _fromClaudeCode;  // showing Claude Code's cache, not ours
    Credentials          *_creds;             // what the current chain is using
    BOOL                  _renewedThisCycle;  // one renewal per chain, then stop
    NSDate               *_lastTransientLog; // rate limits our own logging
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _controller = [[UsageViewController alloc] init];

    _popover = [[NSPopover alloc] init];
    _popover.contentViewController = _controller;
    _popover.behavior = NSPopoverBehaviorTransient;

    _planName = [[NSUserDefaults standardUserDefaults] stringForKey:@"PlanName"];
    _lastLimits = @[];
    _backoff = 0;
    [self restoreCooldown];

    __weak AppDelegate *weakSelf = self;
    _controller.onRefresh = ^{ [weakSelf refreshForced:YES]; };

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    // Without this the item is treated as brand new on every launch and lands
    // at the back of the queue — which on a full menu bar means off the edge.
    // With it, macOS remembers where you Cmd-dragged it to.
    _statusItem.autosaveName = @"ClaudeUsageBar";
    _statusItem.button.imagePosition = NSImageLeading;
    _statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    [self applyButton:GaugeImage(nil, nil) title:@"—" tone:[NSColor labelColor]];
    _statusItem.button.target = self;
    _statusItem.button.action = @selector(togglePopover);

    // Show yesterday's numbers immediately rather than an empty popover. This
    // costs no request, and the live fetch below replaces them if it succeeds.
    [self loadCachedResponse];
    [self refreshForced:YES];

    // Report where macOS actually placed us. The status item can be created
    // successfully and still never appear: on a full menu bar the system drops
    // whatever doesn't fit, silently and with no error. A frame off the left of
    // the screen, or a zero width, is the difference between "not running" and
    // "running but squeezed out" — and those need opposite fixes.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AppDelegate *strong = weakSelf;
        if (!strong) return;
        NSRect frame  = strong->_statusItem.button.window.frame;
        NSScreen *main = [NSScreen mainScreen];
        NSRect screen  = main.frame;

        // On a notched Mac the usable menu bar is split in two. AppKit reports
        // the halves directly, so the notch can be described rather than
        // guessed at from the screen width.
        NSString *notch = @"no notch";
        if (@available(macOS 12.0, *)) {
            NSRect left  = main.auxiliaryTopLeftArea;
            NSRect right = main.auxiliaryTopRightArea;
            if (!NSIsEmptyRect(left) && !NSIsEmptyRect(right)) {
                notch = [NSString stringWithFormat:@"notch spans %.0f-%.0f",
                         NSMaxX(left), NSMinX(right)];
            }
        }

        BOOL placed = NSWidth(frame) > 0 &&
                      NSMinX(frame) >= 0 && NSMaxX(frame) <= NSWidth(screen);
        NSLog(@"ClaudeUsageBar: status item x=%.0f-%.0f (width %.0f), screen %.0f, %@, "
              @"style=%@ — %@", NSMinX(frame), NSMaxX(frame), NSWidth(frame),
              NSWidth(screen), notch, MenuBarStyle(),
              placed ? @"has a slot" : @"NO SLOT (menu bar is full)");
    });

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

/// Keeps the request flag and the popover's spinner in step. Main thread only,
/// which is guaranteed now that every completion hops there first.
- (void)markInFlight:(BOOL)flag {
    _inFlight = flag;
    _controller.busy = flag;
}

#pragma mark Networking

/// The shared session fails immediately when the interface is down, which on a
/// laptop means every wake, every wifi handover and every VPN flap produces a
/// timeout. `waitsForConnectivity` makes URLSession hold the request until
/// there is a route instead — the machine reconnects, the request goes out, and
/// nothing is logged or shown. The long resource timeout is what gives it room
/// to do that; the per-request timeout still bounds a connection that stalls
/// after it opens.
- (NSURLSession *)session {
    static NSURLSession *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.waitsForConnectivity        = YES;
        config.timeoutIntervalForRequest   = 30;
        config.timeoutIntervalForResource  = 300;   // room to wait out a wake
        config.HTTPShouldUsePipelining     = NO;
        shared = [NSURLSession sessionWithConfiguration:config];
    });
    return shared;
}

/// Transient plumbing — asleep, offline, wifi mid-handover, a TLS handshake
/// that lost its connection. Not the server's answer and not the user's
/// problem, so these never produce an alarming note: the numbers stay put and
/// the footnote just says how old they are.
static BOOL IsTransientNetworkError(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorCallIsActive:
        case NSURLErrorDataNotAllowed:
        case NSURLErrorSecureConnectionFailed:
            return YES;
        default:
            return NO;
    }
}

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
        [[self session] dataTaskWithRequest:req
                                        completionHandler:^(NSData *data,
                                                            NSURLResponse *response,
                                                            NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                                ? (NSHTTPURLResponse *)response : nil;
        NSInteger code = http ? http.statusCode : 0;
        // Every piece of state this class keeps is touched from here and from
        // the timer and the status-item click. Hop to the main thread once, so
        // there is exactly one thread mutating any of it.
        dispatch_async(dispatch_get_main_queue(), ^{ done(code, data, error, http); });
    }];
    [task resume];
}

/// `forced` skips the freshness check (the Refresh button), but never skips an
/// active backoff — retrying into a 429 is what keeps it tripped.
- (void)refreshForced:(BOOL)forced {
    NSDate *now = [NSDate date];

    // One request chain at a time. Launch fires a refresh, and clicking the
    // status item before it lands used to fire a second: `_lastSuccess` is only
    // written once a response arrives, so the freshness gate below waves the
    // click straight through. Two Refresh clicks did the same. On an endpoint
    // that 429s if polled casually, that is the app tripping its own limiter.
    if (_inFlight) return;

    if (_nextAllowed && [now compare:_nextAllowed] == NSOrderedAscending) {
        [self renderDegradedWithNote:[self waitNote]];
        return;
    }

    if (!forced && _lastSuccess && [now timeIntervalSinceDate:_lastSuccess] < kFreshnessWindow) {
        return;  // recent enough — leave the UI as it is, make no request
    }

    Credentials *creds = ReadCredentials();
    if (creds.accessToken.length == 0) {
        [self renderState:UsageStateNoCredentials limits:@[] message:nil];
        return;
    }
    _creds = creds;
    _renewedThisCycle = NO;

    // An expired access token is renewed here, never sent. The usage endpoint
    // answers a dead token with a 401, and enough of those with a flat
    // one-hour 429 — so the only place an expired token ever goes is the token
    // endpoint, in exchange for a live one.
    if (creds.isExpired) {
        if (!creds.refreshToken) {
            [self renderState:UsageStateExpired limits:@[] message:@"no refresh token stored"];
            return;
        }
        // A renewal that already failed for this exact stored token is not
        // retried on the timer; that would turn one dead refresh token into a
        // stream of pointless calls. The Refresh button retries once, by hand.
        if (!forced && [self renewalAlreadyFailedFor:creds]) {
            [self renderState:UsageStateExpired limits:@[] message:nil];
            return;
        }
        [self markInFlight:YES];
        _renewedThisCycle = YES;
        __weak AppDelegate *weakSelf = self;
        [self renewCredentials:creds then:^(Credentials *fresh, NSString *failure, BOOL transient) {
            AppDelegate *strong = weakSelf;
            if (!strong) return;
            if (fresh) {
                strong->_creds = fresh;
                [strong continueWithCredentials:fresh];
                return;
            }
            [strong markInFlight:NO];
            if (transient) { [strong renderDegradedWithNote:[strong offlineNote]]; return; }
            [strong rememberRenewalFailedFor:creds];
            [strong renderState:UsageStateExpired limits:@[] message:failure];
        }];
        return;
    }

    [self markInFlight:YES];
    [self continueWithCredentials:creds];
}

/// The profile hop (once per machine, for the plan name) and then the usage
/// fetch. Split out so a freshly renewed token enters the same path.
- (void)continueWithCredentials:(Credentials *)creds {
    NSString *token = creds.accessToken;
    __weak AppDelegate *weakSelf = self;
    if (_planName.length == 0) {
        [self request:kProfileURL token:token done:^(NSInteger code, NSData *data,
                                                     NSError *error, NSHTTPURLResponse *http) {
            AppDelegate *strong = weakSelf;
            if (!strong) return;
            if (code == 429 || code >= 500) {
                // Don't spend a second request into an active refusal.
                LogFailure(code, http, data, @"profile");
                [strong backOffAfter:code http:http];
                [strong renderDegradedWithNote:[strong waitNote]];
                return;
            }
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
        [strong markInFlight:NO];   // end of the chain, whatever happened

        if (error) {
            if (IsTransientNetworkError(error)) {
                // Log at most one of these an hour: eleven identical timeouts
                // overnight is noise that buries the lines worth reading.
                NSDate *last = strong->_lastTransientLog;
                if (!last || -[last timeIntervalSinceNow] > 3600) {
                    LogFailure(0, http, nil,
                               [@"transient: " stringByAppendingString:error.localizedDescription]);
                    strong->_lastTransientLog = [NSDate date];
                }
                [strong renderDegradedWithNote:[strong offlineNote]];
                return;
            }
            LogFailure(0, http, nil, error.localizedDescription);
            [strong renderDegradedWithNote:[NSString stringWithFormat:@"Network error: %@",
                                            error.localizedDescription]];
            return;
        }
        if (code == 401 || code == 403) {
            LogFailure(code, http, data, @"usage");
            // A token we believed valid was refused. One renewal, then stop: a
            // second refusal means revoked, not stale, and retrying would just
            // rebuild the pile of 401s that earns an hour-long 429.
            Credentials *creds = strong->_creds;
            if (!strong->_renewedThisCycle && creds.refreshToken) {
                strong->_renewedThisCycle = YES;
                [strong markInFlight:YES];
                [strong renewCredentials:creds
                                    then:^(Credentials *fresh, NSString *failure, BOOL transient) {
                    AppDelegate *again = weakSelf;
                    if (!again) return;
                    if (fresh) {
                        again->_creds = fresh;
                        [again fetchUsageWithToken:fresh.accessToken];
                        return;
                    }
                    [again markInFlight:NO];
                    if (transient) { [again renderDegradedWithNote:[again offlineNote]]; return; }
                    [again rememberRenewalFailedFor:creds];
                    [again renderState:UsageStateExpired limits:@[] message:failure];
                }];
                return;
            }
            [strong rememberRenewalFailedFor:creds];
            [strong renderState:UsageStateExpired limits:@[] message:nil];
            return;
        }
        if (code == 429 || code >= 500) {
            LogFailure(code, http, data, @"usage");
            [strong backOffAfter:code http:http];
            [strong renderDegradedWithNote:[strong waitNote]];
            return;
        }
        if (code != 200 || !data) {
            LogFailure(code, http, data, @"usage");
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
        strong->_fromClaudeCode = NO;
        [strong clearRenewalFailure];
        [strong rememberCooldown];
        strong->_lastSuccess = [NSDate date];
        strong->_dataAsOf    = strong->_lastSuccess;
        strong->_lastLimits  = limits;
        [strong renderState:UsageStateOK limits:limits message:nil];
    }];
}

#pragma mark Token renewal

/// POST JSON. Completion lands on the main thread like every other request.
- (void)postJSON:(NSDictionary *)body
              to:(NSString *)urlString
            done:(void (^)(NSInteger code, NSData *data, NSError *error,
                           NSHTTPURLResponse *http))done {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"ClaudeUsageBar/1.0" forHTTPHeaderField:@"User-Agent"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];

    NSURLSessionDataTask *task =
        [[self session] dataTaskWithRequest:req
                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                                ? (NSHTTPURLResponse *)response : nil;
        NSInteger code = http ? http.statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{ done(code, data, error, http); });
    }];
    [task resume];
}

/// Renew the access token with the refresh token and store the result where
/// Claude Code will find it. This mirrors Claude Code's own refresh exactly —
/// same endpoint, same client id, same body, same merge into the same keychain
/// item with the same encoding. That symmetry is the whole safety argument for
/// touching a credential two apps share.
///
/// Before the write, the item as it stood is copied to a second keychain entry
/// (kBackupService), so a bad write is one `security` command from undone.
/// A failed write is reported, not fatal: the renewed token still works for
/// this session, and Claude Code renews its own copy the next time it runs.
- (void)renewCredentials:(Credentials *)creds
                    then:(void (^)(Credentials *fresh, NSString *failure, BOOL transient))done {
    NSDictionary *body = @{ @"grant_type":    @"refresh_token",
                            @"refresh_token": creds.refreshToken,
                            @"client_id":     kClientID,
                            @"scope":         creds.scope ?: kDefaultScope };

    __weak AppDelegate *weakSelf = self;
    [self postJSON:body to:kTokenURL done:^(NSInteger code, NSData *data,
                                            NSError *error, NSHTTPURLResponse *http) {
        AppDelegate *strong = weakSelf;
        if (!strong) return;

        if (error) {
            LogFailure(0, http, nil, [@"renew: " stringByAppendingString:error.localizedDescription]);
            done(nil, error.localizedDescription, IsTransientNetworkError(error));
            return;
        }
        if (code == 429 || code >= 500) {
            LogFailure(code, http, data, @"renew");
            done(nil, [NSString stringWithFormat:@"token endpoint returned HTTP %ld", (long)code], YES);
            return;
        }
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSDictionary *resp = [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
        if (code != 200 || !resp) {
            // invalid_grant and friends: the refresh token itself is dead.
            LogFailure(code, http, data, @"renew");
            NSString *why = [resp[@"error"] isKindOfClass:[NSString class]]
                          ? resp[@"error"] : [NSString stringWithFormat:@"HTTP %ld", (long)code];
            done(nil, why, NO);
            return;
        }

        NSDictionary *merged = MergeRefreshResponse(creds.blob, resp, [NSDate date]);
        NSString *json = merged ? JSONText(merged) : nil;
        Credentials *fresh = json ? CredentialsFromJSONText(json) : nil;
        if (!fresh || fresh.isExpired) {
            LogFailure(code, http, data, @"renew: unusable token response");
            done(nil, @"unusable token response", NO);
            return;
        }
        fresh.service = creds.service;
        fresh.account = creds.account;

        if (creds.service && creds.account) {
            NSString *previous = JSONText(creds.blob);
            if (previous) WriteKeychainItem(kBackupService, creds.account, previous, NULL);
            NSString *why = nil;
            if (!WriteKeychainItem(creds.service, creds.account, json, &why)) {
                LogFailure(0, nil, nil, [@"renew: keychain write failed: "
                                         stringByAppendingString:why ?: @"?"]);
            }
        } else {
            NSString *path = [@"~/.claude/.credentials.json" stringByExpandingTildeInPath];
            NSError *werr = nil;
            [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&werr];
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                                             ofItemAtPath:path error:NULL];
            if (werr) LogFailure(0, nil, nil, [@"renew: file write failed: "
                                               stringByAppendingString:werr.localizedDescription]);
        }
        done(fresh, nil, NO);
    }];
}

/// Keyed by the stored token's expiry — no secret material — which changes the
/// moment the user signs in again, so a fresh sign-in is always retried.
- (BOOL)renewalAlreadyFailedFor:(Credentials *)creds {
    double failedFor = [[NSUserDefaults standardUserDefaults] doubleForKey:@"RenewalFailedForExpiry"];
    return failedFor > 0 && creds.expires &&
           fabs([creds.expires timeIntervalSince1970] - failedFor) < 1.0;
}

- (void)rememberRenewalFailedFor:(Credentials *)creds {
    _authExpired = YES;
    if (creds.expires) {
        [[NSUserDefaults standardUserDefaults] setDouble:[creds.expires timeIntervalSince1970]
                                                  forKey:@"RenewalFailedForExpiry"];
    }
}

- (void)clearRenewalFailure {
    _authExpired = NO;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"RenewalFailedForExpiry"];
}

/// Honour the server's own cooldown when it sends one, otherwise climb the
/// local ladder. Kept in one place so the profile and usage calls can't drift.
/// Persisted, because it used to live only in memory. Quitting and reopening
/// the app wiped an outstanding cooldown and fired a request straight back into
/// it — which is how a one-hour Retry-After turned into an afternoon of them.
- (void)rememberCooldown {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (_nextAllowed) {
        [d setDouble:[_nextAllowed timeIntervalSince1970] forKey:@"NextAllowedAt"];
        [d setDouble:_backoff forKey:@"Backoff"];
    } else {
        [d removeObjectForKey:@"NextAllowedAt"];
        [d removeObjectForKey:@"Backoff"];
    }
}

- (void)restoreCooldown {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    double at = [d doubleForKey:@"NextAllowedAt"];
    if (at <= 0) return;
    NSDate *when = [NSDate dateWithTimeIntervalSince1970:at];
    if ([when timeIntervalSinceNow] <= 0) { [self rememberCooldown]; return; }
    _nextAllowed = when;
    _backoff     = [d doubleForKey:@"Backoff"];
    _serverAsked = YES;   // only a server-set wait is worth surviving a restart
}

- (void)backOffAfter:(NSInteger)code http:(NSHTTPURLResponse *)http {
    [self markInFlight:NO];
    NSTimeInterval retryAfter = RetryAfterSeconds(http);
    if (retryAfter > 0) {
        _backoff = retryAfter;
        _serverAsked = YES;
    } else {
        _serverAsked = NO;
        _backoff = _backoff > 0 ? MIN(_backoff * 2, 1800)   // cap at 30 minutes
                                : 120;                      // first refusal: 2 minutes
    }
    _nextAllowed = [NSDate dateWithTimeIntervalSinceNow:_backoff];
    [self rememberCooldown];
}

/// Take Claude Code's cached copy only when it beats what we already have.
/// Strictly newer, never merely different: our own last fetch is usually the
/// better source, and silently swapping in older numbers would be a regression
/// dressed up as a fallback.
- (BOOL)adoptClaudeCodeCacheIfNewer {
    NSDate *fetched = nil;
    NSArray<LimitInfo *> *limits = LimitsFromClaudeCode(&fetched);
    if (limits.count == 0 || !fetched) return NO;
    if (_dataAsOf && [fetched compare:_dataAsOf] != NSOrderedDescending) return NO;

    _lastLimits  = limits;
    _dataAsOf    = fetched;
    _fromClaudeCode = YES;
    return YES;
}

/// Keep the last good numbers on screen when a fetch fails, with a footnote
/// explaining why they might be stale. Better than a wall of JSON.
- (void)renderDegradedWithNote:(NSString *)note {
    [self adoptClaudeCodeCacheIfNewer];
    if (_lastLimits.count > 0) {
        [self renderState:UsageStateOK limits:_lastLimits message:note];
    } else {
        [self renderState:UsageStateError limits:@[] message:note];
    }
}

/// What the popover says when the network, not the server, is the problem.
- (NSString *)offlineNote {
    if (_dataAsOf) {
        return [NSString stringWithFormat:@"Offline — showing values from %@. Will retry.",
                AgeText(_dataAsOf)];
    }
    return @"Offline — will retry when the connection is back.";
}

- (NSString *)waitNote {
    NSTimeInterval remaining = _nextAllowed ? [_nextAllowed timeIntervalSinceNow] : 0;
    if (remaining < 0) remaining = 0;
    long minutes = (long)ceil(remaining / 60.0);
    NSString *when = minutes <= 1 ? @"under a minute"
                                  : [NSString stringWithFormat:@"%ld more minutes", minutes];

    // Say whose cooldown this is. "The server asked for 40 minutes" and "we
    // backed off for 30 minutes on our own" are different problems, and the
    // note is the only place the difference is visible.
    NSString *whose = _serverAsked ? @"The server asked us to wait" : @"Backing off";
    if (_authExpired) {
        return [NSString stringWithFormat:
                @"Your token expired — run `claude` in Terminal once, then press "
                 "Refresh. (Also rate limited: %@ %@.)", whose, when];
    }

    if (_dataAsOf) {
        return [NSString stringWithFormat:@"Rate limited — showing %@ from %@. %@ %@.",
                _fromClaudeCode ? @"Claude Code's numbers" : @"the last values fetched",
                AgeText(_dataAsOf), whose, when];
    }
    return [NSString stringWithFormat:@"Rate limited by the server. %@ %@.", whose, when];
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
    _dataAsOf   = when;   // not _lastSuccess: that would suppress the live fetch
    [self renderState:UsageStateOK limits:limits message:note];
    return YES;
}

#pragma mark Rendering

/// Applies the current MenuBarStyle. The status item's width is the sum of what
/// we put in it, and on a full menu bar that width decides whether macOS shows
/// the item at all.
- (void)applyButton:(NSImage *)image title:(NSString *)title tone:(NSColor *)tone {
    NSStatusBarButton *button = _statusItem.button;
    if (!button) return;

    NSString *style = MenuBarStyle();
    if ([style isEqualToString:@"icon"]) {
        button.image = image;
        button.attributedTitle = [[NSAttributedString alloc] initWithString:@""];
        return;
    }

    BOOL compact = ![style isEqualToString:@"gauge"];
    button.image = compact ? nil : image;

    NSString *text = compact ? title : [@" " stringByAppendingString:title];
    button.attributedTitle = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSForegroundColorAttributeName: tone ?: [NSColor labelColor],
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12
                                                              weight:NSFontWeightRegular],
    }];
}

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
            LimitInfo *shown = MenuBarLimit(limits);
            [self applyButton:GaugeImage(@(RemainingFraction(shown)), GradientForLimit(shown))
                        title:[NSString stringWithFormat:@"%ld%%", RemainingPercent(shown)]
                         tone:TextColorForLimit(shown)];

            NSMutableArray *lines = [NSMutableArray array];
            for (LimitInfo *l in limits) {
                [lines addObject:[NSString stringWithFormat:@"%@: %ld%% · %@",
                                  l.title, (long)lround(l.fraction * 100), ResetText(l.resets)]];
            }
            button.toolTip = [lines componentsJoinedByString:@"\n"];
        } else if (state == UsageStateLoading) {
            [self applyButton:GaugeImage(nil, nil) title:@"…" tone:[NSColor labelColor]];
            button.toolTip = @"Loading Claude usage…";
        } else if (state == UsageStateExpired) {
            [self applyButton:GaugeImage(nil, nil) title:@"!" tone:[NSColor systemRedColor]];
            button.toolTip = @"Claude sign-in expired and couldn't be renewed — click for a one-click fix";
        } else {
            [self applyButton:GaugeImage(nil, nil) title:@"—" tone:[NSColor labelColor]];
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
