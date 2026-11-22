#import "diagnostics.h"
#import <AppKit/AppKit.h>
#import <fcntl.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <unistd.h>

static dispatch_queue_t logQueue;
static dispatch_semaphore_t logSlots;
static NSString *logDirectory;
static NSISO8601DateFormatter *logClock;
static id terminationObserver;
static atomic_bool enabled;
static atomic_uint dropped;
static const off_t maxLogBytes = 2 * 1024 * 1024;
static const unsigned maxArchives = 4;

static void prepareQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logQueue = dispatch_queue_create("local.bicord.diagnostics", DISPATCH_QUEUE_SERIAL);
        logSlots = dispatch_semaphore_create(128);
        logClock = [[NSISO8601DateFormatter alloc] init];
        logClock.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        atomic_init(&enabled, false);
        atomic_init(&dropped, 0);
    });
}

bool sy_log_init(const char *directory) {
    @autoreleasepool {
        prepareQueue();
        NSString *path = [NSString stringWithUTF8String:directory];
        if (!path.length) return false;
        atomic_store(&enabled, true);
        dispatch_async(logQueue, ^{
            NSError *error = nil;
            BOOL created = [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions: @0700} error:&error];
            logDirectory = created ? path : nil;
            if (!created) {
                atomic_store(&enabled, false);
                NSLog(@"Bicord diagnostics unavailable: %@", error);
            }
        });
        SYLog(@"info", @"diagnostics.ready", @{@"os": NSProcessInfo.processInfo.operatingSystemVersionString});
        static dispatch_once_t observeOnce;
        dispatch_once(&observeOnce, ^{
            terminationObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification
                object:nil queue:nil usingBlock:^(__unused NSNotification *notification) {
                    SYLog(@"info", @"application.terminating", @{}); sy_log_flush();
                }];
        });
        return true;
    }
}

NSDictionary *SYError(NSError *error) {
    if (!error) return @{};
    NSMutableDictionary *fields = [@{@"domain": error.domain, @"code": @(error.code),
        @"message": error.localizedDescription ?: @"Unknown error"} mutableCopy];
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:NSError.class] && underlying != error) {
        fields[@"underlying"] = @{@"domain": underlying.domain, @"code": @(underlying.code),
            @"message": underlying.localizedDescription ?: @"Unknown error"};
    }
    return fields;
}

static BOOL rotateLogs(NSString *path) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *oldest = [path stringByAppendingFormat:@".%u", maxArchives];
    if ([files fileExistsAtPath:oldest] && ![files removeItemAtPath:oldest error:NULL]) return NO;
    for (unsigned i = maxArchives; i > 0; i--) {
        NSString *source = i == 1 ? path : [path stringByAppendingFormat:@".%u", i - 1];
        if ([files fileExistsAtPath:source] && ![files moveItemAtPath:source
            toPath:[path stringByAppendingFormat:@".%u", i] error:NULL]) return NO;
    }
    return YES;
}

void SYLog(NSString *level, NSString *event, NSDictionary *fields) {
    prepareQueue();
    if (!atomic_load(&enabled)) return;
    // Never wait for diagnostic I/O on a capture, route, or export thread.
    if (dispatch_semaphore_wait(logSlots, DISPATCH_TIME_NOW)) { atomic_fetch_add(&dropped, 1); return; }
    NSDate *time = NSDate.date;
    NSDictionary *details = [fields copy];
    dispatch_async(logQueue, ^{
        @autoreleasepool {
            if (!logDirectory) { dispatch_semaphore_signal(logSlots); return; }
            NSMutableDictionary *entry = [@{@"time": [logClock stringFromDate:time], @"level": level,
                @"event": event, @"pid": @(getpid()), @"details": details ?: @{}} mutableCopy];
            unsigned lost = atomic_exchange(&dropped, 0);
            if (lost) entry[@"droppedEvents"] = @(lost);
            NSString *directory = details[@"directory"];
            struct statfs storage;
            if ([directory isKindOfClass:NSString.class] && statfs(directory.fileSystemRepresentation, &storage) == 0) {
                entry[@"diskFreeBytes"] = @((uint64_t)storage.f_bavail * storage.f_bsize);
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:NULL];
            // Keep individual messages bounded, even if an OS error contains an unusually large description.
            if (json.length > 16 * 1024) {
                entry[@"details"] = @{@"truncated": @YES, @"session": details[@"session"] ?: NSNull.null};
                json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:NULL];
            }
            if (json) {
                NSMutableData *line = [json mutableCopy];
                [line appendBytes:"\n" length:1];
                NSString *path = [logDirectory stringByAppendingPathComponent:@"bicord.log"];
                struct stat existing;
                BOOL full = lstat(path.fileSystemRepresentation, &existing) == 0 && existing.st_size + (off_t)line.length > maxLogBytes;
                if (!full || rotateLogs(path)) {
                    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600);
                    if (fd >= 0) {
                        const char *bytes = line.bytes;
                        size_t remaining = line.length;
                        while (remaining) {
                            ssize_t count = write(fd, bytes, remaining);
                            if (count < 0 && errno == EINTR) continue;
                            if (count <= 0) break;
                            bytes += count; remaining -= count;
                        }
                        close(fd);
                        if (remaining) NSLog(@"Bicord diagnostic write failed: %s", strerror(errno));
                    } else NSLog(@"Bicord diagnostic file unavailable: %s", strerror(errno));
                } else NSLog(@"Bicord diagnostic rotation failed");
            }
            dispatch_semaphore_signal(logSlots);
        }
    });
}

void sy_log_json(const char *level, const char *event, const char *fields) {
    @autoreleasepool {
        NSData *data = [@(fields) dataUsingEncoding:NSUTF8StringEncoding];
        id details = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        SYLog(@(level), @(event), [details isKindOfClass:NSDictionary.class] ? details : @{});
    }
}

void sy_log_flush(void) {
    prepareQueue();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(logQueue, ^{ dispatch_semaphore_signal(done); });
    // A full or unresponsive disk must not prevent the application from quitting.
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
}
