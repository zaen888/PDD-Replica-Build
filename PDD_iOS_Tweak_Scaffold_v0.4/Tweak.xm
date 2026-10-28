#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <zlib.h>

static NSString * const kDataFolderName = @"PDDGoodsData";
static const NSInteger kFloatingButtonTag = 0x50444452;
static BOOL gEnabled = YES;
static BOOL gPresented = NO;
static NSString * const kEnabledDefaultsKey = @"PDDReplicaEnabled";
static dispatch_queue_t gCaptureQueue;
static NSUInteger gCaptureCount = 0;

static NSString *PDDDataDirectory(void);

static BOOL PDDCaptureEnabled(void) {
    @synchronized ([UIApplication class]) { return gEnabled; }
}

static NSString *PDDSafeGoodsID(id value) {
    if (![value isKindOfClass:NSString.class] && ![value respondsToSelector:@selector(stringValue)]) return nil;
    NSString *raw = [value isKindOfClass:NSString.class] ? (NSString *)value : [value stringValue];
    if (raw.length == 0 || raw.length > 100) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."];
    if ([raw rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound || [raw isEqualToString:@"."] || [raw isEqualToString:@".."]) return nil;
    return raw;
}

static BOOL PDDLooksLikeGoodsObject(id object, NSString **goodsIDOut) {
    if (![object isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *root = (NSDictionary *)object;
    NSDictionary *goods = [root[@"goods"] isKindOfClass:NSDictionary.class] ? root[@"goods"] : nil;
    NSArray *sku = [root[@"sku"] isKindOfClass:NSArray.class] ? root[@"sku"] : nil;
    NSDictionary *price = [root[@"price"] isKindOfClass:NSDictionary.class] ? root[@"price"] : nil;
    NSString *goodsID = PDDSafeGoodsID(goods[@"goods_id"]);
    if (!goods || !sku || !price || !goodsID) return NO;
    if (goodsIDOut) *goodsIDOut = goodsID;
    return YES;
}

static void PDDCaptureRawJSON(NSData *data, NSString *goodsID) {
    if (data.length == 0 || !goodsID.length) return;
    // Copy bytes before dispatch so concurrent parser calls cannot cross-pair data.
    NSData *snapshot = [data copy];
    dispatch_async(gCaptureQueue, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *dir = PDDDataDirectory();
        NSError *error = nil;
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"[PDDReplica] create directory failed: %@", error.localizedDescription);
            return;
        }
        NSString *path = [dir stringByAppendingPathComponent:[goodsID stringByAppendingPathExtension:@"txt"]];
        if (![snapshot writeToFile:path options:NSDataWritingAtomic error:&error]) {
            NSLog(@"[PDDReplica] write failed for %@: %@", goodsID, error.localizedDescription);
            return;
        }
        @synchronized ([UIApplication class]) { gCaptureCount++; }
        NSLog(@"[PDDReplica] saved product JSON id=%@ bytes=%lu", goodsID, (unsigned long)snapshot.length);
    });
}

static UIWindow *PDDActiveWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) return window;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

static NSString *PDDDataDirectory(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:kDataFolderName];
}

static NSArray<NSURL *> *PDDTXTFiles(void) {
    NSString *path = PDDDataDirectory();
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) return @[];
    NSDirectoryEnumerator<NSURL *> *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:path isDirectory:YES]
                                         includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                                       errorHandler:nil];
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (NSURL *url in enumerator) {
        if ([[url.pathExtension lowercaseString] isEqualToString:@"txt"]) {
            NSNumber *isRegular = nil;
            [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
            if (isRegular.boolValue) [files addObject:url];
        }
    }
    return files;
}

static void PDDShowMessage(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = PDDActiveWindow();
        UIViewController *presenter = window.rootViewController;
        if (!presenter) return;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static void PDDAppendLE16(NSMutableData *data, uint16_t value) {
    uint8_t b[2] = { (uint8_t)(value & 0xff), (uint8_t)((value >> 8) & 0xff) };
    [data appendBytes:b length:sizeof(b)];
}

static void PDDAppendLE32(NSMutableData *data, uint32_t value) {
    uint8_t b[4] = { (uint8_t)(value & 0xff), (uint8_t)((value >> 8) & 0xff), (uint8_t)((value >> 16) & 0xff), (uint8_t)((value >> 24) & 0xff) };
    [data appendBytes:b length:sizeof(b)];
}

// Minimal ZIP writer using STORE (no compression), compatible with standard ZIP readers.
static NSURL *PDDCreateZIP(NSArray<NSURL *> *files, NSError **outError) {
    NSMutableData *zip = [NSMutableData data];
    NSMutableArray<NSDictionary *> *central = [NSMutableArray array];
    for (NSURL *url in files) {
        NSError *readError = nil;
        NSData *payload = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
        if (!payload) { if (outError) *outError = readError; return nil; }
        NSString *name = url.lastPathComponent ?: @"item.txt";
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        if (nameData.length == 0 || nameData.length > UINT16_MAX || payload.length > UINT32_MAX || zip.length > UINT32_MAX) {
            if (outError) *outError = [NSError errorWithDomain:@"PDDReplicaZIP" code:1 userInfo:@{NSLocalizedDescriptionKey:@"檔名或檔案大小超出 ZIP Store 支援範圍。"}];
            return nil;
        }
        // ZIP names are flattened like the original export; reject collisions rather than silently duplicate entries.
        for (NSDictionary *entry in central) {
            if ([entry[@"name"] isEqualToString:name]) {
                if (outError) *outError = [NSError errorWithDomain:@"PDDReplicaZIP" code:2 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"發現重複檔名：%@。請先整理檔案。", name]}];
                return nil;
            }
        }
        uint32_t crc = (uint32_t)crc32(0L, Z_NULL, 0);
        const Bytef *bytes = (const Bytef *)payload.bytes;
        uInt remaining = (uInt)MIN(payload.length, (NSUInteger)UINT_MAX);
        crc = (uint32_t)crc32(crc, bytes, remaining);
        uint32_t localOffset = (uint32_t)zip.length;
        PDDAppendLE32(zip, 0x04034b50); PDDAppendLE16(zip, 20); PDDAppendLE16(zip, 0x0800);
        PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0);
        PDDAppendLE32(zip, crc); PDDAppendLE32(zip, (uint32_t)payload.length); PDDAppendLE32(zip, (uint32_t)payload.length);
        PDDAppendLE16(zip, (uint16_t)nameData.length); PDDAppendLE16(zip, 0);
        [zip appendData:nameData]; [zip appendData:payload];
        [central addObject:@{@"name":name, @"nameData":nameData, @"crc":@(crc), @"size":@((uint32_t)payload.length), @"offset":@(localOffset)}];
    }
    if (central.count > UINT16_MAX || zip.length > UINT32_MAX) {
        if (outError) *outError = [NSError errorWithDomain:@"PDDReplicaZIP" code:3 userInfo:@{NSLocalizedDescriptionKey:@"檔案數量或 ZIP 大小超出支援範圍。"}];
        return nil;
    }
    uint32_t centralOffset = (uint32_t)zip.length;
    for (NSDictionary *entry in central) {
        NSData *nameData = entry[@"nameData"];
        PDDAppendLE32(zip, 0x02014b50); PDDAppendLE16(zip, 20); PDDAppendLE16(zip, 20);
        PDDAppendLE16(zip, 0x0800); PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0);
        PDDAppendLE32(zip, [entry[@"crc"] unsignedIntValue]);
        PDDAppendLE32(zip, [entry[@"size"] unsignedIntValue]); PDDAppendLE32(zip, [entry[@"size"] unsignedIntValue]);
        PDDAppendLE16(zip, (uint16_t)nameData.length); PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0);
        PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0); PDDAppendLE32(zip, 0);
        PDDAppendLE32(zip, [entry[@"offset"] unsignedIntValue]); [zip appendData:nameData];
    }
    uint32_t centralSize = (uint32_t)zip.length - centralOffset;
    PDDAppendLE32(zip, 0x06054b50); PDDAppendLE16(zip, 0); PDDAppendLE16(zip, 0);
    PDDAppendLE16(zip, (uint16_t)central.count); PDDAppendLE16(zip, (uint16_t)central.count);
    PDDAppendLE32(zip, centralSize); PDDAppendLE32(zip, centralOffset); PDDAppendLE16(zip, 0);

    NSString *tmp = NSTemporaryDirectory();
    NSString *uniqueName = [NSString stringWithFormat:@"PDDExport-%lu-%@.zip", (unsigned long)files.count, NSUUID.UUID.UUIDString];
    NSString *zipPath = [tmp stringByAppendingPathComponent:uniqueName];
    NSError *writeError = nil;
    if (![zip writeToFile:zipPath options:NSDataWritingAtomic error:&writeError]) { if (outError) *outError = writeError; return nil; }
    return [NSURL fileURLWithPath:zipPath];
}

static void PDDShareTXTFiles(void) {
    // File enumeration, reading, CRC calculation and ZIP construction run off the main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<NSURL *> *files = PDDTXTFiles();
        if (files.count == 0) {
            PDDShowMessage(@"PDD Replica", [NSString stringWithFormat:@"No TXT files found in:\n%@", PDDDataDirectory()]);
            return;
        }
        NSError *zipError = nil;
        NSURL *zipURL = PDDCreateZIP(files, &zipError);
        if (!zipURL) {
            PDDShowMessage(@"ZIP 匯出失敗", zipError.localizedDescription ?: @"無法建立 ZIP 檔案。");
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *window = PDDActiveWindow();
            UIViewController *presenter = window.rootViewController;
            if (!presenter) return;
            while (presenter.presentedViewController) presenter = presenter.presentedViewController;
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[zipURL] applicationActivities:nil];
            if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
                share.popoverPresentationController.sourceView = presenter.view;
                share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
            }
            [presenter presentViewController:share animated:YES completion:nil];
        });
    });
}

static void PDDToggle(UIButton *button) {
    @synchronized ([UIApplication class]) { gEnabled = !gEnabled; }
    [NSUserDefaults.standardUserDefaults setBool:gEnabled forKey:kEnabledDefaultsKey];
    NSString *state = gEnabled ? @"PDD · ON" : @"PDD · OFF";
    [button setTitle:state forState:UIControlStateNormal];
    PDDShowMessage(@"PDD Replica", gEnabled ? @"商品 JSON 擷取已啟用：只保存符合 goods/sku/price 結構的解析資料。" : @"商品 JSON 擷取已停用。");
}

static void PDDLongPress(UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    PDDShareTXTFiles();
}

@interface PDDActionProxy : NSObject
+ (instancetype)shared;
- (void)toggle:(UIButton *)button;
- (void)drag:(UIPanGestureRecognizer *)gesture;
- (void)longPress:(UILongPressGestureRecognizer *)gesture;
@end

static void PDDInstallFloatingButton(void) {
    if (gPresented) return;
    UIWindow *window = PDDActiveWindow();
    if (!window) return;
    UIView *existing = [window viewWithTag:kFloatingButtonTag];
    if (existing) { gPresented = YES; return; }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = kFloatingButtonTag;
    button.frame = CGRectMake(MAX(8.0, window.bounds.size.width - 92.0), window.safeAreaInsets.top + 180.0, 84.0, 44.0);
    button.backgroundColor = [UIColor colorWithRed:0.15 green:0.35 blue:0.85 alpha:0.92];
    [button setTitle:(gEnabled ? @"PDD · ON" : @"PDD · OFF") forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    button.layer.cornerRadius = 12.0;
    button.layer.shadowOpacity = 0.2;
    button.layer.shadowRadius = 4.0;
    [button addTarget:[PDDActionProxy shared] action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[PDDActionProxy shared] action:@selector(drag:)];
    pan.cancelsTouchesInView = NO;
    [button addGestureRecognizer:pan];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:[PDDActionProxy shared] action:@selector(longPress:)];
    longPress.minimumPressDuration = 0.7;
    longPress.cancelsTouchesInView = NO;
    [button addGestureRecognizer:longPress];
    [window addSubview:button];
    gPresented = YES;
}

@implementation PDDActionProxy
+ (instancetype)shared { static PDDActionProxy *p; static dispatch_once_t once; dispatch_once(&once, ^{ p = [PDDActionProxy new]; }); return p; }
- (void)toggle:(UIButton *)button { PDDToggle(button); }
- (void)drag:(UIPanGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    UIWindow *window = PDDActiveWindow();
    if (!view || !window) return;
    CGPoint delta = [gesture translationInView:window];
    CGPoint center = view.center;
    center.x += delta.x; center.y += delta.y;
    CGFloat halfW = CGRectGetWidth(view.bounds) / 2.0, halfH = CGRectGetHeight(view.bounds) / 2.0;
    center.x = MIN(MAX(halfW, center.x), CGRectGetWidth(window.bounds) - halfW);
    center.y = MIN(MAX(halfH, center.y), CGRectGetHeight(window.bounds) - halfH);
    view.center = center;
    [gesture setTranslation:CGPointZero inView:window];
}
- (void)longPress:(UILongPressGestureRecognizer *)gesture { PDDLongPress(gesture); }
@end

%hook NSJSONSerialization
+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id parsed = %orig;
    if (parsed && data.length > 0 && PDDCaptureEnabled()) {
        NSString *goodsID = nil;
        if (PDDLooksLikeGoodsObject(parsed, &goodsID)) {
            PDDCaptureRawJSON(data, goodsID);
        }
    }
    return parsed;
}
%end

%ctor {
    @autoreleasepool {
        gEnabled = [NSUserDefaults.standardUserDefaults objectForKey:kEnabledDefaultsKey] ? [NSUserDefaults.standardUserDefaults boolForKey:kEnabledDefaultsKey] : YES;
        gCaptureQueue = dispatch_queue_create("com.local.pddreplica.capture", DISPATCH_QUEUE_SERIAL);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            PDDInstallFloatingButton();
            // Re-check after app transitions; this is UI setup only, not a network hook.
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                gPresented = NO;
                PDDInstallFloatingButton();
            }];
        });
    }
}
