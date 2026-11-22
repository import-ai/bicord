#import "diagnostics.h"
#import <sys/stat.h>
#import <unistd.h>

static NSArray<NSDictionary *> *entries(NSURL *url) {
    NSString *content = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        assert(entry && entry[@"time"] && entry[@"pid"] && entry[@"level"] && entry[@"event"]);
        [result addObject:entry];
    }
    return result;
}

int main(void) {
    @autoreleasepool {
        char tmp[] = "/tmp/bicord-log-test.XXXXXX";
        assert(mkdtemp(tmp));
        NSURL *directory = [NSURL fileURLWithFileSystemRepresentation:tmp isDirectory:YES relativeToURL:nil];
        assert(sy_log_init(tmp));
        NSError *inner = [NSError errorWithDomain:NSPOSIXErrorDomain code:28 userInfo:nil];
        NSError *error = [NSError errorWithDomain:@"TestAVError" code:-11800 userInfo:@{NSUnderlyingErrorKey: inner}];
        SYLog(@"error", @"test.write.failed", @{@"session": @"test-session", @"error": SYError(error), @"directory": directory.path});
        sy_log_json("warning", "test.multiline", "{\"message\":\"first\\nsecond\"}");
        sy_log_json("warning", "test.invalid", "[]");
        SYLog(@"warning", @"test.oversized", @{@"message": [@"x" stringByPaddingToLength:20000 withString:@"x" startingAtIndex:0]});
        sy_log_flush();
        NSURL *current = [directory URLByAppendingPathComponent:@"bicord.log"];
        NSArray *initial = entries(current);
        assert(initial.count == 5);
        assert([initial[3][@"details"] count] == 0);
        assert([initial[4][@"details"][@"truncated"] boolValue]);
        NSDictionary *failure = initial[1];
        assert([failure[@"details"][@"session"] isEqual:@"test-session"]);
        assert([failure[@"details"][@"error"][@"domain"] isEqual:@"TestAVError"]);
        assert([failure[@"details"][@"error"][@"underlying"][@"code"] intValue] == 28);
        assert([failure[@"diskFreeBytes"] unsignedLongLongValue] > 0);
        struct stat permissions;
        assert(stat(current.fileSystemRepresentation, &permissions) == 0 && (permissions.st_mode & 0777) == 0600);

        dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t i) {
            SYLog(@"info", @"test.concurrent", @{@"sequence": @(i)});
        });
        sy_log_flush();
        assert(entries(current).count == initial.count + 64);
        NSString *large = [@"x" stringByPaddingToLength:2048 withString:@"x" startingAtIndex:0];
        for (int i = 0; i < 6400; i++) {
            SYLog(@"info", @"test.rotation", @{@"sequence": @(i), @"message": large});
            if (i % 32 == 31) sy_log_flush();
        }
        sy_log_flush();
        NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:NULL];
        assert(files.count == 5);
        unsigned long long total = 0;
        for (NSURL *file in files) {
            unsigned long long bytes = [[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:NULL] fileSize];
            assert(bytes <= 2 * 1024 * 1024);
            total += bytes;
            assert(entries(file).count > 0);
        }
        assert(total <= 10 * 1024 * 1024);
        assert([entries(current).lastObject[@"details"][@"sequence"] intValue] == 6399);
        // A failed log open must not crash or block the application.
        assert([NSFileManager.defaultManager removeItemAtURL:current error:NULL]);
        assert([NSFileManager.defaultManager createDirectoryAtURL:current withIntermediateDirectories:NO attributes:nil error:NULL]);
        SYLog(@"error", @"test.unwritable", @{});
        sy_log_flush();
        NSURL *blocked = [directory URLByAppendingPathComponent:@"not-a-directory"];
        assert([NSData.data writeToURL:blocked atomically:YES]);
        assert(sy_log_init([[blocked URLByAppendingPathComponent:@"logs"] path].UTF8String));
        SYLog(@"error", @"test.unavailable.directory", @{});
        sy_log_flush();
        assert([NSFileManager.defaultManager removeItemAtURL:directory error:NULL]);
        puts("Structured errors, concurrent writes, rotation limits, file permissions and unavailable logs passed.");
    }
}
