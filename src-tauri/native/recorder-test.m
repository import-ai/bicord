#import "recorder.m"

@interface FailingTrack : SYTrack
@property BOOL failOpen;
@end
@implementation FailingTrack
- (BOOL)openFile:(NSError **)error {
    if (self.failOpen) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:nil];
        return NO;
    }
    return [super openFile:error];
}
@end

static void recoveryTests(NSURL *root) {
    NSURL *directory = [root URLByAppendingPathComponent:@"recovery" isDirectory:YES];
    assert([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:NULL]);
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:8000 channels:1 interleaved:NO];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:8000];
    buffer.frameLength = 8000;
    for (int i = 0; i < 8000; i++) buffer.floatChannelData[0][i] = 0.4 * sin(2 * M_PI * 440 * i / 8000);
    SYTrack *track = [[SYTrack alloc] initWithURL:[directory URLByAppendingPathComponent:@"system-long.caf"] format:format error:NULL];
    UInt64 start = AudioGetCurrentHostTime();
    for (int i = 0; i < 1861; i++) {
        @autoreleasepool { [track write:buffer hostTime:start + AudioConvertNanosToHostTime((UInt64)i * NSEC_PER_SEC)]; }
    }
    assert([track finish]);
    track = nil;
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory.path error:NULL];
    NSUInteger chunks = 0;
    for (NSString *name in files) if ([name.pathExtension isEqual:@"caf"]) chunks++;
    assert(chunks == 63);
    NSURL *output = [directory URLByAppendingPathComponent:@"restored.m4a"];
    NSString *warning = nil;
    // An invalid destination fails without consuming the source audio; a fresh export can retry.
    assert(exportDirectory(directory, [directory URLByAppendingPathComponent:@"missing/export.m4a"], &warning));
    assert(!exportDirectory(directory, output, &warning));
    assert(!warning && fabs(sy_duration(output.path.UTF8String) - 1861) < 0.1);
    assert([[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory.path error:NULL] count] >= chunks * 2);

    NSURL *faults = [root URLByAppendingPathComponent:@"faults" isDirectory:YES];
    assert([NSFileManager.defaultManager createDirectoryAtURL:faults withIntermediateDirectories:NO attributes:nil error:NULL]);
    FailingTrack *fault = [[FailingTrack alloc] initWithURL:[faults URLByAppendingPathComponent:@"mic-fault.caf"] format:format error:NULL];
    for (int i = 0; i < 30; i++) [fault write:buffer hostTime:start + AudioConvertNanosToHostTime((UInt64)i * NSEC_PER_SEC)];
    fault.failOpen = YES;
    [fault write:buffer hostTime:start + AudioConvertNanosToHostTime(30ull * NSEC_PER_SEC)];
    assert(fault.warning);
    fault.failOpen = NO;
    [fault setValue:@0 forKey:@"retryAfter"];
    [fault write:buffer hostTime:start + AudioConvertNanosToHostTime(31ull * NSEC_PER_SEC)];
    // An extreme clock jump is clamped instead of padding hours of silence.
    [fault write:buffer hostTime:UINT64_MAX];
    assert([fault finish]);
    warning = nil;
    assert(!exportDirectory(faults, [faults URLByAppendingPathComponent:@"fault-restored.m4a"], &warning));
    assert(fabs(sy_duration([[faults URLByAppendingPathComponent:@"fault-restored.m4a"] path].UTF8String) - 33) < 0.1);
    // A corrupt chunk must not prevent exporting the intact chunks.
    [@"broken" writeToURL:[faults URLByAppendingPathComponent:@"mic-broken.caf"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    warning = nil;
    assert(!exportDirectory(faults, [faults URLByAppendingPathComponent:@"partial.m4a"], &warning) && warning);
    puts("31-minute chunk recovery, failed-export retry, disk failure recovery, corrupt chunks and clock jumps passed.");
}

static SYTrack *tone(NSURL *directory, NSString *name, double frequency, double rate, AVAudioChannelCount channels, UInt64 start) {
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                    sampleRate:rate channels:channels interleaved:channels > 1];
    SYTrack *track = [[SYTrack alloc] initWithURL:[directory URLByAppendingPathComponent:name] format:format error:NULL];
    AVAudioFrameCount frames = (AVAudioFrameCount)rate;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];
    buffer.frameLength = frames;
    for (AVAudioFrameCount i = 0; i < frames; ++i) {
        float sample = 0.5 * sin(2 * M_PI * frequency * i / rate);
        for (AVAudioChannelCount channel = 0; channel < channels; ++channel) {
            buffer.floatChannelData[channel][i * buffer.stride] = sample;
        }
    }
    [track enqueue:buffer.audioBufferList frames:frames hostTime:start];
    [track finish];
    assert(track.frames == frames);
    return track;
}

static double amplitude(AVAudioPCMBuffer *audio, double frequency, double offset) {
    double rate = audio.format.sampleRate;
    int start = (int)(rate * offset);
    int frames = (int)(rate * 0.15);
    double real = 0, imaginary = 0;
    for (int i = 0; i < frames; ++i) {
        double phase = 2 * M_PI * frequency * i / rate;
        double sample = audio.floatChannelData[0][start + i];
        real += sample * cos(phase);
        imaginary += sample * sin(phase);
    }
    return 2 * hypot(real, imaginary) / frames;
}

int main(int argc, const char *argv[]) {
    if (argc == 3 && strcmp(argv[1], "--crash") == 0) {
        @autoreleasepool {
            NSURL *directory = [NSURL fileURLWithPath:@(argv[2])];
            AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:8000 channels:1 interleaved:NO];
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:8000];
            buffer.frameLength = 8000;
            memset(buffer.floatChannelData[0], 0, 8000 * sizeof(float));
            SYTrack *track = [[SYTrack alloc] initWithURL:[directory URLByAppendingPathComponent:@"system-crash.caf"] format:format error:NULL];
            UInt64 start = AudioGetCurrentHostTime();
            for (int i = 0; i < 31; i++) [track write:buffer hostTime:start + AudioConvertNanosToHostTime((UInt64)i * NSEC_PER_SEC)];
            _exit(0);
        }
    }
    @autoreleasepool {
        char tmp[] = "/tmp/bicord-test.XXXXXX";
        assert(mkdtemp(tmp));
        NSURL *directory = [NSURL fileURLWithFileSystemRepresentation:tmp isDirectory:YES relativeToURL:nil];
        UInt64 start = AudioGetCurrentHostTime();
        SYTrack *system = tone(directory, @"system-a.caf", 440, 48000, 2, start);
        SYTrack *mic = tone(directory, @"mic-a.caf", 730, 48000, 1, start + AudioConvertNanosToHostTime(300000000));
        SYTrack *systemNext = tone(directory, @"system-b.caf", 980, 44100, 2, start + AudioConvertNanosToHostTime(1200000000));
        SYTrack *micNext = tone(directory, @"mic-b.caf", 1170, 32000, 1, start + AudioConvertNanosToHostTime(1400000000));
        NSURL *output = [directory URLByAppendingPathComponent:@"test.m4a"];
        NSString *warning = nil;
        NSString *error = exportSegments(@[system, systemNext], @[mic, micNext], YES, YES, output, &warning);
        if (error || warning) NSLog(@"Export issue: %@ %@", error, warning);
        assert(!error && !warning);
        NSURL *published = [directory URLByAppendingPathComponent:@"recording.m4a"];
        assert(!sy_publish(output.path.UTF8String, published.path.UTF8String));
        char *publishError = sy_publish(system.url.path.UTF8String, published.path.UTF8String);
        assert(publishError && [NSFileManager.defaultManager fileExistsAtPath:system.url.path]);
        sy_free(publishError);
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:published error:NULL];
        assert(file && fabs(file.length / file.fileFormat.sampleRate - 2.4) < 0.05);
        AVAudioPCMBuffer *audio = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                                frameCapacity:(AVAudioFrameCount)file.length];
        assert([file readIntoBuffer:audio error:NULL]);
        assert(amplitude(audio, 440, 0.5) > 0.10 && amplitude(audio, 730, 0.5) > 0.10);
        assert(amplitude(audio, 980, 1.6) > 0.10 && amplitude(audio, 1170, 1.6) > 0.10);
        assert(amplitude(audio, 730, 0.05) < 0.02);
        NSURL *micOnly = [directory URLByAppendingPathComponent:@"mic-only.m4a"];
        NSURL *systemOnly = [directory URLByAppendingPathComponent:@"system-only.m4a"];
        assert(!exportSegments(@[], @[mic], NO, YES, micOnly, &warning) && !warning);
        assert(!exportSegments(@[system], @[], YES, NO, systemOnly, &warning) && !warning);
        assert(fabs(sy_duration(micOnly.path.UTF8String) - 1) < 0.05);
        assert(fabs(sy_duration(systemOnly.path.UTF8String) - 1) < 0.05);
        recoveryTests(directory);
        NSURL *crash = [directory URLByAppendingPathComponent:@"crash" isDirectory:YES];
        assert([NSFileManager.defaultManager createDirectoryAtURL:crash withIntermediateDirectories:NO attributes:nil error:NULL]);
        NSTask *child = [[NSTask alloc] init];
        child.executableURL = [NSURL fileURLWithPath:@(argv[0])];
        child.arguments = @[@"--crash", crash.path];
        assert([child launchAndReturnError:NULL]);
        [child waitUntilExit];
        assert(child.terminationStatus == 0);
        warning = nil;
        NSURL *crashOutput = [crash URLByAppendingPathComponent:@"recovered.m4a"];
        assert(!exportDirectory(crash, crashOutput, &warning));
        assert(sy_duration(crashOutput.path.UTF8String) >= 29.99);
        puts("Abrupt process exit preserved sealed chunks for the next process.");
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:8000 channels:1 interleaved:NO];
        SYTrack *stalled = [[SYTrack alloc] initWithURL:[directory URLByAppendingPathComponent:@"system-stalled.caf"] format:format error:NULL];
        dispatch_queue_t writer = [stalled valueForKey:@"writer"];
        dispatch_semaphore_t release = dispatch_semaphore_create(0);
        dispatch_async(writer, ^{ dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER); });
        double before = hostSeconds(AudioGetCurrentHostTime());
        assert(![stalled finish] && stalled.warning);
        assert(hostSeconds(AudioGetCurrentHostTime()) - before < 6);
        dispatch_semaphore_signal(release);
        dispatch_sync(writer, ^{});
        puts("A stalled writer returned an error within the bounded stop timeout.");
        SYRecorder *blocked = [[SYRecorder alloc] initWithDirectory:directory withSystem:NO withMic:NO];
        dispatch_queue_t control = [blocked valueForKey:@"control"];
        dispatch_semaphore_t unblock = dispatch_semaphore_create(0);
        dispatch_async(control, ^{ dispatch_semaphore_wait(unblock, DISPATCH_TIME_FOREVER); });
        before = hostSeconds(AudioGetCurrentHostTime());
        assert([blocked snapshot][@"warning"] != NSNull.null);
        assert(hostSeconds(AudioGetCurrentHostTime()) - before < 1);
        before = hostSeconds(AudioGetCurrentHostTime());
        assert([blocked closeCapture]);
        assert(hostSeconds(AudioGetCurrentHostTime()) - before < 16);
        dispatch_semaphore_signal(unblock);
        dispatch_sync(control, ^{});
        puts("An unresponsive audio device did not block status or stop indefinitely.");
        assert([NSFileManager.defaultManager removeItemAtURL:directory error:NULL]);
        puts("M4A mix preserved both sources before and after a device format change.");
    }
}
