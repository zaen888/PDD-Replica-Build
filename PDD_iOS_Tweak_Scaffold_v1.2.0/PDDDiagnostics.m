#import "PDDDiagnostics.h"
#import <unistd.h>

static dispatch_queue_t gDiagQueue;
static const unsigned long long kMaxFileBytes = 1024 * 1024;
static const NSUInteger kMaxFiles = 5;
static BOOL gDiagWriteFailed = NO;

static NSString *PDDDiagDirectory(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"PDDReplicaDiagnostics"];
}

static NSString *PDDDiagCurrentPath(void) {
    return [PDDDiagDirectory() stringByAppendingPathComponent:@"current.log"];
}

@implementation PDDDiagnostics
+ (instancetype)shared {
    static PDDDiagnostics *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PDDDiagnostics new]; });
    return s;
}

- (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gDiagQueue = dispatch_queue_create("com.local.pddreplica.diag", DISPATCH_QUEUE_SERIAL);
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:PDDDiagDirectory() withIntermediateDirectories:YES attributes:nil error:nil];
        [self log:@"=== PDDDiagnostics start pid=%d version=%@ ===",
              getpid(), [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?"];
    });
}

- (void)log:(NSString *)fmt, ... {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[PDDReplica] %@", msg);
    if (!gDiagQueue) return;
    NSString *line = [NSString stringWithFormat:@"%@ [%d] %@\n",
                      [NSDate date].description, getpid(), msg];
    dispatch_async(gDiagQueue, ^{ [self _appendLine:line]; });
}

- (void)event:(NSString *)name fields:(NSDictionary<NSString *, id> *)fields {
    NSMutableString *s = [NSMutableString stringWithFormat:@"EVENT %@", name];
    NSArray *keys = [fields.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *k in keys) {
        id v = fields[k];
        if ([k.lowercaseString containsString:@"token"]) v = @"<redacted>";
        [s appendFormat:@" %@=%@", k, v];
    }
    [self log:@"%@", s];
}

- (void)_appendLine:(NSString *)line {
    if (gDiagWriteFailed) return;
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *path = PDDDiagCurrentPath();
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        if ([attr[NSFileSize] unsignedLongLongValue] + line.length > kMaxFileBytes) {
            [self _rotate];
        }
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![fm fileExistsAtPath:path]) {
            if (![data writeToFile:path atomically:YES]) gDiagWriteFailed = YES;
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) { gDiagWriteFailed = YES; return; }
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    } @catch (NSException *e) {
        gDiagWriteFailed = YES;
        NSLog(@"[PDDReplica][DIAG] write failed: %@", e.reason);
    }
}

- (void)_rotate {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = PDDDiagDirectory();
    NSString *oldest = [dir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"current.%lu.log", (unsigned long)(kMaxFiles - 1)]];
    [fm removeItemAtPath:oldest error:nil];
    for (NSInteger i = kMaxFiles - 2; i >= 1; i--) {
        NSString *from = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"current.%ld.log", (long)i]];
        NSString *to = [dir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"current.%ld.log", (long)(i + 1)]];
        if ([fm fileExistsAtPath:from]) [fm moveItemAtPath:from toPath:to error:nil];
    }
    [fm moveItemAtPath:PDDDiagCurrentPath()
                toPath:[dir stringByAppendingPathComponent:@"current.1.log"]
                 error:nil];
}

- (void)flush {
    if (gDiagQueue) dispatch_sync(gDiagQueue, ^{});
}

- (NSURL *)exportLogURL {
    [self flush];
    NSString *path = PDDDiagCurrentPath();
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"PDDDiagnostics-%@.log", NSUUID.UUID.UUIDString]];
    NSError *e = nil;
    [[NSFileManager defaultManager] copyItemAtPath:path toPath:tmp error:&e];
    return e ? nil : [NSURL fileURLWithPath:tmp];
}

- (void)presentExportFromViewController:(UIViewController *)presenter sourceView:(UIView *)sourceView {
    NSURL *url = [self exportLogURL];
    if (!url) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"診斷日誌"
            message:@"目前沒有診斷日誌。" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:a animated:YES completion:nil];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                       applicationActivities:nil];
    if (share.popoverPresentationController) {
        share.popoverPresentationController.sourceView = sourceView ?: presenter.view;
        share.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds
            : CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
    }
    [presenter presentViewController:share animated:YES completion:nil];
}
@end
