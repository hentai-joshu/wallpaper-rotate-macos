#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#import <CoreGraphics/CoreGraphics.h>

static NSString *const kPaused = @"paused";
static NSString *const kInterval = @"interval";
static const NSTimeInterval kDefaultInterval = 1800;
static NSString *const kLast   = @"lastImage";
static NSString *const kGallery = @"gallery";
static NSString *const kAssign = @"spaceAssignments";
static NSString *const kRecent = @"recentImages";  // 最近用过的若干张，避免短时间内重复  // {spaceUUID: 图片绝对路径}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *item;
@property (strong) NSTimer *timer;
@property (copy)   NSString *gallery;
@end

@implementation AppDelegate {
    NSMutableDictionary *_intendedStorage;
    NSTimer *_spaceWatcher;
    // 换图进行中时不要去「对齐屏幕」：rotate 已经自己把当前桌面的屏换好了，
    // 而它后来给各桌面记的账要到 1.5 秒后才落盘，这中间 align 会把屏幕改回旧图。
    NSTimeInterval _suppressSyncUntil;
    // 每块屏「上一次看到的（应该是什么 / 现在是什么）」，用来识别过渡态
    NSMutableDictionary<NSString *, NSString *> *_pendingSync;
}

// 每个桌面被分配到哪张图，持久化下来：重启后仍知道哪些桌面已经分过，
// 也能区分「新建的桌面」和「早就存在的桌面」。
- (NSMutableDictionary *)assignments {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kAssign];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}
- (NSArray<NSString *> *)recentImages {
    return [[NSUserDefaults standardUserDefaults] arrayForKey:kRecent] ?: @[];
}
- (void)noteUsed:(NSString *)full {
    NSMutableArray<NSString *> *r = [[self recentImages] mutableCopy];
    [r removeObject:full];
    [r insertObject:full atIndex:0];
    const NSUInteger keep = 40;
    if (r.count > keep) [r removeObjectsInRange:NSMakeRange(keep, r.count - keep)];
    [[NSUserDefaults standardUserDefaults] setObject:r forKey:kRecent];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
// 从图库里挑一张「最近没出现过」的；实在挑不到就随机
- (NSString *)pickImageAvoiding:(NSSet<NSString *> *)avoid recent:(NSArray<NSString *> *)recent {
    NSArray<NSString *> *imgs = [self images];
    if (imgs.count == 0) return nil;
    for (int i = 0; i < 200; i++) {
        NSString *c = imgs[arc4random_uniform((uint32_t)imgs.count)];
        NSString *p = [self.gallery stringByAppendingPathComponent:c];
        if ([avoid containsObject:p]) continue;
        if ([recent containsObject:p]) continue;
        return p;
    }
    for (int i = 0; i < 40; i++) {
        NSString *c = imgs[arc4random_uniform((uint32_t)imgs.count)];
        NSString *p = [self.gallery stringByAppendingPathComponent:c];
        if (![avoid containsObject:p]) return p;
    }
    return [self.gallery stringByAppendingPathComponent:imgs[arc4random_uniform((uint32_t)imgs.count)]];
}

- (void)saveAssignments:(NSDictionary *)a {
    [[NSUserDefaults standardUserDefaults] setObject:a forKey:kAssign];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// 图库目录：优先用菜单里选过的，其次 ~/Pictures/Wallpapers，
// 再退到旧版本的 ~/Pictures/壁纸（老用户升级后不至于突然找不到图）。
- (NSString *)detectGallery {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kGallery];
    if (saved.length) return saved;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *candidates = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Pictures/Wallpapers"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Pictures/壁纸"],
    ];
    for (NSString *c in candidates) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:c isDirectory:&isDir] && isDir) return c;
    }
    return candidates.firstObject;
}

- (instancetype)init {
    self = [super init];
    _gallery = [self detectGallery];
    _pendingSync = [NSMutableDictionary dictionary];
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"photo.on.rectangle.angled" accessibilityDescription:@"壁纸轮换"];
    if (icon) icon.template = YES;
    self.item.button.image = icon;
    self.item.button.toolTip = @"壁纸轮换";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"壁纸轮换"];
    menu.delegate = self;
    self.item.menu = menu;
    [self restartTimer];
    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [nc addObserver:self selector:@selector(systemWillSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [nc addObserver:self selector:@selector(systemDidWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [nc addObserver:self selector:@selector(systemWillSleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [nc addObserver:self selector:@selector(systemDidWake:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    _intendedStorage = [self assignments];
    // 新建桌面时系统会沿用当前桌面的图，所以要盯着 Space 列表，发现新桌面就单独给它一张
    _spaceWatcher = [NSTimer scheduledTimerWithTimeInterval:4.0 target:self
                                                   selector:@selector(spaceWatcherFired:) userInfo:nil repeats:YES];
    // 切桌面/新建桌面会发这个通知，能立刻发现，不用等定时器
    [nc addObserver:self selector:@selector(spaceWatcherFired:) name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![weakSelf isPaused]) [weakSelf rotate:nil];
    });
}

- (NSTimeInterval)interval {
    NSTimeInterval v = [[NSUserDefaults standardUserDefaults] doubleForKey:kInterval];
    return v > 0 ? v : kDefaultInterval;
}

- (void)restartTimer {
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:[self interval] target:self selector:@selector(timerFired:) userInfo:nil repeats:YES];
    self.timer.tolerance = MIN(60, [self interval] * 0.1);
    NSLog(@"[wallpaper] timer armed: %.0f min, next fire %@", [self interval] / 60.0, self.timer.fireDate);
}

// 熄屏/睡眠期间不换图，省电也避免无谓的磁盘读取
- (BOOL)displayAsleep {
    return CGDisplayIsAsleep(CGMainDisplayID()) != 0;
}

- (void)timerFired:(NSTimer *)t {
    if ([self isPaused]) return;
    if ([self displayAsleep]) { NSLog(@"[wallpaper] display asleep, skip"); return; }
    [self rotate:nil];
}

- (void)setIntervalMinutes:(NSMenuItem *)sender {
    NSTimeInterval secs = [sender.representedObject doubleValue];
    [[NSUserDefaults standardUserDefaults] setDouble:secs forKey:kInterval];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self restartTimer];
    NSLog(@"[wallpaper] interval -> %.0f min", secs / 60.0);
}

- (void)systemWillSleep:(NSNotification *)n { [self.timer invalidate]; }
- (void)systemDidWake:(NSNotification *)n { [self restartTimer]; }

- (BOOL)isPaused { return [[NSUserDefaults standardUserDefaults] boolForKey:kPaused]; }
- (void)setPaused:(BOOL)p {
    [[NSUserDefaults standardUserDefaults] setBool:p forKey:kPaused];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSArray<NSString *> *)images {
    NSError *err = nil;
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.gallery error:&err];
    if (!all) return @[];
    NSSet *exts = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"heic", @"webp", @"tif", @"tiff"]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in all) {
        if ([name hasPrefix:@"."]) continue;
        if ([exts containsObject:name.pathExtension.lowercaseString]) [out addObject:name];
    }
    return out;
}

// ---------- 壁纸存储（Index.plist）读写 ----------
- (NSMutableDictionary *)loadStore {
    NSData *data = [NSData dataWithContentsOfFile:[self storePlistPath]];
    if (!data) return nil;
    id root = [NSPropertyListSerialization propertyListWithData:data
                                                        options:NSPropertyListMutableContainersAndLeaves
                                                         format:NULL error:NULL];
    return [root isKindOfClass:[NSMutableDictionary class]] ? root : nil;
}

- (BOOL)saveStore:(NSDictionary *)root {
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:root
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0 error:NULL];
    return out && [out writeToFile:[self storePlistPath] atomically:YES];
}

// 深度优先找一个图片类型的条目当模板（Provider = choice.image 且带 Files + Configuration）。
// 用 C 递归而不是 block：block 自引用会形成 retain cycle，而这里每次换图/修补都会跑。
static NSDictionary *FindImageTemplate(id node) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *n = node;
        NSArray *files = n[@"Files"];
        if ([n[@"Provider"] isEqualToString:@"com.apple.wallpaper.choice.image"]
            && [files isKindOfClass:[NSArray class]] && files.count > 0 && n[@"Configuration"]) {
            return n;
        }
        for (id v in [n allValues]) {
            NSDictionary *hit = FindImageTemplate(v);
            if (hit) return hit;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)node) {
            NSDictionary *hit = FindImageTemplate(v);
            if (hit) return hit;
        }
    }
    return nil;
}

// 找一个图片类型的条目当模板；没有就用上次缓存下来的
- (NSDictionary *)imageTemplateIn:(id)root {
    NSDictionary *found = FindImageTemplate(root);
    NSString *cache = [[self supportDir] stringByAppendingPathComponent:@"image-choice-template.plist"];
    if (found) {
        NSData *td = [NSPropertyListSerialization dataWithPropertyList:found
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0 error:NULL];
        [td writeToFile:cache atomically:YES];
        return found;
    }
    NSData *td = [NSData dataWithContentsOfFile:cache];
    if (!td) return nil;
    id t = [NSPropertyListSerialization propertyListWithData:td options:0 format:NULL error:NULL];
    return [t isKindOfClass:[NSDictionary class]] ? t : nil;
}

- (NSDictionary *)choiceForPath:(NSString *)path template:(NSDictionary *)tmpl {
    NSMutableDictionary *c = [tmpl mutableCopy];
    c[@"Files"] = @[ @{ @"relative": [[NSURL fileURLWithPath:path] absoluteString] } ];
    return c;
}

// 只替换第一条 choice，保留其余结构（Configuration 决定缩放方式等）
static BOOL PutChoice(id node, NSDictionary *choice, NSDate *now) {
    if (![node isKindOfClass:[NSMutableDictionary class]]) return NO;
    NSMutableDictionary *n = node;
    NSMutableDictionary *content = n[@"Content"];
    if (![content isKindOfClass:[NSMutableDictionary class]]) return NO;
    NSMutableArray *choices = content[@"Choices"];
    if (![choices isKindOfClass:[NSMutableArray class]] || choices.count == 0) return NO;
    choices[0] = [choice mutableCopy];
    n[@"LastSet"] = now;
    n[@"LastUse"] = now;
    return YES;
}

// 每个桌面（Space）各给一张**不同**的图；所有 Space 用同一套模板，只是图片不同。
// 注意：不要去改 AllSpacesAndDisplays 的 Type，也不要清空 Spaces/Displays——
// 那样 macOS 会把配置折叠成「所有空间共用一张」，反而丢掉各桌面各自的图。
- (NSUInteger)applyDistinctImagesToSpaces {
    NSMutableDictionary *d = [self loadStore];
    if (!d) return 0;
    NSDictionary *tmpl = [self imageTemplateIn:d];
    if (!tmpl) return 0;
    NSMutableDictionary *spaces = d[@"Spaces"];
    NSArray *sids = [[spaces allKeys] sortedArrayUsingSelector:@selector(compare:)];
    if (sids.count == 0) return 0;
    if ([self images].count == 0) return 0;

    NSArray<NSString *> *recent = [self recentImages];
    NSMutableDictionary *intended = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *used = [NSMutableSet set];
    NSDate *now = [NSDate date];
    NSUInteger n = 0;

    // 每个桌面里，每块屏各拿一张不同的图；不同桌面之间也不重复
    for (NSString *sid in sids) {
        NSMutableDictionary *sp = spaces[sid];
        NSMutableDictionary *disp = sp[@"Displays"];
        NSArray *dids = [[disp allKeys] sortedArrayUsingSelector:@selector(compare:)];
        NSString *first = nil;
        for (NSString *did in dids) {
            NSString *full = [self pickImageAvoiding:used recent:recent];
            if (!full) break;
            [used addObject:full];
            if (!first) first = full;
            NSDictionary *choice = [self choiceForPath:full template:tmpl];
            if (PutChoice(disp[did][@"Desktop"], choice, now)) n++;
            intended[[NSString stringWithFormat:@"%@/%@", sid, did]] = full;
        }
        if (first) {
            NSDictionary *choice = [self choiceForPath:first template:tmpl];
            if (PutChoice(sp[@"Default"][@"Desktop"], choice, now)) n++;
            intended[[NSString stringWithFormat:@"%@/Default", sid]] = first;
        }
    }
    // 全局 Displays（不属于任何桌面的那份）也各给一张
    NSMutableDictionary *gdisp = d[@"Displays"];
    for (NSString *did in [[gdisp allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *full = [self pickImageAvoiding:used recent:recent];
        if (!full) break;
        [used addObject:full];
        NSDictionary *choice = [self choiceForPath:full template:tmpl];
        if (PutChoice(gdisp[did][@"Desktop"], choice, now)) n++;
        intended[[NSString stringWithFormat:@"global/%@", did]] = full;
    }

    if (n == 0) return 0;
    if (![self saveStore:d]) return 0;
    _intendedStorage = intended;
    [self saveAssignments:intended];
    NSLog(@"[wallpaper] distinct %lu entries", (unsigned long)n);
    return n;
}

- (BOOL)applyUniformImage:(NSString *)path {
    NSMutableDictionary *d = [self loadStore];
    if (!d) return NO;
    NSDictionary *tmpl = [self imageTemplateIn:d];
    if (!tmpl) return NO;
    NSDictionary *choice = [self choiceForPath:path template:tmpl];
    NSDate *now = [NSDate date];
    NSUInteger n = 0;
    if (PutChoice(d[@"AllSpacesAndDisplays"][@"Desktop"], choice, now)) n++;
    if (PutChoice(d[@"SystemDefault"][@"Desktop"], choice, now)) n++;
    for (NSString *sid in d[@"Spaces"]) {
        NSMutableDictionary *sp = d[@"Spaces"][sid];
        if (PutChoice(sp[@"Default"][@"Desktop"], choice, now)) n++;
        NSMutableDictionary *disp = sp[@"Displays"];
        for (NSString *did in disp) if (PutChoice(disp[did][@"Desktop"], choice, now)) n++;
    }
    for (NSString *did in d[@"Displays"]) if (PutChoice(d[@"Displays"][did][@"Desktop"], choice, now)) n++;
    if (n == 0) return NO;
    if (![self saveStore:d]) return NO;
    [_intendedStorage removeAllObjects];
    [self saveAssignments:@{}];
    NSLog(@"[wallpaper] uniform %lu entries -> %@", (unsigned long)n, path.lastPathComponent);
    return YES;
}

// 必须用 SIGKILL：优雅退出时 WallpaperAgent 会把内存里的旧配置回写，覆盖刚写的文件。
- (void)restartWallpaperAgent {
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/killall";
    t.arguments = @[@"-9", @"WallpaperAgent"];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *ex) { NSLog(@"[wallpaper] killall failed: %@", ex); }
}

// 只对当前所有显示器调 API（只影响当前活跃 Space，其余靠改配置）
// 每块屏可以给不同的图：paths 与 NSScreen.screens 一一对应，数量不足时用最后一张。
// 把 NSScreen 换算成系统墙纸配置里用的显示器 UUID（AFBB3A24-… 这种）
- (NSString *)displayUUIDForScreen:(NSScreen *)s {
    NSNumber *num = s.deviceDescription[@"NSScreenNumber"];
    if (!num) return nil;
    CGDirectDisplayID did = (CGDirectDisplayID)num.unsignedIntValue;
    CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(did);
    if (!u) return nil;
    CFStringRef str = CFUUIDCreateString(NULL, u);
    NSString *out = [(__bridge NSString *)str copy];
    CFRelease(str); CFRelease(u);
    return out;
}

- (BOOL)setDesktopImagesForScreens:(NSArray<NSString *> *)paths {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    if (screens.count == 0 || paths.count == 0) return NO;
    NSDictionary *opts = @{
        NSWorkspaceDesktopImageScalingKey: @(NSImageScaleProportionallyUpOrDown),
        NSWorkspaceDesktopImageAllowClippingKey: @YES
    };
    BOOL ok = YES;
    for (NSUInteger i = 0; i < screens.count; i++) {
        NSString *p = i < paths.count ? paths[i] : paths.lastObject;
        NSError *e = nil;
        if (![[NSWorkspace sharedWorkspace] setDesktopImageURL:[NSURL fileURLWithPath:p]
                                                     forScreen:screens[i] options:opts error:&e]) {
            NSLog(@"[wallpaper] set failed: %@", e.localizedDescription);
            ok = NO;
        }
    }
    return ok;
}

// 代理重启后偶尔会把某个 Space 的旧条目写回去：只修「和自己定的不一样」的那些
// 把 choice 写进某个节点（node 是 {"Desktop": {...}} 这种容器）
// 当前每块屏上是哪个桌面（Space）。只有「正在显示的那个桌面」才能用
// NSWorkspace setDesktopImageURL 直接换图；换别的桌面会改到当前桌面身上。
static NSDictionary<NSString *, NSString *> *ActiveSpaceByDisplay(void) {
    static void *skylight;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY); });
    typedef int (*ConnFn)(void);
    typedef CFArrayRef (*CopySpacesFn)(int);
    ConnFn conn = skylight ? (ConnFn)dlsym(skylight, "_CGSDefaultConnection") : NULL;
    CopySpacesFn copy = skylight ? (CopySpacesFn)dlsym(skylight, "CGSCopyManagedDisplaySpaces") : NULL;
    if (!conn || !copy) return @{};
    CFArrayRef arr = copy(conn());
    if (!arr) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSDictionary *disp in (__bridge NSArray *)arr) {
        NSString *did = disp[@"Display Identifier"];
        NSString *sid = disp[@"Current Space"][@"uuid"];
        if (did && sid) out[[did uppercaseString]] = [sid uppercaseString];
    }
    CFRelease(arr);
    return out;
}

// 系统里真正存在的桌面（Space）UUID 集合。
// 配置文件的 Spaces 字典会永久保留历史上建过又删掉的桌面（本机实测 18 条，
// 活的只有 2 条），如果不加筛选，每次换图都会给这些幽灵桌面写一遍，
// 既写盘又让「配置漂移」检查每 4 秒命中一次。
static NSSet<NSString *> *LiveSpaceIDs(void) {
    static void *skylight;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY); });
    typedef int (*ConnFn)(void);
    typedef CFArrayRef (*CopySpacesFn)(int);
    ConnFn conn = skylight ? (ConnFn)dlsym(skylight, "_CGSDefaultConnection") : NULL;
    CopySpacesFn copy = skylight ? (CopySpacesFn)dlsym(skylight, "CGSCopyManagedDisplaySpaces") : NULL;
    if (!conn || !copy) return nil;
    CFArrayRef arr = copy(conn());
    if (!arr) return nil;
    NSMutableSet<NSString *> *out = [NSMutableSet set];
    for (NSDictionary *disp in (__bridge NSArray *)arr) {
        for (NSDictionary *sp in (disp[@"Spaces"] ?: @[])) {
            NSString *u = sp[@"uuid"];
            if (u) [out addObject:[u uppercaseString]];
        }
    }
    CFRelease(arr);
    return out;
}

static BOOL PutInto(id container, NSDictionary *choice, NSDate *now) {
    if (![container isKindOfClass:[NSDictionary class]]) return NO;
    id desk = container[@"Desktop"];
    if (!desk) return NO;
    return PutChoice(desk, choice, now);
}

// 按 _intendedStorage 里记的「某个桌面某块屏应该用哪张图」补写回配置文件。
// 不重启壁纸服务（重启会闪黑），下次切到那个桌面/那块屏时自然生效。
- (NSUInteger)repairKeys:(NSArray<NSString *> *)keys {
    if (keys.count == 0) return 0;
    NSMutableDictionary *d = [self loadStore];
    if (!d) return 0;
    NSDictionary *tmpl = [self imageTemplateIn:d];
    if (!tmpl) return 0;
    NSDate *now = [NSDate date];
    NSUInteger fixed = 0;
    for (NSString *key in keys) {
        NSString *full = _intendedStorage[key];
        NSString *want = [[NSURL fileURLWithPath:full] absoluteString];
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@"/"];
        if (parts.count != 2) continue;
        NSString *a = parts[0], *b = parts[1];
        id node = nil;
        if ([a isEqualToString:@"global"]) node = d[@"Displays"][b];
        else if ([b isEqualToString:@"Default"]) node = d[@"Spaces"][a][@"Default"];
        else node = d[@"Spaces"][a][@"Displays"][b];
        if (!node) continue;
        id desk = node[@"Desktop"];
        NSString *have = (desk[@"Content"][@"Choices"][0][@"Files"]) ? desk[@"Content"][@"Choices"][0][@"Files"][0][@"relative"] : nil;
        if ([have isEqualToString:want]) continue;
        NSDictionary *choice = [self choiceForPath:full template:tmpl];
        if (PutInto(node, choice, now)) fixed++;
    }
    if (fixed == 0) return 0;
    if (![self saveStore:d]) return 0;
    NSLog(@"[wallpaper] repaired %lu entries (no restart)", (unsigned long)fixed);
    return fixed;
}

- (void)repairDistinctEntries {
    [self repairKeys:[_intendedStorage allKeys]];
}

// 当前桌面的各块屏已经用系统 API 换好了（不重启服务、不黑屏），
// 这里只给「其它桌面」的每块屏各写一张不同的图进配置文件，切过去时才渲染。
// 系统里出现过的所有显示器 UUID（各桌面 + 全局），用来给每个桌面都写全两块屏
- (NSArray<NSString *> *)allDisplayUUIDsIn:(NSDictionary *)d {
    NSMutableSet<NSString *> *s = [NSMutableSet set];
    for (NSString *did in (d[@"Displays"] ?: @{})) [s addObject:did];
    for (NSString *sid in (d[@"Spaces"] ?: @{}))
        for (NSString *did in (d[@"Spaces"][sid][@"Displays"] ?: @{})) [s addObject:did];
    for (NSScreen *sc in [NSScreen screens]) {
        NSString *u = [self displayUUIDForScreen:sc];
        if (u) [s addObject:u];
    }
    return [[s allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

// 找出「当前正在显示的这个桌面」是哪一条：
// 换图后壁纸服务会把当前桌面的配置改成刚设的那张，所以拿屏幕上的图去比对就能认出来。
- (NSSet<NSString *> *)currentSpaceIDsMatching:(NSSet<NSString *> *)paths {
    NSMutableDictionary *d = [self loadStore];
    NSDictionary *spaces = d[@"Spaces"];
    NSMutableSet<NSString *> *out = [NSMutableSet set];
    for (NSString *sid in spaces) {
        BOOL found = NO;
        NSMutableDictionary *sp = spaces[sid];
        NSMutableArray<NSString *> *cand = [NSMutableArray array];
        NSString *rel = sp[@"Default"][@"Desktop"][@"Content"][@"Choices"][0][@"Files"][0][@"relative"];
        if (rel && [NSURL URLWithString:rel].path) [cand addObject:[NSURL URLWithString:rel].path];
        for (NSString *did in (sp[@"Displays"] ?: @{})) {
            NSString *r2 = sp[@"Displays"][did][@"Desktop"][@"Content"][@"Choices"][0][@"Files"][0][@"relative"];
            if (r2 && [NSURL URLWithString:r2].path) [cand addObject:[NSURL URLWithString:r2].path];
        }
        for (NSString *p in cand) if ([paths containsObject:p]) { found = YES; break; }
        if (found) [out addObject:sid];
    }
    return out;
}

// 给「其它桌面」的每块屏各写一张不同的图（当前桌面已经在屏幕上换好了，跳过它，
// 但要把它的条目按实际显示记账，免得 4 秒后的 repair 把屏幕上的图改掉）。
- (NSUInteger)assignDistinctForOtherSpaces:(NSDictionary<NSString *, NSString *> *)currentByDisplay
                                 skipSids:(NSSet<NSString *> *)curSids
                               defaultPath:(NSString *)defaultPath {
    NSMutableDictionary *d = [self loadStore];
    if (!d) return 0;
    NSDictionary *tmpl = [self imageTemplateIn:d];
    if (!tmpl) return 0;
    NSMutableDictionary *spaces = d[@"Spaces"];
    if (!spaces) return 0;
    if ([self images].count == 0) return 0;

    NSArray<NSString *> *recent = [self recentImages];
    NSMutableSet<NSString *> *used = [NSMutableSet setWithArray:[currentByDisplay allValues]];
    NSMutableDictionary *intended = [NSMutableDictionary dictionary];
    NSDate *now = [NSDate date];
    NSUInteger n = 0;

    NSSet<NSString *> *live = LiveSpaceIDs();
    for (NSString *sid in [[spaces allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        // 只在真实存在的桌面上动手：配置文件里那些建过又删掉的桌面永远不显示，
        // 给它们写图只会让「配置漂移」检查一直命中。
        if (live && ![live containsObject:sid]) continue;
        NSMutableDictionary *sp = spaces[sid];
        NSMutableDictionary *disp = sp[@"Displays"];

        if (curSids && [curSids containsObject:sid]) {
            // 当前桌面：配置里就写屏幕上正在显示的那几张，不要再换
            for (NSString *did in disp) {
                NSString *p = currentByDisplay[did];
                if (!p) continue;
                if (PutInto(disp[did], [self choiceForPath:p template:tmpl], now)) n++;
                intended[[NSString stringWithFormat:@"%@/%@", sid, did]] = p;
            }
            // Default 用这个桌面自己那块屏的图，别用全局的——两块屏分属两个桌面时，
            // 否则这两个桌面的 Default 会写成同一张，新建桌面克隆过去又是同一张图
            NSString *def = nil;
            for (NSString *did in disp) { if (currentByDisplay[did]) { def = currentByDisplay[did]; break; } }
            if (!def) def = defaultPath ?: [currentByDisplay allValues].firstObject;
            if (def) {
                if (PutInto(sp[@"Default"], [self choiceForPath:def template:tmpl], now)) n++;
                intended[[NSString stringWithFormat:@"%@/Default", sid]] = def;
            }
            continue;
        }

        NSString *first = nil;
        for (NSString *did in [self allDisplayUUIDsIn:d]) {
            NSString *full = [self pickImageAvoiding:used recent:recent];
            if (!full) break;
            [used addObject:full];
            if (!first) first = full;
            if (!disp[did]) {
                // 这个桌面还没为这块屏写过条目：按模板造一个完整的（含 Content.Choices），
                // 否则 PutChoice 找不到 Choices 会写不进去，屏幕上就是空的。
                NSDictionary *tmplChoice = [self choiceForPath:full template:tmpl];
                disp[did] = [@{
                    @"Desktop": [@{
                        @"Content": [@{@"Choices": [@[[tmplChoice mutableCopy]] mutableCopy]} mutableCopy],
                        @"LastSet": now,
                        @"LastUse": now
                    } mutableCopy]
                } mutableCopy];
            }
            if (PutInto(disp[did], [self choiceForPath:full template:tmpl], now)) n++;
            intended[[NSString stringWithFormat:@"%@/%@", sid, did]] = full;
        }
        if (first) {
            if (PutInto(sp[@"Default"], [self choiceForPath:first template:tmpl], now)) n++;
            intended[[NSString stringWithFormat:@"%@/Default", sid]] = first;
        }
    }
    // 全局 Displays 那份（不属于任何桌面）也各给一张，避开当前桌面的。
    // 只写当前接着的屏：拔掉的外接屏留下的条目没有任何用处。
    NSMutableSet<NSString *> *connected = [NSMutableSet set];
    for (NSScreen *sc in [NSScreen screens]) {
        NSString *u = [self displayUUIDForScreen:sc];
        if (u) [connected addObject:u];
    }
    for (NSString *did in [[d[@"Displays"] allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (connected.count > 0 && ![connected containsObject:did]) continue;
        NSString *full = [self pickImageAvoiding:used recent:recent];
        if (!full) break;
        [used addObject:full];
        if (PutInto(d[@"Displays"][did], [self choiceForPath:full template:tmpl], now)) n++;
        intended[[NSString stringWithFormat:@"global/%@", did]] = full;
    }
    if (n == 0) return 0;
    if (![self saveStore:d]) return 0;
    _intendedStorage = intended;
    [self saveAssignments:intended];
    return n;
}

// 此刻每块屏正在显示哪个桌面（Space）。这是唯一可靠的「当前桌面」来源：
// 早先靠「屏幕上的图 == 配置里的图」去猜，换图那一瞬猜出来的往往是上一个桌面。
- (NSSet<NSString *> *)activeSpaceIDs {
    NSMutableSet<NSString *> *out = [NSMutableSet set];
    for (NSString *sid in [ActiveSpaceByDisplay() allValues]) [out addObject:sid];
    return out;
}

// 定时看桌面列表：出现没见过的桌面就单独给它每块屏各分一张不同的图
// 每块屏现在显示的是哪个桌面，就让它和那个桌面的配置图一致。
// 新建桌面、切桌面之后靠这个把屏幕和配置对齐——不会去动没在显示的桌面。
- (NSUInteger)syncActiveScreens {
    if ([self isPaused]) return 0;
    // 换图流程刚跑过（rotate 已经自己把屏换好了，它给各桌面记的账要 1.5 秒后才落盘）：
    // 这中间去「对齐」读到的是换图前的旧记录，会把刚换好的屏再改回去 —— 那正是
    // 「切桌面时连换两张」的来源之一。
    if ([NSDate timeIntervalSinceReferenceDate] < _suppressSyncUntil) return 0;
    NSDictionary<NSString *, NSString *> *active = ActiveSpaceByDisplay();
    if (active.count == 0) return 0;
    NSMutableDictionary *d = [self loadStore];
    NSDictionary *spaces = d[@"Spaces"];
    if (!spaces) return 0;
    NSDictionary *intended = [self assignments];
    NSUInteger painted = 0;
    for (NSScreen *sc in [NSScreen screens]) {
        NSString *did = [self displayUUIDForScreen:sc];
        if (!did) continue;
        NSString *sid = active[did];
        if (!sid || !spaces[sid]) continue;
        NSString *want = intended[[NSString stringWithFormat:@"%@/%@", sid, did]];
        if (!want) continue;                       // 这个桌面还没被分配过，交给别的逻辑
        NSString *cur = [[[NSWorkspace sharedWorkspace] desktopImageURLForScreen:sc] path];
        if (cur && [cur isEqualToString:want]) { [_pendingSync removeObjectForKey:did]; continue; }
        if (![[NSFileManager defaultManager] fileExistsAtPath:want]) continue;
        // 刚切到某个桌面时，壁纸服务先铺配置里的图、随后才轮到我们，这中间屏幕上
        // 「还不是想要的那张」属于正常过渡；此刻立刻纠正就会看到连换两张。
        // 所以同一个不一致要连续观察到两次（约 4 秒后）才动手，过渡态直接放过。
        NSString *sig = [NSString stringWithFormat:@"%@|%@", want, cur ?: @""];
        if (![_pendingSync[did] isEqualToString:sig]) { _pendingSync[did] = sig; continue; }
        [_pendingSync removeObjectForKey:did];
        NSDictionary *opts = @{
            NSWorkspaceDesktopImageScalingKey: @(NSImageScaleProportionallyUpOrDown),
            NSWorkspaceDesktopImageAllowClippingKey: @YES
        };
        NSError *e = nil;
        if ([[NSWorkspace sharedWorkspace] setDesktopImageURL:[NSURL fileURLWithPath:want]
                                                    forScreen:sc options:opts error:&e])
            { NSLog(@"[wallpaper] synced %@ -> %@", [did substringToIndex:8], want.lastPathComponent); painted++; }
        else
            NSLog(@"[wallpaper] sync failed: %@", e.localizedDescription);
    }
    return painted;
}

// 只在「配置和记录对不上」时才重写，而且只重写对不上的那几条。
// 桌面被关掉、外接屏被拔掉之后，记录里会留下永远匹配不上的条目，
// 以前那种「发现一条不符就全量重写 40 条」的做法会每 4 秒空转写一次 plist；
// 现在先清掉失效记录，再只补真正漂移的那几条。
- (void)repairDistinctEntriesIfDrifted {
    NSMutableDictionary *d = [self loadStore];
    if (!d) return;
    NSMutableDictionary *intended = [self assignments];
    if (intended.count == 0) return;
    NSDictionary *spaces = d[@"Spaces"] ?: @{};
    NSMutableArray<NSString *> *drifted = [NSMutableArray array];
    NSMutableArray<NSString *> *stale = [NSMutableArray array];
    NSSet<NSString *> *live = LiveSpaceIDs();
    NSMutableSet<NSString *> *connected = [NSMutableSet set];
    for (NSScreen *sc in [NSScreen screens]) {
        NSString *u = [self displayUUIDForScreen:sc];
        if (u) [connected addObject:u];
    }
    for (NSString *key in intended) {
        NSArray *parts = [key componentsSeparatedByString:@"/"];
        if (parts.count != 2) { [stale addObject:key]; continue; }
        NSString *sid = parts[0], *did = parts[1];
        // 已经不存在（或早已删掉）的桌面：它的配置条目永远匹配不上，
        // 留着只会让这里每 4 秒判一次漂移。
        if (![sid isEqualToString:@"global"] && live && ![live containsObject:sid]) { [stale addObject:key]; continue; }
        if ([sid isEqualToString:@"global"] && connected.count > 0 && ![connected containsObject:did]) { [stale addObject:key]; continue; }
        id node = nil;
        if ([sid isEqualToString:@"global"]) node = d[@"Displays"][did];
        else if ([did isEqualToString:@"Default"]) node = spaces[sid][@"Default"];
        else node = spaces[sid][@"Displays"][did];
        if (!node) { [stale addObject:key]; continue; }   // 这个桌面或这块屏已经不在了
        NSString *rel = node[@"Desktop"][@"Content"][@"Choices"][0][@"Files"][0][@"relative"];
        NSString *have = rel ? [NSURL URLWithString:rel].path : nil;
        if (![have isEqualToString:intended[key]]) [drifted addObject:key];
    }
    if (stale.count > 0) {
        for (NSString *k in stale) [intended removeObjectForKey:k];
        [self saveAssignments:intended];
        _intendedStorage = [intended mutableCopy];
        NSLog(@"[wallpaper] dropped %lu stale assignment(s)", (unsigned long)stale.count);
    }
    if (drifted.count == 0) return;
    NSLog(@"[wallpaper] config drift on %@", [drifted componentsJoinedByString:@", "]);
    [self repairKeys:drifted];
}

- (void)spaceWatcherFired:(NSTimer *)t {
    NSUInteger painted = [self syncActiveScreens];
    // 刚用系统 API 换过屏就别在同一拍里再改配置文件：壁纸服务会按新配置重画一次，
    // 屏幕上就会看到「换一张、又换一张」。等下一拍（4 秒后）再补配置。
    if (![self isPaused] && painted == 0) [self repairDistinctEntriesIfDrifted];
    NSMutableDictionary *d = [self loadStore];
    NSDictionary *spaces = d[@"Spaces"];
    if (!spaces || spaces.count == 0) return;

    NSMutableDictionary *asg = [self assignments];
    NSMutableSet<NSString *> *known = [NSMutableSet set];
    for (NSString *k in asg) [known addObject:[[k componentsSeparatedByString:@"/"] firstObject]];
    BOOL pruned = NO;
    for (NSString *sid in [known copy]) {
        if (!spaces[sid]) { [asg removeObjectForKey:sid]; pruned = YES; }
    }
    if (pruned) [self saveAssignments:asg];

    // 只有系统里真实存在的桌面才算「新桌面」。配置文件的 Spaces 会永久保留
    // 历史上建过又删掉的条目（本机 18 条里活的是 2 条），不筛掉的话这里每 4 秒
    // 都会把它们当成新桌面重新分配一次，然后又在下一次检查里被判成 stale 删掉，
    // 于是 plist 被反复写、日志刷屏——这正是之前「反复 detected N new space(s)」的根因。
    NSSet<NSString *> *live = LiveSpaceIDs();
    NSMutableArray<NSString *> *fresh = [NSMutableArray array];
    for (NSString *sid in [[spaces allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (live && ![live containsObject:sid]) continue;
        if (![known containsObject:sid]) [fresh addObject:sid];
    }
    if (fresh.count == 0) return;
    if ([self isPaused]) {
        NSLog(@"[wallpaper] %lu new space(s) while paused, leave to office default", (unsigned long)fresh.count);
        return;
    }
    NSLog(@"[wallpaper] detected %lu new space(s)", (unsigned long)fresh.count);
    [self applyFreshSpaces:fresh];
}

// 新建桌面会沿用原桌面的图，而且它就是当前正在显示的那个桌面。
// 只改配置文件屏幕不会变（壁纸服务不重读），所以先用系统 API 把屏幕真正换掉，
// 再把同样的图写进这个新桌面的配置，切走再切回来才不会变回旧图。
- (void)applyFreshSpaces:(NSArray<NSString *> *)fresh {
    NSMutableDictionary *d = [self loadStore];
    NSDictionary *tmpl = [self imageTemplateIn:d];
    if (!tmpl) return;

    // 其它桌面已经在用的图，先收集起来避开
    NSMutableSet<NSString *> *used = [NSMutableSet set];
    NSDictionary *spaces = d[@"Spaces"];
    for (NSString *sid in spaces) {
        if ([fresh containsObject:sid]) continue;
        NSArray *nodes = @[spaces[sid][@"Default"] ?: [NSNull null]];
        for (NSString *did in (spaces[sid][@"Displays"] ?: @{}))
            nodes = [nodes arrayByAddingObject:spaces[sid][@"Displays"][did] ?: [NSNull null]];
        for (id node in nodes) {
            if (node == [NSNull null]) continue;
            NSString *rel = node[@"Desktop"][@"Content"][@"Choices"][0][@"Files"][0][@"relative"];
            NSString *path = rel ? [NSURL URLWithString:rel].path : nil;
            if (path) [used addObject:path];
        }
    }

    // 先给每个「新桌面 × 它名下的屏」定好一张图
    NSArray<NSString *> *recent = [self recentImages];
    NSMutableDictionary<NSString *, NSString *> *pick = [NSMutableDictionary dictionary];  // "sid/did" -> path
    for (NSString *sid in fresh) {
        NSMutableDictionary *disp = spaces[sid][@"Displays"];
        for (NSString *did in (disp ?: @{})) {
            NSString *full = [self pickImageAvoiding:used recent:recent];
            if (!full) break;
            [used addObject:full];
            [self noteUsed:full];
            pick[[NSString stringWithFormat:@"%@/%@", sid, did]] = full;
        }
    }
    if (pick.count == 0) return;

    // 只给「此刻正在显示这个新桌面」的屏换图，别的屏一概不动——
    // 新建桌面时如果你还停在原桌面，这时去换图会改到原桌面上（会看起来像两个桌面交换了壁纸）
    NSDictionary<NSString *, NSString *> *active = ActiveSpaceByDisplay();
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *byDisplay = [NSMutableDictionary dictionary];
    for (NSScreen *sc in [NSScreen screens]) {
        NSString *did = [self displayUUIDForScreen:sc];
        if (!did) continue;
        NSString *sid = active[did];
        if (!sid || ![fresh containsObject:sid]) continue;
        NSString *full = pick[[NSString stringWithFormat:@"%@/%@", sid, did]];
        if (!full) continue;
        [paths addObject:full];
        byDisplay[did] = full;
        NSDictionary *opts = @{
            NSWorkspaceDesktopImageScalingKey: @(NSImageScaleProportionallyUpOrDown),
            NSWorkspaceDesktopImageAllowClippingKey: @YES
        };
        NSError *e = nil;
        if (![[NSWorkspace sharedWorkspace] setDesktopImageURL:[NSURL fileURLWithPath:full]
                                                     forScreen:sc options:opts error:&e])
            NSLog(@"[wallpaper] fresh set failed: %@", e.localizedDescription);
    }

    // 把这些图写进新桌面的配置（即使那块屏现在不显示它，切过去也要是对的）
    NSDate *now = [NSDate date];
    NSMutableDictionary *intended = [self assignments];
    for (NSString *sid in fresh) {
        NSMutableDictionary *sp = spaces[sid];
        NSMutableDictionary *disp = sp[@"Displays"];
        NSString *def = nil;
        for (NSString *did in (disp ?: @{})) {
            NSString *full = pick[[NSString stringWithFormat:@"%@/%@", sid, did]];
            if (!full) continue;
            if (!def) def = full;
            if (PutInto(disp[did], [self choiceForPath:full template:tmpl], now))
                intended[[NSString stringWithFormat:@"%@/%@", sid, did]] = full;
        }
        if (def && PutInto(sp[@"Default"], [self choiceForPath:def template:tmpl], now))
            intended[[NSString stringWithFormat:@"%@/Default", sid]] = def;
    }
    if ([self saveStore:d]) {
        _intendedStorage = intended;
        [self saveAssignments:intended];
        NSLog(@"[wallpaper] new space(s) got %@ (painted %lu screen(s))",
              [pick.allValues valueForKey:@"lastPathComponent"], (unsigned long)paths.count);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self repairDistinctEntries]; });
}

// 系统会为每张壁纸渲染一份整屏 PNG 缓存（约 3–7 MB × 每块屏），换得越勤攒得越多。
// 这些只是渲染缓存，删掉不影响当前壁纸，只是下次用到时要重新渲染。
- (void)trimWallpaperCache {
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *subs = [fm contentsOfDirectoryAtPath:base error:NULL];
    // 每个桌面每块屏各一张图，但每张只占 3–7 MB；留 10 个够回切几轮，磁盘稳定在 70 MB 上下
    const NSUInteger keep = 10;
    for (NSString *sub in subs) {
        if (![sub hasPrefix:@"extension-com.apple.wallpaper.extension.image"]) continue;
        NSString *dir = [base stringByAppendingPathComponent:sub];
        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:NULL];
        if (files.count <= keep) continue;
        NSMutableArray<NSDictionary *> *info = [NSMutableArray array];
        for (NSString *f in files) {
            NSString *fp = [dir stringByAppendingPathComponent:f];
            NSDictionary *attr = [fm attributesOfItemAtPath:fp error:NULL];
            if (attr) [info addObject:@{@"path": fp,
                                        @"date": attr[NSFileModificationDate] ?: [NSDate distantPast]}];
        }
        [info sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [(NSDate *)b[@"date"] compare:(NSDate *)a[@"date"]];
        }];
        NSUInteger removed = 0;
        for (NSUInteger i = keep; i < info.count; i++) {
            if ([fm removeItemAtPath:info[i][@"path"] error:NULL]) removed++;
        }
        if (removed) NSLog(@"[wallpaper] trimmed %lu old cache files", (unsigned long)removed);
    }
}

- (void)retryDistinctWithAttempt:(NSInteger)attempt {
    if (attempt >= 4) { NSLog(@"[wallpaper] gave up distinct retry"); return; }
    NSTimeInterval delay = attempt == 0 ? 3.0 : 5.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self applyDistinctImagesToSpaces] > 0) {
            [self restartWallpaperAgent];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self repairDistinctEntries]; });
        } else {
            [self retryDistinctWithAttempt:attempt + 1];
        }
    });
}

- (void)rotate:(id)sender {
    NSArray<NSString *> *imgs = [self images];
    if (imgs.count == 0) { NSBeep(); return; }
    // 手动点「立即换一张」时把倒计时重新开始算，免得刚点完 10 秒后定时器又换一次
    if (sender != nil) [self restartTimer];  // 定时器触发时 sender 为 nil，不会自我重置

    // 从这一刻起到记账落盘为止，禁止 syncActiveScreens 插手：它读的是换图前的旧记录，
    // 会在 1.5 秒的窗口里把刚换好的屏改回上一张。
    _suppressSyncUntil = [NSDate timeIntervalSinceReferenceDate] + 4.0;
    [_pendingSync removeAllObjects];

    // 1) 当前桌面的每块屏各挑一张「最近没用过」的图，用系统 API 直接换。
    //    不重启壁纸服务 → 不黑屏；每块屏一次调用内换完 → 不会出现「先变一样」。
    NSMutableSet<NSString *> *used = [NSMutableSet set];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *byDisplay = [NSMutableDictionary dictionary];
    NSArray<NSScreen *> *screens = [NSScreen screens];
    for (NSUInteger i = 0; i < screens.count; i++) {
        NSString *full = [self pickImageAvoiding:used recent:[self recentImages]];
        if (!full) break;
        [used addObject:full];
        [paths addObject:full];
        NSString *uuid = [self displayUUIDForScreen:screens[i]];
        if (uuid) byDisplay[uuid] = full;
        [self noteUsed:full];
    }
    if (paths.count == 0) { NSBeep(); return; }
    [self setDesktopImagesForScreens:paths];
    NSString *full = paths.firstObject;
    [[NSUserDefaults standardUserDefaults] setObject:full forKey:kLast];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // 2) 立刻把「当前桌面 = 屏幕上这几张」写进配置。
    //    这里必须同步写完：壁纸服务会在下一帧按配置文件重画当前桌面，
    //    如果配置还是上一张图，屏幕上就会先被改回去、再由后面的对齐改回来 ——
    //    也就是看到的「连换两张」。以前靠「拿屏幕上的图去猜当前桌面」，
    //    所以不得不等 1.5 秒；现在改用 SkyLight 直接问，可以当场写完。
    __weak typeof(self) weakSelf = self;
    NSSet<NSString *> *curSids = [self activeSpaceIDs];
    if (curSids.count > 0) {
        NSUInteger n = [self assignDistinctForOtherSpaces:byDisplay skipSids:curSids defaultPath:paths.firstObject];
        _suppressSyncUntil = 0;
        [_pendingSync removeAllObjects];
        NSLog(@"[wallpaper] rotated (%lu entries, no restart, current=%@)",
              (unsigned long)n, [[curSids allObjects] componentsJoinedByString:@","]);
    } else {
        // 拿不到活跃桌面时才退回「等 1.5 秒再用图比对」的老办法
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf assignOtherSpacesAfterSet:byDisplay defaultPath:paths.firstObject]; });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf trimWallpaperCache]; });
}

- (void)assignOtherSpacesAfterSet:(NSDictionary<NSString *, NSString *> *)byDisplay defaultPath:(NSString *)defaultPath {
    // 账已经按屏幕实际显示的内容记好了，从这里起允许 syncActiveScreens 再对齐。
    _suppressSyncUntil = 0;
    [_pendingSync removeAllObjects];
    NSSet<NSString *> *curSids = [self currentSpaceIDsMatching:[NSSet setWithArray:[byDisplay allValues]]];
    NSUInteger n = [self assignDistinctForOtherSpaces:byDisplay skipSids:curSids defaultPath:defaultPath];
    if (n == 0) {
        // 配置里暂时拿不到桌面列表（比如刚从办公默认切回来）：走老办法重建
        NSString *full = [[NSUserDefaults standardUserDefaults] stringForKey:kLast];
        [self applyUniformImage:full];
        [self restartWallpaperAgent];
        [self retryDistinctWithAttempt:0];
        NSLog(@"[wallpaper] rotated (fallback, restart)");
    } else {
        NSLog(@"[wallpaper] rotated (%lu entries, no restart, current=%@)", (unsigned long)n, [[curSids allObjects] componentsJoinedByString:@","] ?: @"(unknown)");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self repairDistinctEntries]; });
    }
}

- (void)togglePause:(id)sender {
    if ([self isPaused]) {
        [self setPaused:NO];
        [self rotate:nil];
    } else {
        [self setPaused:YES];
        [self applyOfficeDefaultQuietly];
    }
}

- (NSString *)supportDir {
    NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/wallpaper-rotate"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
- (NSString *)storePlistPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/com.apple.wallpaper/Store/Index.plist"];
}

// 存"办公默认"：记下当前系统墙纸配置
- (void)saveOfficeDefault:(id)sender {
    NSString *src = [self storePlistPath];
    NSString *dst = [[self supportDir] stringByAppendingPathComponent:@"office.plist"];
    NSError *e = nil;
    if ([[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&e]) {
        NSBeep();
        NSAlert *a = [NSAlert new];
        a.messageText = @"已设为办公默认壁纸";
        a.informativeText = @"以后点「切回办公默认」就会恢复成现在这个样式。";
        [a runModal];
    } else {
        NSLog(@"[wallpaper] save default failed: %@", e);
    }
}

// 还原办公默认配置（不改变暂停状态）
- (BOOL)applyOfficeDefaultQuietly {
    NSString *src = [[self supportDir] stringByAppendingPathComponent:@"office.plist"];
    NSString *dst = [self storePlistPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:src]) return NO;
    NSError *e = nil;
    [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
    if (![[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&e]) {
        NSLog(@"[wallpaper] restore failed: %@", e);
        return NO;
    }
    [self restartWallpaperAgent];
    NSLog(@"[wallpaper] office default applied");
    return YES;
}

// 菜单项：显式切回桌面默认（若还没存过快照就提示）
- (void)restoreOfficeDefault:(id)sender {
    if (![self applyOfficeDefaultQuietly]) {
        NSBeep();
        NSAlert *a = [NSAlert new];
        a.messageText = @"还没有保存办公默认壁纸";
        a.informativeText = @"先把系统壁纸调成你想要的样子，再点「把当前壁纸设为办公默认」。";
        [a runModal];
        return;
    }
    [self setPaused:YES];
}

- (void)openWallpaperSettings:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"]];
}

// 让用户自己挑图库目录（记在 defaults 里，重装不丢）。
- (void)chooseGallery:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = [NSURL fileURLWithPath:self.gallery];
    panel.prompt = @"选用这个文件夹";
    panel.message = @"选择放壁纸图片的文件夹（会递归找 jpg / png / heic / webp / tiff）";
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSString *dir = panel.URL.path;
    [[NSUserDefaults standardUserDefaults] setObject:dir forKey:kGallery];
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.gallery = dir;
    NSLog(@"[wallpaper] gallery -> %@ (%lu images)", dir, (unsigned long)[self images].count);
    [self restartTimer];
}

- (void)openGallery:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:self.gallery]];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    BOOL paused = [self isPaused];
    NSUInteger count = [self images].count;

    NSMenuItem *r = [[NSMenuItem alloc] initWithTitle:@"立即换一张" action:@selector(rotate:) keyEquivalent:@""];
    r.target = self;
    [menu addItem:r];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *p = [[NSMenuItem alloc] initWithTitle:(paused ? @"恢复自动轮换" : @"暂停（切回办公默认壁纸）")
                                               action:@selector(togglePause:) keyEquivalent:@""];
    p.target = self;
    p.state = paused ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:p];

    [menu addItem:[NSMenuItem separatorItem]];


    NSMenuItem *saveDef = [[NSMenuItem alloc] initWithTitle:@"把当前壁纸设为办公默认" action:@selector(saveOfficeDefault:) keyEquivalent:@""];
    saveDef.target = self;
    [menu addItem:saveDef];

    NSMenuItem *restoreDef = [[NSMenuItem alloc] initWithTitle:@"切回办公默认壁纸（并暂停）" action:@selector(restoreOfficeDefault:) keyEquivalent:@""];
    restoreDef.target = self;
    [menu addItem:restoreDef];

    [menu addItem:[NSMenuItem separatorItem]];
    // 换图间隔
    NSMenuItem *iv = [[NSMenuItem alloc] initWithTitle:@"换图间隔" action:nil keyEquivalent:@""];
    NSMenu *ivSub = [[NSMenu alloc] initWithTitle:@"换图间隔"];
    NSArray *mins = @[@5, @10, @15, @30, @60, @120, @240];
    NSTimeInterval cur = [self interval];
    for (NSNumber *m in mins) {
        NSTimeInterval secs = m.doubleValue * 60.0;
        NSString *title = (m.doubleValue < 60)
            ? [NSString stringWithFormat:@"每 %@ 分钟", m]
            : [NSString stringWithFormat:@"每 %g 小时", m.doubleValue / 60.0];
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:@selector(setIntervalMinutes:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = @(secs);
        it.state = (fabs(cur - secs) < 1.0) ? NSControlStateValueOn : NSControlStateValueOff;
        [ivSub addItem:it];
    }
    iv.submenu = ivSub;
    [menu addItem:iv];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *cg = [[NSMenuItem alloc] initWithTitle:@"选择图库文件夹…" action:@selector(chooseGallery:) keyEquivalent:@""];
    cg.target = self;
    [menu addItem:cg];

    NSMenuItem *o = [[NSMenuItem alloc] initWithTitle:@"打开图库文件夹…" action:@selector(openGallery:) keyEquivalent:@""];
    o.target = self;
    [menu addItem:o];

    NSMenuItem *ws = [[NSMenuItem alloc] initWithTitle:@"打开墙纸设置…" action:@selector(openWallpaperSettings:) keyEquivalent:@""];
    ws.target = self;
    [menu addItem:ws];

    NSString *statusText;
    if (count == 0) {
        statusText = [NSString stringWithFormat:@"⚠️ 图库里没有图片：%@", self.gallery.stringByAbbreviatingWithTildeInPath];
    } else if (paused) {
        statusText = [NSString stringWithFormat:@"已暂停（办公默认）· 图库 %lu 张", (unsigned long)count];
    } else {
        NSDate *fire = self.timer.fireDate;
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm";
        statusText = [NSString stringWithFormat:@"%lu 张 · 下次 %@", (unsigned long)count, [df stringFromDate:fire]];
    }
    NSMenuItem *st = [[NSMenuItem alloc] initWithTitle:statusText action:nil keyEquivalent:@""];
    st.enabled = NO;
    [menu addItem:st];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *q = [[NSMenuItem alloc] initWithTitle:@"退出壁纸轮换" action:@selector(terminate:) keyEquivalent:@""];
    q.target = NSApp;
    [menu addItem:q];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *d = [[AppDelegate alloc] init];
        app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
