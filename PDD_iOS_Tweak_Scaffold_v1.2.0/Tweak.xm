#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <zlib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "PDDDiagnostics.h"

static NSString * const kDataFolderName = @"PDDGoodsData";
static const NSInteger kFloatingButtonTag = 0x50444452;
static BOOL gEnabled = YES;
static BOOL gPresented = NO;
static NSString * const kEnabledDefaultsKey = @"PDDReplicaEnabled";
static NSString * const kCloudServerURLKey = @"PDDReplicaCloudServerURL";
static NSString * const kCloudDeviceIDKey = @"PDDReplicaCloudDeviceID";
static NSString * const kCloudDeviceTokenKey = @"PDDReplicaCloudDeviceToken";
static const NSTimeInterval kCloudPollInterval = 5.0;
static const NSTimeInterval kCloudHeartbeatInterval = 15.0;
static dispatch_queue_t gCaptureQueue;
static NSUInteger gCaptureCount = 0;
static NSString *gActiveTaskID = nil;
static NSString *gActiveKeyword = nil;
static NSUInteger gActiveTargetCount = 0;
static NSUInteger gActiveSavedCount = 0;
static BOOL gClaimInFlight = NO;
static BOOL gHeartbeatInFlight = NO;
static NSTimer *gCloudTimer = nil;
static NSTimeInterval gLastHeartbeat = 0;
static NSMutableSet<NSString *> *gUploadingPaths = nil;
static BOOL gUploadBusy = NO;
static NSString *gAutoSearchTaskID = nil;
static NSUInteger gAutoSearchAttempts = 0;
static BOOL gAutoSearchSubmitted = NO;
static NSInteger gAutoCollectState = 0;
static NSMutableSet<NSString *> *gAutoVisitedIndexPaths = nil;
static NSString *gAutoExpectedGoodsID = nil;
static NSUInteger gAutoScrollAttempts = 0;
static NSUInteger gAutoPhaseTicks = 0;
static BOOL gAutoTickScheduled = NO;
static BOOL gAutoTaskCompletedPendingReturn = NO;

static NSString *PDDDataDirectory(void);
static void PDDShowMessage(NSString *title, NSString *message);
static void PDDQueueCloudUpload(NSData *data, NSString *goodsID, NSDictionary *taskSnapshot);
static NSDictionary *PDDActiveTaskSnapshot(void);
static void PDDStartCloudWorker(void);
static void PDDShowControlMenu(UIButton *button);
static void PDDConfigureCloud(void);
static void PDDStartAutoSearchForTask(NSString *taskID, NSString *keyword);
static void PDDAutoCollectTick(void);
static void PDDAutoScheduleTick(NSTimeInterval delay);
static void PDDAutoUploadConfirmed(NSString *goodsID);

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
    NSDictionary *taskSnapshot = PDDActiveTaskSnapshot();
    if (taskSnapshot && gAutoCollectState != 2 && gAutoCollectState != 3 && gAutoCollectState != 7) taskSnapshot = nil;
    NSData *snapshot = [data copy];
    dispatch_async(gCaptureQueue, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *dir = PDDDataDirectory();
        NSError *error = nil;
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) return;
        NSString *path = [dir stringByAppendingPathComponent:[goodsID stringByAppendingPathExtension:@"txt"]];
        if (![snapshot writeToFile:path options:NSDataWritingAtomic error:&error]) return;
        @synchronized ([UIApplication class]) { gCaptureCount++; }
        PDDDiagEvent(@"capture.saved", @{@"goods_id": goodsID, @"bytes": @(snapshot.length)});
        PDDQueueCloudUpload(snapshot, goodsID, taskSnapshot);
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
            if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
                share.popoverPresentationController.sourceView = presenter.view;
                share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
            }
            [presenter presentViewController:share animated:YES completion:nil];
        });
    });
}

@interface PDDActionProxy : NSObject
+ (instancetype)shared;
- (void)toggle:(UIButton *)button;
- (void)drag:(UIPanGestureRecognizer *)gesture;
- (void)longPress:(UILongPressGestureRecognizer *)gesture;
- (void)cloudTick:(NSTimer *)timer;
@end

static NSString *PDDCloudSetting(NSString *key) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return [value isKindOfClass:NSString.class] ? [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
}

static NSString *PDDCloudServerURL(void) { return PDDCloudSetting(kCloudServerURLKey); }
static NSString *PDDCloudDeviceID(void) { return PDDCloudSetting(kCloudDeviceIDKey); }
static NSString *PDDCloudDeviceToken(void) { return PDDCloudSetting(kCloudDeviceTokenKey); }

static BOOL PDDCloudConfigured(void) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:PDDCloudServerURL()];
    return [[parts.scheme lowercaseString] isEqualToString:@"https"] && parts.host.length > 0 &&
        PDDCloudDeviceID().length >= 8 && PDDCloudDeviceToken().length >= 16;
}

static NSDictionary *PDDActiveTaskSnapshot(void) {
    @synchronized ([UIApplication class]) {
        if (!gActiveTaskID.length) return nil;
        return @{ @"task_id": gActiveTaskID, @"keyword": gActiveKeyword ?: @"",
                  @"target_count": @(gActiveTargetCount), @"saved_count": @(gActiveSavedCount) };
    }
}

static BOOL PDDStringLooksLikeSearch(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return NO;
    NSString *v = value.lowercaseString;
    return [v containsString:@"搜索"] || [v containsString:@"搜尋"] || [v containsString:@"search"];
}

static void PDDCollectSearchControls(UIView *view, NSMutableArray<UITextField *> *fields, NSMutableArray<UIButton *> *buttons) {
    if (!view || view.hidden || view.alpha < 0.05 || CGRectIsEmpty(view.bounds)) return;
    if ([view isKindOfClass:UISearchBar.class]) {
        UISearchBar *bar = (UISearchBar *)view;
        if (@available(iOS 13.0, *)) {
            UITextField *field = bar.searchTextField;
            if (field && ![fields containsObject:field]) [fields addObject:field];
        }
    }
    if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        BOOL identified = PDDStringLooksLikeSearch(field.placeholder) || PDDStringLooksLikeSearch(field.accessibilityLabel) || PDDStringLooksLikeSearch(field.accessibilityIdentifier);
        if ((identified || field.enabled) && ![fields containsObject:field]) [fields addObject:field];
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSString *title = [button titleForState:UIControlStateNormal];
        BOOL identified = PDDStringLooksLikeSearch(title) || PDDStringLooksLikeSearch(button.accessibilityLabel) || PDDStringLooksLikeSearch(button.accessibilityIdentifier);
        if (identified && ![buttons containsObject:button]) [buttons addObject:button];
    }
    for (UIView *child in view.subviews) PDDCollectSearchControls(child, fields, buttons);
}

static void PDDAutoSearchAttempt(NSString *taskID, NSString *keyword) {
    if (!PDDCaptureEnabled() || !taskID.length || !keyword.length) return;
    NSDictionary *active = PDDActiveTaskSnapshot();
    if (![active[@"task_id"] isEqualToString:taskID]) return;
    if (gAutoSearchSubmitted && [gAutoSearchTaskID isEqualToString:taskID]) return;

    UIWindow *window = PDDActiveWindow();
    if (!window) {
        if (++gAutoSearchAttempts <= 45) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                PDDAutoSearchAttempt(taskID, keyword);
            });
        }
        return;
    }

    NSMutableArray<UITextField *> *fields = [NSMutableArray array];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    PDDCollectSearchControls(window, fields, buttons);
    UITextField *target = nil;
    for (UITextField *candidate in fields) {
        if (PDDStringLooksLikeSearch(candidate.placeholder) || PDDStringLooksLikeSearch(candidate.accessibilityLabel) || PDDStringLooksLikeSearch(candidate.accessibilityIdentifier)) { target = candidate; break; }
    }
    if (!target && fields.count == 1) target = fields.firstObject;
    if (!target) {
        if (++gAutoSearchAttempts <= 180) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                PDDAutoSearchAttempt(taskID, keyword);
            });
            return;
        }
        UIPasteboard.generalPasteboard.string = keyword;
        return;
    }

    if (![target becomeFirstResponder] && !target.isFirstResponder) {
        UIPasteboard.generalPasteboard.string = keyword;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            PDDAutoSearchAttempt(taskID, keyword);
        });
        return;
    }

    target.text = @"";
    [target sendActionsForControlEvents:UIControlEventEditingChanged];
    
    UITextRange *range = [target textRangeFromPosition:target.beginningOfDocument toPosition:target.endOfDocument];
    [target replaceRange:range withText:keyword];
    [target sendActionsForControlEvents:UIControlEventEditingChanged];

    // 減少等待時間，防止被拼多多覆蓋
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSDictionary *latest = PDDActiveTaskSnapshot();
        if (![latest[@"task_id"] isEqualToString:taskID] || !target.window) return;
        
        NSString *actual = target.text ?: @"";
        if (![actual isEqualToString:keyword]) {
            PDDDiagEvent(@"search.verify_failed_fix", @{@"expected": keyword, @"actual": actual});
            target.text = keyword;
            [target sendActionsForControlEvents:UIControlEventEditingChanged];
        }
        
        // 立即提交
        UIButton *submit = buttons.firstObject;
        if (submit && submit.enabled) {
            [submit sendActionsForControlEvents:UIControlEventTouchUpInside];
        } else {
            [target sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        }
        
        gAutoSearchSubmitted = YES;
        gAutoCollectState = 1;
        gAutoPhaseTicks = 0;
        PDDDiagEvent(@"search.submitted", @{@"keyword": keyword});
        PDDAutoScheduleTick(1.0);
    });
}

static void PDDStartAutoSearchForTask(NSString *taskID, NSString *keyword) {
    if (!taskID.length || !keyword.length) return;
    gAutoSearchTaskID = [taskID copy];
    gAutoSearchAttempts = 0;
    gAutoSearchSubmitted = NO;
    gAutoTaskCompletedPendingReturn = NO;
    gAutoCollectState = 0;
    gAutoExpectedGoodsID = nil;
    gAutoScrollAttempts = 0;
    gAutoPhaseTicks = 0;
    gAutoVisitedIndexPaths = [NSMutableSet set];
    UIPasteboard.generalPasteboard.string = keyword;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PDDAutoSearchAttempt(taskID, keyword);
    });
}

static BOOL PDDSetActiveTask(NSDictionary *task, BOOL notify) {
    NSString *taskID = [task[@"task_id"] isKindOfClass:NSString.class] ? task[@"task_id"] : nil;
    NSString *keyword = [task[@"keyword"] isKindOfClass:NSString.class] ? task[@"keyword"] : @"";
    if (!taskID.length) return NO;
    BOOL isNew = NO;
    @synchronized ([UIApplication class]) {
        isNew = ![gActiveTaskID isEqualToString:taskID];
        gActiveTaskID = [taskID copy];
        gActiveKeyword = [keyword copy];
        gActiveTargetCount = [task[@"target_count"] respondsToSelector:@selector(unsignedIntegerValue)] ? [task[@"target_count"] unsignedIntegerValue] : 0;
        gActiveSavedCount = [task[@"saved_count"] respondsToSelector:@selector(unsignedIntegerValue)] ? [task[@"saved_count"] unsignedIntegerValue] : 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = PDDActiveWindow();
        UIButton *button = (UIButton *)[window viewWithTag:kFloatingButtonTag];
        if ([button isKindOfClass:UIButton.class]) {
            NSString *title = [NSString stringWithFormat:@"PDD · %lu/%lu", (unsigned long)gActiveSavedCount, (unsigned long)gActiveTargetCount];
            [button setTitle:title forState:UIControlStateNormal];
        }
        if (notify && isNew) {
            PDDStartAutoSearchForTask(taskID, keyword);
            PDDDiagEvent(@"task.received", @{@"task_id": taskID, @"keyword": keyword});
        }
    });
    return isNew;
}

static void PDDClearActiveTask(void) {
    PDDDiagEvent(@"task.clear", @{
        @"active_before": gActiveTaskID ?: @"",
        @"auto_state": @(gAutoCollectState),
        @"pending_return": @(gAutoTaskCompletedPendingReturn)
    });
    gAutoSearchTaskID = nil; gAutoSearchAttempts = 0; gAutoSearchSubmitted = NO;
    gAutoCollectState = 0; gAutoExpectedGoodsID = nil; gAutoScrollAttempts = 0; gAutoPhaseTicks = 0;
    gAutoTaskCompletedPendingReturn = NO;
    gAutoVisitedIndexPaths = [NSMutableSet set];
    @synchronized ([UIApplication class]) {
        gActiveTaskID = nil; gActiveKeyword = nil; gActiveTargetCount = 0; gActiveSavedCount = 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = PDDActiveWindow();
        UIButton *button = (UIButton *)[window viewWithTag:kFloatingButtonTag];
        if ([button isKindOfClass:UIButton.class]) [button setTitle:(gEnabled ? @"PDD · ON" : @"PDD · OFF") forState:UIControlStateNormal];
    });
}

static void PDDCloudRequest(NSString *path, NSDictionary *body, void (^completion)(NSDictionary *result, NSError *error, NSInteger statusCode)) {
    if (!PDDCloudConfigured()) {
        NSError *e = [NSError errorWithDomain:@"PDDLocalCollector" code:100 userInfo:@{NSLocalizedDescriptionKey:@"尚未設定本地伺服器或設備憑證。"}];
        if (completion) completion(nil, e, 0);
        return;
    }
    NSString *base = PDDCloudServerURL();
    NSURL *url = [NSURL URLWithString:[[base stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] stringByAppendingString:path]];
    if (!url) {
        NSError *e = [NSError errorWithDomain:@"PDDLocalCollector" code:101 userInfo:@{NSLocalizedDescriptionKey:@"本地伺服器 URL 無效。"}];
        if (completion) completion(nil, e, 0);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    request.HTTPMethod = @"POST";
    [request setValue:PDDCloudDeviceID() forHTTPHeaderField:@"X-Device-ID"];
    [request setValue:PDDCloudDeviceToken() forHTTPHeaderField:@"X-Device-Token"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:(body ?: @{}) options:0 error:&jsonError];
    if (!bodyData) { if (completion) completion(nil, jsonError, 0); return; }
    request.HTTPBody = bodyData;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        NSDictionary *json = nil;
        if (data.length) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
            if ([parsed isKindOfClass:NSDictionary.class]) json = parsed;
        }
        if (completion) completion(json, error, status);
    }];
    [task resume];
}

static NSString *PDDPendingUploadDirectory(void) {
    return [PDDDataDirectory() stringByAppendingPathComponent:@"PendingUploads"];
}

static NSString *PDDFailedUploadDirectory(void) {
    return [PDDDataDirectory() stringByAppendingPathComponent:@"FailedUploads"];
}

static BOOL PDDQuarantinePendingUpload(NSString *path, NSString *reason) {
    if (!path.length) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = PDDFailedUploadDirectory();
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    NSString *name = path.lastPathComponent ?: [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"json"];
    NSString *destination = [dir stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:destination]) {
        destination = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, name]];
    }
    NSError *moveError = nil;
    if ([fm moveItemAtPath:path toPath:destination error:&moveError]) {
        NSString *note = reason.length ? reason : @"上傳遭伺服器拒絕；原始佇列檔已保留在 FailedUploads。";
        [note writeToFile:[destination stringByAppendingString:@".reason.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        PDDDiagEvent(@"upload.quarantined", @{@"file": destination.lastPathComponent, @"reason": note});
        return YES;
    }
    return NO;
}

static void PDDHandleUploadSuccess(NSDictionary *envelope, NSDictionary *response) {
    NSString *taskID = envelope[@"task_id"];
    if (![taskID isKindOfClass:NSString.class]) return;
    BOOL matches = NO;
    @synchronized ([UIApplication class]) { matches = [gActiveTaskID isEqualToString:taskID]; }
    if (!matches) return;
    NSUInteger saved = [response[@"saved_count"] respondsToSelector:@selector(unsignedIntegerValue)] ? [response[@"saved_count"] unsignedIntegerValue] : 0;
    BOOL completed = [response[@"task_completed"] boolValue];
    @synchronized ([UIApplication class]) { gActiveSavedCount = saved; }
    NSString *uploadedGoodsID = [envelope[@"goods_id"] isKindOfClass:NSString.class] ? envelope[@"goods_id"] : nil;
    if (uploadedGoodsID.length) PDDAutoUploadConfirmed(uploadedGoodsID);
    if (completed) {
        gAutoTaskCompletedPendingReturn = YES;
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *window = PDDActiveWindow(); UIButton *button = (UIButton *)[window viewWithTag:kFloatingButtonTag];
            if ([button isKindOfClass:UIButton.class]) [button setTitle:[NSString stringWithFormat:@"PDD · %lu/%lu", (unsigned long)saved, (unsigned long)gActiveTargetCount] forState:UIControlStateNormal];
        });
    }
}

static void PDDFlushPendingUploads(void) {
    @synchronized ([UIApplication class]) { if (gUploadBusy) return; }
    NSString *dir = PDDPendingUploadDirectory();
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSArray *sorted = [files sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in sorted) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        @synchronized ([UIApplication class]) {
            if (gUploadBusy || [gUploadingPaths containsObject:path]) return;
            gUploadBusy = YES;
            [gUploadingPaths addObject:path];
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *fileData = [NSData dataWithContentsOfFile:path];
            NSDictionary *envelope = nil;
            if (fileData) {
                id parsed = [NSJSONSerialization JSONObjectWithData:fileData options:NSJSONReadingMutableContainers error:nil];
                if ([parsed isKindOfClass:NSDictionary.class]) envelope = parsed;
            }
            if (![envelope isKindOfClass:NSDictionary.class] || ![envelope[@"task_id"] isKindOfClass:NSString.class] ||
                ![envelope[@"goods_id"] isKindOfClass:NSString.class] || ![envelope[@"raw_json_base64"] isKindOfClass:NSString.class]) {
                PDDQuarantinePendingUpload(path, @"上傳佇列 JSON 格式錯誤；檔案已移至 FailedUploads。");
                @synchronized ([UIApplication class]) { gUploadBusy = NO; [gUploadingPaths removeObject:path]; }
                return;
            }
            PDDCloudRequest(@"/api/v1/device/captures", envelope, ^(NSDictionary *result, NSError *error, NSInteger statusCode) {
                BOOL success = !error && statusCode >= 200 && statusCode < 300 && [result[@"ok"] boolValue];
                BOOL completed = success && [result[@"task_completed"] boolValue];
                if (success) {
                    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                    PDDHandleUploadSuccess(envelope, result);
                } else {
                    BOOL retryable = (statusCode == 0 || statusCode >= 500 || statusCode == 408 || statusCode == 425 || statusCode == 429);
                    if (!retryable && statusCode >= 400 && statusCode < 500) {
                        NSString *detail = [result[@"detail"] isKindOfClass:NSString.class] ? result[@"detail"] : @"伺服器拒絕此上傳";
                        PDDQuarantinePendingUpload(path, [NSString stringWithFormat:@"HTTP %ld：%@", (long)statusCode, detail]);
                    }
                }
                @synchronized ([UIApplication class]) { gUploadBusy = NO; [gUploadingPaths removeObject:path]; }
                if (success && !completed) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ PDDFlushPendingUploads(); });
            });
        });
        return;
    }
}

static void PDDQueueCloudUpload(NSData *data, NSString *goodsID, NSDictionary *task) {
    if (!task || !data.length || !goodsID.length) return;
    dispatch_async(gCaptureQueue, ^{
        NSString *dir = PDDPendingUploadDirectory();
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *envelope = [NSMutableDictionary dictionary];
        envelope[@"task_id"] = task[@"task_id"];
        envelope[@"goods_id"] = goodsID;
        envelope[@"captured_at"] = [[NSDate date] description];
        envelope[@"source"] = @"NSJSONSerialization";
        envelope[@"raw_json_base64"] = [data base64EncodedStringWithOptions:0];
        NSData *json = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
        if (!json) return;
        NSString *filename = [NSString stringWithFormat:@"%@-%@.json", task[@"task_id"], NSUUID.UUID.UUIDString];
        NSString *path = [dir stringByAppendingPathComponent:filename];
        if (![json writeToFile:path options:NSDataWritingAtomic error:nil]) return;
        PDDFlushPendingUploads();
    });
}

static void PDDCloudTick(void) {
    if (!PDDCloudConfigured()) return;
    NSTimeInterval current = [NSDate date].timeIntervalSince1970;
    NSDictionary *active = PDDActiveTaskSnapshot();
    if (!gHeartbeatInFlight && (current - gLastHeartbeat >= kCloudHeartbeatInterval)) {
        gHeartbeatInFlight = YES;
        NSString *activeID = active[@"task_id"] ?: @"";
        NSDictionary *body = @{ @"app_version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
                                 @"plugin_version": @"1.2.4", @"app_active": @YES, @"active_task_id": activeID };
        PDDCloudRequest(@"/api/v1/device/heartbeat", body, ^(NSDictionary *result, NSError *error, NSInteger statusCode) {
            dispatch_async(dispatch_get_main_queue(), ^{
                gHeartbeatInFlight = NO;
                gLastHeartbeat = [NSDate date].timeIntervalSince1970;
            });
        });
    }
    if (PDDCaptureEnabled() && !gClaimInFlight) {
        gClaimInFlight = YES;
        PDDCloudRequest(@"/api/v1/device/tasks/claim", @{}, ^(NSDictionary *result, NSError *error, NSInteger statusCode) {
            dispatch_async(dispatch_get_main_queue(), ^{ gClaimInFlight = NO; });
            if (error || statusCode < 200 || statusCode >= 300) return;
            
            PDDDiagEvent(@"claim.response", @{
                @"status": @(statusCode),
                @"paused": result[@"paused"] ?: @NO,
                @"has_task": @(result[@"task"] != nil),
                @"task_id": result[@"task"][@"task_id"] ?: @"",
                @"active_before": PDDActiveTaskSnapshot()[@"task_id"] ?: @""
            });
            if ([result[@"paused"] boolValue]) return;
            NSDictionary *task = [result[@"task"] isKindOfClass:NSDictionary.class] ? result[@"task"] : nil;
            if (task) {
                PDDSetActiveTask(task, YES);
            } else if (PDDActiveTaskSnapshot()) {
                if (gAutoCollectState == 0 || gAutoCollectState == 6) {
                    PDDClearActiveTask();
                } else {
                    PDDDiagEvent(@"claim.empty_ignored", @{
                        @"active": gActiveTaskID ?: @"",
                        @"auto_state": @(gAutoCollectState)
                    });
                }
            }
        });
    }
    PDDFlushPendingUploads();
}

static void PDDStartCloudWorker(void) {
    if (!PDDCloudConfigured()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gCloudTimer) { [gCloudTimer invalidate]; gCloudTimer = nil; }
        gCloudTimer = [NSTimer scheduledTimerWithTimeInterval:kCloudPollInterval target:[PDDActionProxy shared] selector:@selector(cloudTick:) userInfo:nil repeats:YES];
        PDDCloudTick();
    });
}

static void PDDToggle(UIButton *button) {
    @synchronized ([UIApplication class]) { gEnabled = !gEnabled; }
    [NSUserDefaults.standardUserDefaults setBool:gEnabled forKey:kEnabledDefaultsKey];
    NSDictionary *active = PDDActiveTaskSnapshot();
    NSString *state = active ? [NSString stringWithFormat:@"PDD · %lu/%lu", (unsigned long)gActiveSavedCount, (unsigned long)gActiveTargetCount] : (gEnabled ? @"PDD · ON" : @"PDD · OFF");
    [button setTitle:state forState:UIControlStateNormal];
    PDDShowMessage(@"PDD Replica", gEnabled ? @"商品 JSON 擷取已啟用。" : @"商品 JSON 擷取已停用；設備心跳仍會維持連線。" );
}

static void PDDConfigureCloud(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = PDDActiveWindow();
        UIViewController *presenter = window.rootViewController;
        if (!presenter) return;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"設定本地採集服務" message:@"請填入 Windows 本地伺服器 HTTPS 網址、設備 ID 與設備 Token。憑證只存在這台 iPhone 的拼多多 App 偏好設定，不會寫入 GitHub 源碼。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"https://192.168.x.x:8443";
            field.text = PDDCloudServerURL();
            field.keyboardType = UIKeyboardTypeURL;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"Device ID";
            field.text = PDDCloudDeviceID();
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"Device Token";
            field.text = PDDCloudDeviceToken();
            field.secureTextEntry = YES;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"儲存並連線" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSArray<UITextField *> *fields = alert.textFields;
            NSString *url = [fields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *deviceID = [fields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *token = [fields[2].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSURLComponents *parts = [NSURLComponents componentsWithString:url];
            if (![[parts.scheme lowercaseString] isEqualToString:@"https"] || parts.host.length == 0 || deviceID.length < 8 || token.length < 16) {
                PDDShowMessage(@"設定無效", @"請確認網址以 https:// 開頭，且設備 ID、Token 都完整。可從 Windows 專案中的 ios/PDDLocalConfig.h 查看。" );
                return;
            }
            [NSUserDefaults.standardUserDefaults setObject:[url stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] forKey:kCloudServerURLKey];
            [NSUserDefaults.standardUserDefaults setObject:deviceID forKey:kCloudDeviceIDKey];
            [NSUserDefaults.standardUserDefaults setObject:token forKey:kCloudDeviceTokenKey];
            PDDStartCloudWorker();
            PDDShowMessage(@"設定已儲存", @"本地服務設定已儲存。插件會開始發送心跳並領取任務；請在 Windows 管理頁建立任務。" );
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

__attribute__((unused)) static BOOL PDDClassImplementsSelector(id object, SEL selector) {
    if (!object || !selector) return NO;
    return class_getInstanceMethod(object_getClass(object), selector) != NULL ||
           class_getInstanceMethod([object class], selector) != NULL;
}

__attribute__((unused)) static NSString *PDDGestureTargetSummary(UIGestureRecognizer *gesture) {
    NSMutableArray *parts = [NSMutableArray array];
    @try {
        id targets = [gesture valueForKey:@"_targets"];
        if ([targets isKindOfClass:NSArray.class]) {
            for (id entry in (NSArray *)targets) {
                id target = nil; SEL action = NULL;
                @try { target = [entry valueForKey:@"_target"]; } @catch (__unused NSException *e) {}
                @try {
                    id actionValue = [entry valueForKey:@"_action"];
                    if ([actionValue isKindOfClass:NSString.class]) action = NSSelectorFromString(actionValue);
                    else if (actionValue) action = NSSelectorFromString([actionValue description]);
                } @catch (__unused NSException *e) {}
                NSString *targetName = target ? NSStringFromClass([target class]) : @"nil";
                NSString *actionName = action ? NSStringFromSelector(action) : @"unknown";
                [parts addObject:[NSString stringWithFormat:@"%@/%@", targetName, actionName]];
            }
        }
    } @catch (__unused NSException *e) {}
    return parts.count ? [parts componentsJoinedByString:@","] : @"target/action unavailable";
}

static BOOL PDDFindTestCollection(UIView *view, UICollectionView **collectionOut, NSIndexPath **indexPathOut, NSString **reasonOut) {
    if (!view) return NO;
    if ([view isKindOfClass:UICollectionView.class]) {
        UICollectionView *cv = (UICollectionView *)view;
        id delegate = cv.delegate;
        NSString *delegateName = delegate ? NSStringFromClass([delegate class]) : @"nil";
        SEL selector = NSSelectorFromString(@"collectionView:didSelectItemAtIndexPath:");
        if ([delegateName containsString:@"PDDSearchResultPageContainerModule"] &&
            [delegate respondsToSelector:selector]) {
            NSArray<NSIndexPath *> *paths = [cv.indexPathsForVisibleItems sortedArrayUsingComparator:^NSComparisonResult(NSIndexPath *a, NSIndexPath *b) {
                if (a.section < b.section) return NSOrderedAscending;
                if (a.section > b.section) return NSOrderedDescending;
                if (a.item < b.item) return NSOrderedAscending;
                if (a.item > b.item) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            for (NSIndexPath *path in paths) {
                UICollectionViewCell *cell = [cv cellForItemAtIndexPath:path];
                NSString *cellName = cell ? NSStringFromClass(cell.class) : @"nil";
                if (cell && [cellName containsString:@"PDDSRDoubleColNormalGoodsCell"] && !cell.hidden && cell.alpha > 0.05) {
                    if (collectionOut) *collectionOut = cv;
                    if (indexPathOut) *indexPathOut = path;
                    if (reasonOut) *reasonOut = [NSString stringWithFormat:@"delegate=%@ cell=%@ indexPath=%@", delegateName, cellName, path];
                    return YES;
                }
            }
            if (reasonOut) *reasonOut = [NSString stringWithFormat:@"已找到列表 %@，但沒有可用的可見商品卡片。", delegateName];
        }
    }
    for (UIView *child in view.subviews) {
        if (PDDFindTestCollection(child, collectionOut, indexPathOut, reasonOut)) return YES;
    }
    return NO;
}

static BOOL PDDViewTreeContainsClass(UIView *view, NSString *needle) {
    if (!view || !needle.length || view.hidden || view.alpha < 0.05) return NO;
    if ([NSStringFromClass(view.class) containsString:needle]) return YES;
    for (UIView *child in view.subviews) if (PDDViewTreeContainsClass(child, needle)) return YES;
    return NO;
}

static UIButton *PDDFindDetailBackButton(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.05) return nil;
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        if (button.enabled) {
            NSArray<NSString *> *actions = [button actionsForTarget:nil forControlEvent:UIControlEventTouchUpInside];
            for (NSString *actionName in actions) {
                if ([actionName isEqualToString:@"backButtonPressed:"]) return button;
            }
            NSString *title = [button titleForState:UIControlStateNormal] ?: @"";
            NSString *label = button.accessibilityLabel ?: @"";
            NSString *identifier = button.accessibilityIdentifier ?: @"";
            BOOL backLike = [title containsString:@"返回"] || [title containsString:@"返回上一頁"] ||
                            [label containsString:@"返回"] || [label containsString:@"返回上一頁"] ||
                            [identifier.lowercaseString containsString:@"back"];
            if (backLike) return button;
        }
    }
    for (UIView *child in view.subviews) {
        UIButton *found = PDDFindDetailBackButton(child);
        if (found) return found;
    }
    return nil;
}

static UIViewController *PDDTopViewController(UIViewController *controller) {
    if (!controller) return nil;
    if (controller.presentedViewController) return PDDTopViewController(controller.presentedViewController);
    if ([controller isKindOfClass:UINavigationController.class])
        return PDDTopViewController(((UINavigationController *)controller).visibleViewController);
    if ([controller isKindOfClass:UITabBarController.class])
        return PDDTopViewController(((UITabBarController *)controller).selectedViewController);
    return controller;
}

static BOOL PDDTryReturnFromDetail(UIWindow *window) {
    if (!window) return NO;
    UIViewController *top = PDDTopViewController(window.rootViewController);
    UINavigationController *nav = top.navigationController;
    if (nav && nav.viewControllers.count > 1 && top == nav.topViewController) {
        [nav popViewControllerAnimated:YES];
        return YES;
    }
    UIButton *back = PDDFindDetailBackButton(top.view);
    if (!back) back = PDDFindDetailBackButton(window);
    if (back) {
        BOOL invoked = NO;
        for (id target in back.allTargets) {
            NSArray<NSString *> *actions = [back actionsForTarget:target forControlEvent:UIControlEventTouchUpInside] ?: @[];
            for (NSString *actionName in actions) {
                SEL action = NSSelectorFromString(actionName);
                if (![actionName isEqualToString:@"backButtonPressed:"] || ![target respondsToSelector:action]) continue;
                @try { ((void (*)(id, SEL, id))objc_msgSend)(target, action, back); invoked = YES; }
                @catch (NSException *exception) {}
                break;
            }
            if (invoked) break;
        }
        if (!invoked) [back sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    if (top.presentingViewController) {
        [top dismissViewControllerAnimated:YES completion:nil];
        return YES;
    }
    return NO;
}

static void PDDAutoScheduleTick(NSTimeInterval delay) {
    if (gAutoTickScheduled || gAutoCollectState == 0 || gAutoCollectState == 6) return;
    gAutoTickScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.2, delay) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gAutoTickScheduled = NO;
        PDDAutoCollectTick();
    });
}

static void PDDAutoPause(NSString *reason) {
    gAutoCollectState = 6;
    PDDDiagEvent(@"auto.paused", @{@"reason": reason ?: @"unknown"});
    PDDShowMessage(@"自動採集已暫停", reason ?: @"目前無法安全繼續。請檢查畫面後再處理。");
}

static void PDDAutoCollectTick(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ PDDAutoCollectTick(); }); return; }
    
    NSDictionary *active = PDDActiveTaskSnapshot();
    if (!active || !PDDCaptureEnabled()) {
        gAutoCollectState = 0; return;
    }
    
    if (![active[@"task_id"] isEqualToString:gAutoSearchTaskID]) {
        if (gAutoCollectState != 0) {
            PDDAutoScheduleTick(0.5);
        }
        return;
    }

    NSUInteger target = [active[@"target_count"] unsignedIntegerValue];
    NSUInteger saved = [active[@"saved_count"] unsignedIntegerValue];
    if (target < 1) target = 1;
    if (target > 3) target = 3;
    
    if (saved >= target && gAutoCollectState != 4) {
        if (gAutoCollectState != 3 && gAutoCollectState != 7) return;
    }
    
    UIWindow *window = PDDActiveWindow();
    if (!window) { PDDAutoPause(@"找不到拼多多活動視窗。"); return; }

    BOOL isDetail = PDDViewTreeContainsClass(window, @"PDDGoodsDetailContentView");
    UICollectionView *collection = nil; NSIndexPath *indexPath = nil; NSString *reason = nil;
    BOOL isResults = PDDFindTestCollection(window, &collection, &indexPath, &reason);

    if (gAutoCollectState == 1) {
        if (isDetail) { PDDAutoPause(@"搜尋後意外進入商品詳情頁，為避免誤採集已停止。"); return; }
        if (!isResults) {
            if (++gAutoPhaseTicks > 45) { PDDAutoPause(@"等待搜尋結果超過 45 秒。請確認關鍵詞已成功搜尋，再重新領取任務。"); return; }
            PDDAutoScheduleTick(1.0); return;
        }
        gAutoPhaseTicks = 0;
        gAutoCollectState = 2;
    }

    if (gAutoCollectState == 2) {
        if (isDetail) {
            gAutoCollectState = 3; gAutoPhaseTicks = 0;
            if (gAutoExpectedGoodsID.length) { PDDAutoUploadConfirmed(gAutoExpectedGoodsID); return; }
            PDDAutoScheduleTick(0.8); return;
        }
        if (!isResults || !collection) {
            if (++gAutoPhaseTicks > 30) { PDDAutoPause(@"無法確認搜尋結果列表仍在畫面上。"); return; }
            PDDAutoScheduleTick(0.8); return;
        }
        NSArray<NSIndexPath *> *paths = [collection.indexPathsForVisibleItems sortedArrayUsingComparator:^NSComparisonResult(NSIndexPath *a, NSIndexPath *b) {
            if (a.section != b.section) return a.section < b.section ? NSOrderedAscending : NSOrderedDescending;
            if (a.item != b.item) return a.item < b.item ? NSOrderedAscending : NSOrderedDescending;
            return NSOrderedSame;
        }];
        NSIndexPath *chosen = nil;
        for (NSIndexPath *path in paths) {
            UICollectionViewCell *cell = [collection cellForItemAtIndexPath:path];
            if (!cell || ![NSStringFromClass(cell.class) containsString:@"PDDSRDoubleColNormalGoodsCell"]) continue;
            NSString *key = [NSString stringWithFormat:@"%ld-%ld", (long)path.section, (long)path.item];
            if (![gAutoVisitedIndexPaths containsObject:key]) { chosen = path; break; }
        }
        if (!chosen) {
            if (gAutoScrollAttempts >= 8) { PDDAutoPause(@"目前可見商品已處理，但向下翻頁 8 次仍未找到新商品；請確認列表是否載入更多商品。"); return; }
            gAutoScrollAttempts++;
            CGPoint offset = collection.contentOffset;
            CGFloat nextY = MIN(MAX(0, collection.contentSize.height - collection.bounds.size.height), offset.y + collection.bounds.size.height * 0.72);
            if (nextY <= offset.y + 2) { PDDAutoPause(@"搜尋結果已到列表底部，沒有更多可採集商品。"); return; }
            [collection setContentOffset:CGPointMake(offset.x, nextY) animated:YES];
            PDDAutoScheduleTick(1.0); return;
        }
        NSString *key = [NSString stringWithFormat:@"%ld-%ld", (long)chosen.section, (long)chosen.item];
        [gAutoVisitedIndexPaths addObject:key];
        id delegate = collection.delegate; SEL selector = NSSelectorFromString(@"collectionView:didSelectItemAtIndexPath:");
        if (!delegate || ![delegate respondsToSelector:selector]) { PDDAutoPause(@"商品列表點擊回呼不可用。"); return; }
        gAutoExpectedGoodsID = nil; gAutoPhaseTicks = 0; gAutoCollectState = 7;
        PDDDiagEvent(@"opening_product", @{@"indexPath": [chosen description]});
        @try { ((void (*)(id, SEL, UICollectionView *, NSIndexPath *))objc_msgSend)(delegate, selector, collection, chosen); }
        @catch (NSException *exception) { PDDAutoPause([NSString stringWithFormat:@"商品點擊回呼例外：%@", exception.reason ?: @"unknown"]); return; }
        PDDAutoScheduleTick(0.8); return;
    }

    if (gAutoCollectState == 7) {
        if (isDetail) {
            gAutoCollectState = 3; gAutoPhaseTicks = 0;
            if (gAutoExpectedGoodsID.length) { PDDAutoUploadConfirmed(gAutoExpectedGoodsID); return; }
            PDDAutoScheduleTick(0.8); return;
        }
        if (++gAutoPhaseTicks > 35) { PDDAutoPause(@"已觸發商品選取，但 35 秒內未確認進入商品詳情頁。"); return; }
        PDDAutoScheduleTick(0.8); return;
    }

    if (gAutoCollectState == 3) {
        if (!isDetail) { if (++gAutoPhaseTicks > 30) { PDDAutoPause(@"商品詳情頁未能穩定顯示。"); return; } PDDAutoScheduleTick(0.8); return; }
        if (gAutoExpectedGoodsID.length) { PDDAutoUploadConfirmed(gAutoExpectedGoodsID); return; }
        if (++gAutoPhaseTicks > 90) { PDDAutoPause(@"商品詳情頁已打開，但 90 秒內本地伺服器未確認 TXT 上傳。TXT 若已保存仍會保留在手機；請檢查網路與服務設定。"); return; }
        PDDAutoScheduleTick(1.0); return;
    }

    if (gAutoCollectState == 4) {
        if (isResults && !isDetail) {
            if (gAutoTaskCompletedPendingReturn || saved >= target) {
                NSString *finishedKeyword = [active[@"keyword"] isKindOfClass:NSString.class] ? active[@"keyword"] : @"";
                NSUInteger finishedCount = saved;
                PDDDiagEvent(@"task.complete", @{@"keyword": finishedKeyword, @"uploaded": @(finishedCount)});
                PDDClearActiveTask();
                return;
            }
            gAutoCollectState = 5; gAutoPhaseTicks = 0;
            PDDAutoScheduleTick(3.0); return;
        }
        if (++gAutoPhaseTicks > 30) { PDDAutoPause(@"已觸發詳情頁返回，但未能確認回到搜尋結果頁。"); return; }
        PDDAutoScheduleTick(0.8); return;
    }
    if (gAutoCollectState == 5) {
        gAutoCollectState = 2; gAutoPhaseTicks = 0;
        PDDAutoScheduleTick(0.2); return;
    }
}

static void PDDAutoUploadConfirmed(NSString *goodsID) {
    if (!goodsID.length || (gAutoCollectState != 7 && gAutoCollectState != 3)) return;
    if (gAutoExpectedGoodsID.length && ![gAutoExpectedGoodsID isEqualToString:goodsID]) return;
    gAutoExpectedGoodsID = [goodsID copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gAutoCollectState != 7 && gAutoCollectState != 3) return;
        UIWindow *window = PDDActiveWindow();
        if (!window || !PDDViewTreeContainsClass(window, @"PDDGoodsDetailContentView")) {
            PDDAutoScheduleTick(0.8);
            return;
        }
        if (PDDTryReturnFromDetail(window)) {
            gAutoCollectState = 4;
            gAutoPhaseTicks = 0;
            PDDAutoScheduleTick(0.8);
            return;
        }
        gAutoCollectState = 3;
        if (++gAutoPhaseTicks > 30) {
            PDDAutoPause(@"商品已上傳，但目前詳情頁沒有可用的返回按鈕或導覽堆疊。請複製介面診斷以確認實際頁面結構。");
            return;
        }
        PDDAutoScheduleTick(0.8);
    });
}

static void PDDStartAutoCollectCurrentResults(void) {
    NSDictionary *active = PDDActiveTaskSnapshot();
    if (!active || ![active[@"task_id"] isKindOfClass:NSString.class]) {
        PDDShowMessage(@"尚無採集任務", @"請先在 Windows 管理頁建立任務，並等待 iPhone 領取。");
        return;
    }
    if (!PDDCaptureEnabled()) {
        PDDShowMessage(@"JSON 擷取目前已暫停", @"請先啟用 JSON 擷取，再開始自動採集。");
        return;
    }
    gAutoSearchTaskID = [active[@"task_id"] copy];
    gAutoCollectState = 1;
    gAutoExpectedGoodsID = nil;
    gAutoScrollAttempts = 0;
    gAutoPhaseTicks = 0;
    gAutoVisitedIndexPaths = [NSMutableSet set];
    PDDShowMessage(@"開始辨識目前搜尋結果", @"請確認拼多多目前已顯示該任務關鍵詞的搜尋結果。插件會先確認商品列表，再逐件採集。");
    PDDAutoScheduleTick(0.5);
}

static void PDDTestOpenFirstVisibleProduct(void) {
    void (^runTest)(void) = ^{
        UIWindow *window = PDDActiveWindow();
        if (!window) {
            PDDShowMessage(@"商品點擊測試", @"找不到活動視窗。請先回到拼多多搜尋結果頁。");
            return;
        }
        UICollectionView *collection = nil;
        NSIndexPath *indexPath = nil;
        NSString *reason = nil;
        if (!PDDFindTestCollection(window, &collection, &indexPath, &reason)) {
            PDDShowMessage(@"商品點擊測試未執行", reason ?: @"找不到符合條件的搜尋商品列表。請確認目前停留在搜尋結果頁。");
            return;
        }
        id delegate = collection.delegate;
        SEL selector = NSSelectorFromString(@"collectionView:didSelectItemAtIndexPath:");
        @try {
            ((void (*)(id, SEL, UICollectionView *, NSIndexPath *))objc_msgSend)(delegate, selector, collection, indexPath);
        } @catch (NSException *exception) {
            PDDShowMessage(@"商品點擊回呼發生例外", exception.reason ?: @"未知錯誤");
        }
    };
    if (NSThread.isMainThread) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), runTest);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), runTest);
        });
    }
}

static void PDDCopyInterfaceDiagnostics(void) {
    UIWindow *window = PDDActiveWindow();
    if (!window) { PDDShowMessage(@"介面診斷", @"目前找不到活動視窗。請回到拼多多前景後再試。"); return; }
    NSMutableString *report = [NSMutableString stringWithString:@"PDD ReplicaShell interface diagnostics 1.2.4\nREAD_ONLY=YES\n"];
    NSUInteger count = 0;
    [report appendFormat:@"\nVIEW_COUNT=%lu\n", (unsigned long)count];
    UIPasteboard.generalPasteboard.string = report;
    PDDShowMessage(@"點擊路徑診斷已複製", [NSString stringWithFormat:@"已複製點擊路徑資訊（掃描 %@ 個視圖）。不會執行任何點擊。", @(count)]);
}

static void PDDShowControlMenu(UIButton *button) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = PDDActiveWindow();
        UIViewController *presenter = window.rootViewController;
        if (!presenter) return;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        NSString *captureState = gEnabled ? @"暫停 JSON 擷取" : @"啟用 JSON 擷取";
        UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"PDD Local Collector" message:(PDDCloudConfigured() ? @"本地服務已設定" : @"尚未設定本地服務") preferredStyle:UIAlertControllerStyleActionSheet];
        [menu addAction:[UIAlertAction actionWithTitle:captureState style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { PDDToggle(button); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"設定本地服務" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { PDDConfigureCloud(); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"匯出 TXT ZIP" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { PDDShareTXTFiles(); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"開始自動採集目前搜尋結果" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { PDDStartAutoCollectCurrentResults(); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"測試打開第一個商品（單次）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { PDDTestOpenFirstVisibleProduct(); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"複製目前介面診斷" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { PDDCopyInterfaceDiagnostics(); }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"匯出診斷日誌" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIWindow *w = PDDActiveWindow();
                UIViewController *p = w.rootViewController;
                if (!p) return;
                while (p.presentedViewController) p = p.presentedViewController;
                [[PDDDiagnostics shared] presentExportFromViewController:p sourceView:button];
            });
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        if (menu.popoverPresentationController) {
            menu.popoverPresentationController.sourceView = button ?: presenter.view;
            menu.popoverPresentationController.sourceRect = button ? button.bounds : CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
        }
        [presenter presentViewController:menu animated:YES completion:nil];
    });
}

static void PDDLongPress(UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    PDDShareTXTFiles();
}

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
- (void)toggle:(UIButton *)button { PDDShowControlMenu(button); }
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
- (void)cloudTick:(NSTimer *)timer { PDDCloudTick(); }
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
        [[PDDDiagnostics shared] start];
        gEnabled = [NSUserDefaults.standardUserDefaults objectForKey:kEnabledDefaultsKey] ? [NSUserDefaults.standardUserDefaults boolForKey:kEnabledDefaultsKey] : YES;
        gCaptureQueue = dispatch_queue_create("com.local.pddreplica.capture", DISPATCH_QUEUE_SERIAL);
        gUploadingPaths = [NSMutableSet set];
        gAutoVisitedIndexPaths = [NSMutableSet set];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            PDDInstallFloatingButton();
            PDDStartCloudWorker();
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                gPresented = NO;
                PDDInstallFloatingButton();
                PDDStartCloudWorker();
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                if (gCloudTimer) { [gCloudTimer invalidate]; gCloudTimer = nil; }
            }];
        });
    }
}
