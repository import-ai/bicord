#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/HostTime.h>
#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import <unistd.h>
#import <fcntl.h>
#import "diagnostics.h"

static NSDictionary *fileFields(NSURL *url) {
    NSURL *directory = url.URLByDeletingLastPathComponent;
    return @{@"session": directory.lastPathComponent ?: @"", @"directory": directory.path ?: @"",
        @"file": url.lastPathComponent ?: @""};
}

static void logFileError(NSString *event, NSURL *url, NSError *error) {
    NSMutableDictionary *fields = [fileFields(url) mutableCopy];
    fields[@"error"] = SYError(error);
    SYLog(@"error", event, fields);
}

static NSString *statusError(NSString *operation, OSStatus status) {
    return [NSString stringWithFormat:@"%@（Core Audio %d）", operation, (int)status];
}

static AudioObjectID defaultDevice(AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device);
    return device;
}

static NSString *deviceString(AudioObjectID device, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    CFStringRef name = NULL;
    UInt32 size = sizeof(name);
    if (device && AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name) == noErr && name) {
        return CFBridgingRelease(name);
    }
    return nil;
}

static NSString *deviceName(AudioObjectID device) {
    return deviceString(device, kAudioObjectPropertyName) ?: @"未检测到设备";
}

static OSStatus tapFormat(AudioObjectID tap, AudioStreamBasicDescription *format) {
    AudioObjectPropertyAddress address = {
        kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(*format);
    return AudioObjectGetPropertyData(tap, &address, 0, NULL, &size, format);
}

static double hostSeconds(UInt64 hostTime) {
    return AudioConvertHostTimeToNanos(hostTime) / 1e9;
}

@interface SYTrack : NSObject {
    AVAudioFile *_file;
    NSURL *_baseURL;
    NSUInteger _chunk;
    NSString *_writeIssue;
    double _retryAfter;
    BOOL _finished;
    dispatch_queue_t _writer;
    dispatch_semaphore_t _slots;
    atomic_bool _overrun;
    atomic_bool _writeFailed;
    _Atomic(float) _level;
    atomic_uint_fast64_t _lastBuffer;
}
@property (readonly) NSURL *url;
@property (readonly) AVAudioFormat *format;
@property (readonly) UInt64 firstHostTime;
@property (readonly) AVAudioFramePosition frames;
- (instancetype)initWithURL:(NSURL *)url format:(AVAudioFormat *)format error:(NSError **)error;
- (void)enqueue:(const AudioBufferList *)data frames:(AVAudioFrameCount)frames hostTime:(UInt64)hostTime;
- (instancetype)initReading:(NSURL *)url hostTime:(UInt64)hostTime;
- (BOOL)finish;
- (NSString *)warning;
- (float)level;
@end

@implementation SYTrack
- (instancetype)initReading:(NSURL *)url hostTime:(UInt64)hostTime {
    if (!(self = [super init])) return nil;
    NSError *error = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&error];
    if (!file || !file.length || !hostTime) {
        if (error) logFileError(@"export.chunk.read.failed", url, error);
        return nil;
    }
    _url = url; _format = file.processingFormat; _frames = file.length; _firstHostTime = hostTime;
    atomic_init(&_overrun, false); atomic_init(&_writeFailed, false);
    atomic_init(&_level, 0); atomic_init(&_lastBuffer, 0);
    return self;
}
- (instancetype)initWithURL:(NSURL *)url format:(AVAudioFormat *)format error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _url = url;
    _format = format;
    _writer = dispatch_queue_create("local.bicord.pcm", DISPATCH_QUEUE_SERIAL);
    _slots = dispatch_semaphore_create(64);
    atomic_init(&_overrun, false);
    atomic_init(&_writeFailed, false);
    atomic_init(&_level, 0);
    atomic_init(&_lastBuffer, 0);
    _baseURL = url;
    return [self openFile:error] ? self : nil;
}

- (BOOL)openFile:(NSError **)error {
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(_format.sampleRate),
        AVNumberOfChannelsKey: @(_format.channelCount), AVLinearPCMBitDepthKey: @16
    };
    _file = [[AVAudioFile alloc] initForWriting:_url settings:settings commonFormat:_format.commonFormat
                                   interleaved:_format.isInterleaved error:error];
    if (_file) SYLog(@"info", @"chunk.opened", fileFields(_url));
    else logFileError(@"chunk.open.failed", _url, error ? *error : nil);
    return _file != nil;
}

- (void)closeChunk {
    BOOL wasOpen = _file != nil;
    _file = nil;
    int fd = open(_url.fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) {
        if (fsync(fd) != 0) logFileError(@"chunk.sync.failed", _url, [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
        close(fd);
    }
    if (wasOpen) {
        NSMutableDictionary *fields = [fileFields(_url) mutableCopy];
        [fields addEntriesFromDictionary:@{@"frames": @(_frames), @"sampleRate": @(_format.sampleRate),
            @"channels": @(_format.channelCount), @"hostTime": @(_firstHostTime)}];
        SYLog(@"info", @"chunk.closed", fields);
    }
}

- (void)nextChunk {
    [self closeChunk];
    _url = [[_baseURL URLByDeletingPathExtension] URLByAppendingPathExtension:
        [NSString stringWithFormat:@"%lu.caf", (unsigned long)++_chunk]];
    _frames = 0;
    _firstHostTime = 0;
}

- (BOOL)saveBuffer:(AVAudioPCMBuffer *)buffer {
    NSError *error = nil;
    if ([_file writeFromBuffer:buffer error:&error]) { _frames += buffer.frameLength; return YES; }
    logFileError(@"chunk.write.failed", _url, error);
    @synchronized (self) { _writeIssue = error.localizedDescription ?: @"写入录音失败。"; }
    atomic_store(&_writeFailed, true);
    _retryAfter = hostSeconds(AudioGetCurrentHostTime()) + 1;
    [self nextChunk];
    return NO;
}

- (void)enqueue:(const AudioBufferList *)data frames:(AVAudioFrameCount)frames hostTime:(UInt64)hostTime {
    if (!frames) return;
    if (dispatch_semaphore_wait(_slots, DISPATCH_TIME_NOW) != 0) {
        atomic_store(&_overrun, true);
        return;
    }
    AVAudioPCMBuffer *copy = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_format frameCapacity:frames];
    copy.frameLength = frames;
    AudioBufferList *dest = copy.mutableAudioBufferList;
    if (!dest || dest->mNumberBuffers != data->mNumberBuffers) {
        atomic_store(&_overrun, true);
        dispatch_semaphore_signal(_slots);
        return;
    }
    for (UInt32 i = 0; i < dest->mNumberBuffers; ++i) {
        AudioBuffer buffer = dest->mBuffers[i];
        AudioBuffer source = data->mBuffers[i];
        if (source.mData && source.mNumberChannels == buffer.mNumberChannels && source.mDataByteSize >= buffer.mDataByteSize) {
            memcpy(buffer.mData, source.mData, buffer.mDataByteSize);
        } else {
            memset(buffer.mData, 0, buffer.mDataByteSize);
        }
    }
    atomic_store(&_lastBuffer, AudioGetCurrentHostTime());
    dispatch_async(_writer, ^{
        @autoreleasepool {
            if (!self->_finished) {
                [self write:copy hostTime:hostTime];
            }
            dispatch_semaphore_signal(self->_slots);
        }
    });
}

- (void)write:(AVAudioPCMBuffer *)buffer hostTime:(UInt64)hostTime {
    double now = hostSeconds(AudioGetCurrentHostTime());
    if (atomic_load(&_writeFailed) && now < _retryAfter) return;
    double delta = _firstHostTime ? hostSeconds(hostTime) - hostSeconds(_firstHostTime) : 0;
    double expected = delta * _format.sampleRate;
    double gap = expected - _frames;
    // Discontinuous clocks must never trigger an unbounded silence allocation or write loop.
    if (_firstHostTime && (!isfinite(expected) || delta < 0 || gap > 60 * _format.sampleRate)) {
        hostTime = _firstHostTime + AudioConvertNanosToHostTime((UInt64)(_frames / _format.sampleRate * 1e9));
        gap = 0;
        if (!atomic_exchange(&_overrun, true)) SYLog(@"warning", @"capture.clock.discontinuity", fileFields(_url));
    }
    if (_frames >= _format.sampleRate * 30 || gap > 2 * _format.sampleRate) [self nextChunk];
    NSError *error = nil;
    if (!_file && ![self openFile:&error]) {
        logFileError(@"chunk.reopen.failed", _url, error);
        @synchronized (self) { _writeIssue = error.localizedDescription; }
        atomic_store(&_writeFailed, true);
        _retryAfter = now + 1;
        return;
    }
    if (!_firstHostTime) {
        _firstHostTime = hostTime ?: AudioGetCurrentHostTime();
        NSData *metadata = [NSJSONSerialization dataWithJSONObject:@{@"hostTime": @(_firstHostTime)} options:0 error:&error];
        if (![metadata writeToURL:[_url URLByAppendingPathExtension:@"json"] options:NSDataWritingAtomic error:&error]) {
            logFileError(@"chunk.metadata.failed", _url, error);
            @synchronized (self) { _writeIssue = error.localizedDescription; }
            atomic_store(&_writeFailed, true);
            _retryAfter = now + 1;
            [self nextChunk];
            return;
        }
        gap = 0;
    }
    if (atomic_exchange(&_writeFailed, false)) SYLog(@"info", @"chunk.write.recovered", fileFields(_url));
    if (gap > _format.sampleRate * 0.08 && gap <= _format.sampleRate * 2) {
        AVAudioPCMBuffer *silence = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_format frameCapacity:(AVAudioFrameCount)gap];
        silence.frameLength = (AVAudioFrameCount)gap;
        AudioBufferList *list = silence.mutableAudioBufferList;
        for (UInt32 i = 0; i < list->mNumberBuffers; ++i) memset(list->mBuffers[i].mData, 0, list->mBuffers[i].mDataByteSize);
        if (![self saveBuffer:silence]) return;
    }
    if (![self saveBuffer:buffer]) return;

    float peak = 0;
    const AudioBufferList *list = buffer.audioBufferList;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        const void *samples = list->mBuffers[i].mData;
        UInt32 count = buffer.frameLength * list->mBuffers[i].mNumberChannels;
        switch (_format.commonFormat) {
        case AVAudioPCMFormatFloat32:
            for (UInt32 j = 0; j < count; ++j) peak = fmaxf(peak, fabsf(((const float *)samples)[j]));
            break;
        case AVAudioPCMFormatFloat64:
            for (UInt32 j = 0; j < count; ++j) peak = fmaxf(peak, (float)fabs(((const double *)samples)[j]));
            break;
        case AVAudioPCMFormatInt16:
            for (UInt32 j = 0; j < count; ++j) peak = fmaxf(peak, fabsf(((const int16_t *)samples)[j] / 32768.0f));
            break;
        case AVAudioPCMFormatInt32:
            for (UInt32 j = 0; j < count; ++j) peak = fmaxf(peak, fabsf(((const int32_t *)samples)[j] / 2147483648.0f));
            break;
        default:
            break;
        }
    }
    atomic_store(&_level, fmaxf(fminf(peak, 1), atomic_load(&_level) * 0.85f));
}

- (BOOL)finish {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_writer, ^{ self->_finished = YES; [self closeChunk]; dispatch_semaphore_signal(done); });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
        SYLog(@"error", @"chunk.drain.timeout", fileFields(_baseURL));
        @synchronized (self) { self->_writeIssue = @"磁盘写入超时，已完成的片段已保留，请稍后重试导出。"; }
        return NO;
    }
    if (atomic_load(&_overrun)) SYLog(@"warning", @"capture.buffer.dropped", fileFields(_baseURL));
    return YES;
}

- (NSString *)warning {
    @synchronized (self) { if (_writeIssue) return [@"部分录音写入异常，已保留可用片段：" stringByAppendingString:_writeIssue]; }
    if (atomic_load(&_overrun)) return @"部分音频缓冲未能写入，录音可能有短暂缺口。";
    return nil;
}

- (float)level {
    UInt64 last = atomic_load(&_lastBuffer);
    if (hostSeconds(AudioGetCurrentHostTime()) - hostSeconds(last) > 0.5) return 0;
    return atomic_load(&_level);
}
@end

static NSString *exportSegments(NSArray<SYTrack *> *system, NSArray<SYTrack *> *mic,
                                BOOL withSystem, BOOL withMic, NSURL *destination, NSString **warning) {
    NSArray<NSArray<SYTrack *> *> *sources = @[system, mic];
    UInt64 origin = UINT64_MAX;
    for (NSArray<SYTrack *> *segments in sources) {
        for (SYTrack *segment in segments) {
            if (segment.frames) origin = MIN(origin, segment.firstHostTime);
            if (segment.warning) *warning = segment.warning;
        }
    }
    if (origin == UINT64_MAX) return @"没有采集到音频。请检查已开启的音源和录音权限。";

    AVMutableComposition *composition = [AVMutableComposition composition];
    NSMutableArray<AVAudioMixInputParameters *> *parameters = [NSMutableArray array];
    for (NSArray<SYTrack *> *segments in sources) {
        AVMutableCompositionTrack *track = nil;
        CMTime end = kCMTimeZero;
        for (SYTrack *segment in segments) {
            if (!segment.frames) continue;
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:segment.url options:nil];
            dispatch_semaphore_t ready = dispatch_semaphore_create(0);
            __block AVAssetTrack *audio = nil;
            __block NSError *loadError = nil;
            [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
                audio = tracks.firstObject;
                loadError = error;
                dispatch_semaphore_signal(ready);
            }];
            if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
                SYLog(@"error", @"export.chunk.load.timeout", fileFields(segment.url));
                [asset cancelLoading];
                return @"读取片段超时，原始录音已保留，可重试导出。";
            }
            if (!audio) { logFileError(@"export.chunk.load.failed", segment.url, loadError); return loadError.localizedDescription ?: @"无法读取录音片段。"; }

            CMTime start = CMTimeMakeWithSeconds(hostSeconds(segment.firstHostTime) - hostSeconds(origin), 1000000);
            CMTime trim = CMTimeMaximum(kCMTimeZero, CMTimeSubtract(end, start));
            CMTime duration = CMTimeMake(segment.frames, (int32_t)segment.format.sampleRate);
            if (CMTimeCompare(trim, duration) >= 0) continue;
            CMTime at = CMTimeAdd(start, trim);
            CMTimeRange range = CMTimeRangeMake(trim, CMTimeSubtract(duration, trim));
            if (!track) track = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                       preferredTrackID:kCMPersistentTrackID_Invalid];
            NSError *error = nil;
            if (CMTimeCompare(at, end) > 0) {
                [track insertEmptyTimeRange:CMTimeRangeFromTimeToTime(end, at)];
            }
            if (![track insertTimeRange:range ofTrack:audio atTime:at error:&error]) {
                logFileError(@"export.chunk.insert.failed", segment.url, error);
                return error.localizedDescription ?: @"无法拼接录音片段。";
            }
            end = CMTimeAdd(at, range.duration);
        }
        if (track) {
            [parameters addObject:[AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track]];
        } else if (segments == system ? withSystem : withMic) {
            *warning = segments == system ? @"本次仅保存了麦克风声音，系统音频没有收到数据。"
                                          : @"本次仅保存了系统声音，麦克风没有收到数据。";
        }
    }
    for (AVMutableAudioMixInputParameters *input in parameters) {
        [input setVolume:parameters.count > 1 ? 0.5f : 1.0f atTime:kCMTimeZero];
    }
    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = parameters;
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetAppleM4A];
    if (!export) return @"无法初始化 M4A 导出。";
    export.audioMix = mix;
    export.outputFileType = AVFileTypeAppleM4A;
    export.outputURL = destination;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [export exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
    if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC))) {
        SYLog(@"error", @"export.encode.timeout", fileFields(destination));
        [export cancelExport];
        return @"导出超时，原始录音已保留，可重试导出。";
    }
    if (export.status != AVAssetExportSessionStatusCompleted) logFileError(@"export.encode.failed", destination, export.error);
    return export.status == AVAssetExportSessionStatusCompleted ? nil : (export.error.localizedDescription ?: @"M4A 导出失败。");
}

static NSString *exportDirectory(NSURL *directory, NSURL *destination, NSString **warning) {
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    SYLog(@"info", @"export.started", fileFields(destination));
    NSString *savedWarning = [NSString stringWithContentsOfURL:[directory URLByAppendingPathComponent:@"capture-warning"] encoding:NSUTF8StringEncoding error:NULL];
    if (savedWarning.length) *warning = savedWarning;
    NSMutableArray *system = [NSMutableArray array], *mic = [NSMutableArray array];
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:NULL];
    for (NSURL *url in files) {
        if (![url.pathExtension isEqual:@"caf"] ||
            !([url.lastPathComponent hasPrefix:@"system-"] || [url.lastPathComponent hasPrefix:@"mic-"])) continue;
        NSDictionary *metadata = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfURL:[url URLByAppendingPathExtension:@"json"]] ?: [NSData data] options:0 error:NULL];
        NSNumber *hostTime = [metadata isKindOfClass:NSDictionary.class] ? metadata[@"hostTime"] : nil;
        SYTrack *track = [hostTime isKindOfClass:NSNumber.class] ?
            [[SYTrack alloc] initReading:url hostTime:hostTime.unsignedLongLongValue] : nil;
        if (!track) {
            SYLog(@"warning", @"export.chunk.skipped", fileFields(url));
            *warning = @"部分片段不可读，已保留原始录音供恢复。"; continue;
        }
        if ([url.lastPathComponent hasPrefix:@"system-"]) [system addObject:track];
        else if ([url.lastPathComponent hasPrefix:@"mic-"]) [mic addObject:track];
    }
    NSComparator order = ^NSComparisonResult(SYTrack *a, SYTrack *b) {
        return a.firstHostTime < b.firstHostTime ? NSOrderedAscending : a.firstHostTime > b.firstHostTime ? NSOrderedDescending : NSOrderedSame;
    };
    [system sortUsingComparator:order]; [mic sortUsingComparator:order];
    NSDictionary *session = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"session.json"]] ?: NSData.data options:0 error:NULL];
    BOOL withSystem = [session isKindOfClass:NSDictionary.class] && [session[@"system_audio"] isEqual:@YES];
    BOOL withMic = [session isKindOfClass:NSDictionary.class] && [session[@"microphone"] isEqual:@YES];
    NSString *issue = exportSegments(system, mic, withSystem, withMic, destination, warning);
    NSMutableDictionary *fields = [fileFields(destination) mutableCopy];
    [fields addEntriesFromDictionary:@{@"systemChunks": @(system.count), @"micChunks": @(mic.count),
        @"elapsedSeconds": @(CFAbsoluteTimeGetCurrent() - began), @"error": issue ?: NSNull.null, @"warning": *warning ?: NSNull.null}];
    SYLog(issue ? @"error" : *warning ? @"warning" : @"info", issue ? @"export.failed" : @"export.completed", fields);
    return issue;
}

@interface SYRecorder : NSObject {
    NSURL *_directory;
    dispatch_queue_t _control;
    dispatch_source_t _routeTimer;
    id _terminationObserver;
    BOOL _withSystem;
    BOOL _withMic;
    BOOL _systemRunning;
    BOOL _micTapInstalled;
    BOOL _drainFailed;
    AudioObjectID _outputDevice;
    AudioObjectID _inputDevice;
    AudioObjectID _tap;
    AudioStreamBasicDescription _tapFormat;
    AudioObjectID _aggregate;
    AudioDeviceIOProcID _ioProc;
    AVAudioEngine *_engine;
    SYTrack *_system;
    SYTrack *_mic;
    NSMutableArray<SYTrack *> *_systemSegments;
    NSMutableArray<SYTrack *> *_micSegments;
    NSString *_systemIssue;
    NSString *_micIssue;
    AudioObjectID _lastOutputAttempt;
    AudioObjectID _lastInputAttempt;
    NSUInteger _outputAttempts;
    NSUInteger _inputAttempts;
    BOOL _statusTimedOut;
    NSString *_lastReportedWarning;
}
- (instancetype)initWithDirectory:(NSURL *)directory withSystem:(BOOL)withSystem withMic:(BOOL)withMic;
- (NSString *)start;
- (NSDictionary *)snapshot;
- (NSString *)stopAndExport:(NSURL *)destination warning:(NSString **)warning;
- (NSString *)closeCapture;
@end

@implementation SYRecorder
- (instancetype)initWithDirectory:(NSURL *)directory withSystem:(BOOL)withSystem withMic:(BOOL)withMic {
    if (!(self = [super init])) return nil;
    _directory = directory;
    _withSystem = withSystem;
    _withMic = withMic;
    _control = dispatch_queue_create("local.bicord.routes", DISPATCH_QUEUE_SERIAL);
    _systemSegments = [NSMutableArray array];
    _micSegments = [NSMutableArray array];
    // Native macOS Quit can bypass the Tauri exit request callback.
    __weak SYRecorder *weakSelf = self;
    _terminationObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification
        object:nil queue:nil usingBlock:^(__unused NSNotification *notification) {
            [weakSelf closeCapture]; sy_log_flush();
        }];
    return self;
}

- (void)dealloc {
    if (_terminationObserver) [NSNotificationCenter.defaultCenter removeObserver:_terminationObserver];
}

- (SYTrack *)trackFor:(NSString *)source format:(AVAudioFormat *)format error:(NSError **)error {
    NSString *name = [NSString stringWithFormat:@"%@-%@.caf", source, NSUUID.UUID.UUIDString];
    return [[SYTrack alloc] initWithURL:[_directory URLByAppendingPathComponent:name] format:format error:error];
}

- (NSString *)startSystem:(AudioObjectID)output {
    NSString *uid = deviceString(output, kAudioDevicePropertyDeviceUID);
    if (!uid) return @"没有可用的系统输出设备。";
    AudioObjectPropertyAddress processAddress = {
        kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    pid_t pid = getpid();
    AudioObjectID process = kAudioObjectUnknown;
    UInt32 size = sizeof(process);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &processAddress, sizeof(pid), &pid, &size, &process);
    // shortcut: use the primary output stream, add per-stream taps if multistream interfaces are needed.
    CATapDescription *description = [[CATapDescription alloc]
        initExcludingProcesses:process ? @[@(process)] : @[] andDeviceUID:uid withStream:0];
    description.privateTap = YES;
    OSStatus status = AudioHardwareCreateProcessTap(description, &_tap);
    if (status != noErr) return statusError(@"无法创建系统音频采集，请检查系统音频录制权限", status);

    NSDictionary *aggregateConfig = @{
        @kAudioAggregateDeviceNameKey: @"Bicord",
        @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceTapListKey: @[@{
            @kAudioSubTapUIDKey: description.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey: @YES
        }]
    };
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregateConfig, &_aggregate);
    if (status != noErr) return statusError(@"无法初始化系统音频设备", status);

    AudioStreamBasicDescription asbd = {0};
    status = tapFormat(_tap, &asbd);
    if (status != noErr) return statusError(@"无法读取系统音频格式", status);
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
    if (!format || !asbd.mBytesPerFrame || format.sampleRate <= 0 || format.commonFormat == AVAudioOtherFormat) {
        return @"系统音频格式不受支持。";
    }

    NSError *error = nil;
    SYTrack *track = [self trackFor:@"system" format:format error:&error];
    if (!track) return error.localizedDescription;
    _system = track;
    UInt32 bytesPerFrame = asbd.mBytesPerFrame;
    status = AudioDeviceCreateIOProcIDWithBlock(&_ioProc, _aggregate, NULL,
        ^(const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime,
          __unused AudioBufferList *outputData, __unused const AudioTimeStamp *outputTime) {
            @autoreleasepool {
                if (!input->mNumberBuffers) return;
                UInt64 time = (inputTime->mFlags & kAudioTimeStampHostTimeValid) ? inputTime->mHostTime : now->mHostTime;
                [track enqueue:input frames:input->mBuffers[0].mDataByteSize / bytesPerFrame hostTime:time];
            }
        });
    if (status != noErr) return statusError(@"无法连接系统音频设备", status);
    status = AudioDeviceStart(_aggregate, _ioProc);
    if (status != noErr) return statusError(@"无法开始内录，请检查系统音频录制权限", status);
    _tapFormat = asbd;
    _systemRunning = YES;
    _outputDevice = output;
    return nil;
}

- (NSString *)startMic:(AudioObjectID)input {
    if (!input) return @"没有可用的麦克风。";
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *node = engine.inputNode;
    AudioUnit unit = node.audioUnit;
    if (!unit) return @"无法连接麦克风。";
    AudioObjectID current = kAudioObjectUnknown;
    UInt32 size = sizeof(current);
    OSStatus status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &current, &size);
    if (status != noErr) return statusError(@"无法读取麦克风设备", status);
    if (current != input) {
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &input, sizeof(input));
        if (status != noErr) return statusError(@"无法切换麦克风设备", status);
    }

    AVAudioFormat *format = [node outputFormatForBus:0];
    if (format.sampleRate <= 0 || !format.channelCount || format.commonFormat != AVAudioPCMFormatFloat32) {
        return @"麦克风暂时不可用。";
    }
    NSError *error = nil;
    SYTrack *track = [self trackFor:@"mic" format:format error:&error];
    if (!track) return error.localizedDescription;
    _mic = track;
    _engine = engine;
    @try {
        [node installTapOnBus:0 bufferSize:1024 format:nil block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
            @autoreleasepool {
                if (![buffer.format isEqual:format]) return;
                UInt64 time = when.isHostTimeValid ? when.hostTime : AudioGetCurrentHostTime();
                [track enqueue:buffer.audioBufferList frames:buffer.frameLength hostTime:time];
            }
        }];
    } @catch (NSException *exception) {
        SYLog(@"error", @"device.mic.tap.exception", @{@"session": _directory.lastPathComponent,
            @"name": exception.name, @"reason": exception.reason ?: @""});
        return @"麦克风格式正在变化，请稍后重试。";
    }
    _micTapInstalled = YES;
    if (![engine startAndReturnError:&error]) {
        logFileError(@"device.mic.start.failed", track.url, error);
        return error.localizedDescription;
    }
    _inputDevice = input;
    return nil;
}

- (void)finishTrack:(SYTrack *)track inSegments:(NSMutableArray<SYTrack *> *)segments {
    if (!track) return;
    if (![track finish]) {
        _drainFailed = YES;
        [segments addObject:track];
        return;
    }
    if (track.frames || track.warning) {
        [segments addObject:track];
    } else {
        [NSFileManager.defaultManager removeItemAtURL:track.url error:NULL];
    }
}

- (void)checkStatus:(OSStatus)status operation:(NSString *)operation {
    if (status != noErr) SYLog(@"error", @"device.cleanup.failed", @{@"session": _directory.lastPathComponent,
        @"operation": operation, @"domain": @"NSOSStatusErrorDomain", @"code": @(status)});
}

- (void)closeSystem {
    if (_systemRunning) [self checkStatus:AudioDeviceStop(_aggregate, _ioProc) operation:@"AudioDeviceStop"];
    if (_ioProc) [self checkStatus:AudioDeviceDestroyIOProcID(_aggregate, _ioProc) operation:@"AudioDeviceDestroyIOProcID"];
    if (_aggregate) [self checkStatus:AudioHardwareDestroyAggregateDevice(_aggregate) operation:@"AudioHardwareDestroyAggregateDevice"];
    if (_tap) [self checkStatus:AudioHardwareDestroyProcessTap(_tap) operation:@"AudioHardwareDestroyProcessTap"];
    _systemRunning = NO;
    _ioProc = NULL;
    _aggregate = _tap = _outputDevice = kAudioObjectUnknown;
    [self finishTrack:_system inSegments:_systemSegments];
    _system = nil;
}

- (void)closeMic {
    [_engine stop];
    // Release the engine and its tap before draining the pending disk writes.
    if (_micTapInstalled) [_engine.inputNode removeTapOnBus:0];
    _micTapInstalled = NO;
    _engine = nil;
    _inputDevice = kAudioObjectUnknown;
    [self finishTrack:_mic inSegments:_micSegments];
    _mic = nil;
}

- (void)reconcileRoutes {
    if (_withSystem) {
        AudioObjectID output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice);
        AudioStreamBasicDescription format = {0};
        BOOL formatChanged = _systemRunning && tapFormat(_tap, &format) == noErr &&
            memcmp(&format, &_tapFormat, sizeof(format)) != 0;
        if (!_systemRunning || output != _outputDevice || formatChanged) {
            NSString *previous = _systemIssue;
            if (!previous || output != _lastOutputAttempt || formatChanged) {
                SYLog(@"info", @"device.system.reconnecting", @{@"session": _directory.lastPathComponent,
                    @"from": @(_outputDevice), @"to": @(output), @"device": deviceName(output), @"formatChanged": @(formatChanged)});
            }
            _lastOutputAttempt = output; _outputAttempts++;
            [self closeSystem];
            _systemIssue = [self startSystem:output];
            if (!_systemIssue || ![_systemIssue isEqual:previous]) {
                SYLog(_systemIssue ? @"error" : @"info", _systemIssue ? @"device.system.failed" : @"device.system.connected",
                    @{@"session": _directory.lastPathComponent, @"deviceID": @(output), @"device": deviceName(output),
                      @"attempts": @(_outputAttempts), @"error": _systemIssue ?: NSNull.null,
                      @"sampleRate": @(_system.format.sampleRate), @"channels": @(_system.format.channelCount)});
            }
            if (_systemIssue) [self closeSystem];
            else _outputAttempts = 0;
        }
    }
    AudioObjectID input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice);
    BOOL micFormatChanged = _engine.isRunning && ![[_engine.inputNode outputFormatForBus:0] isEqual:_mic.format];
    if (_withMic && (!_engine.isRunning || input != _inputDevice || micFormatChanged)) {
        NSString *previous = _micIssue;
        if (!previous || input != _lastInputAttempt || micFormatChanged) {
            SYLog(@"info", @"device.mic.reconnecting", @{@"session": _directory.lastPathComponent,
                @"from": @(_inputDevice), @"to": @(input), @"device": deviceName(input), @"formatChanged": @(micFormatChanged)});
        }
        _lastInputAttempt = input; _inputAttempts++;
        [self closeMic];
        _micIssue = [self startMic:input];
        if (!_micIssue || ![_micIssue isEqual:previous]) {
            SYLog(_micIssue ? @"error" : @"info", _micIssue ? @"device.mic.failed" : @"device.mic.connected",
                @{@"session": _directory.lastPathComponent, @"deviceID": @(input), @"device": deviceName(input),
                  @"attempts": @(_inputAttempts), @"error": _micIssue ?: NSNull.null,
                  @"sampleRate": @(_mic.format.sampleRate), @"channels": @(_mic.format.channelCount)});
        }
        if (_micIssue) [self closeMic];
        else _inputAttempts = 0;
    }
}

- (NSString *)start {
    if (_withMic) {
        AVAuthorizationStatus permission = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (permission == AVAuthorizationStatusNotDetermined) {
            dispatch_semaphore_t decision = dispatch_semaphore_create(0);
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(__unused BOOL granted) {
                dispatch_semaphore_signal(decision);
            }];
            dispatch_semaphore_wait(decision, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
            permission = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        }
        SYLog(permission == AVAuthorizationStatusAuthorized ? @"info" : @"error", @"capture.mic.permission",
            @{@"session": _directory.lastPathComponent, @"status": @(permission)});
        if (permission != AVAuthorizationStatusAuthorized) {
            return @"请在「系统设置 → 隐私与安全性 → 麦克风」允许 Bicord 访问。";
        }
    }

    __block NSString *error = nil;
    dispatch_group_t starting = dispatch_group_create();
    dispatch_group_async(starting, _control, ^{
        [self reconcileRoutes];
        error = self->_systemIssue ?: self->_micIssue;
        if (error) {
            [self closeSystem];
            [self closeMic];
            return;
        }
        self->_routeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_control);
        dispatch_source_set_timer(self->_routeTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4),
                                  NSEC_PER_SEC / 4, NSEC_PER_SEC / 40);
        __weak SYRecorder *weakSelf = self;
        dispatch_source_set_event_handler(self->_routeTimer, ^{ [weakSelf reconcileRoutes]; });
        dispatch_resume(self->_routeTimer);
    });
    if (dispatch_group_wait(starting, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC))) {
        SYLog(@"error", @"capture.start.timeout", @{@"session": _directory.lastPathComponent});
        return @"连接音频设备超时，请重试。已有片段会保留在本机。";
    }
    return error;
}

- (NSDictionary *)snapshot {
    __block NSDictionary *result;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_control, ^{
        result = @{
            @"systemLevel": @([self->_system level]),
            @"micLevel": @([self->_mic level]),
            @"outputName": deviceName(self->_outputDevice ?: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)),
            @"inputName": deviceName(self->_inputDevice ?: defaultDevice(kAudioHardwarePropertyDefaultInputDevice)),
            @"warning": self->_systemIssue ?: self->_micIssue ?: [self->_system warning] ?: [self->_mic warning] ?: NSNull.null
        };
        NSString *warning = result[@"warning"] == NSNull.null ? nil : result[@"warning"];
        if (warning && ![warning isEqual:self->_lastReportedWarning]) {
            SYLog(@"warning", @"capture.warning", @{@"session": self->_directory.lastPathComponent, @"warning": warning});
        }
        self->_lastReportedWarning = warning;
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5))) {
        @synchronized (self) {
            if (!_statusTimedOut) SYLog(@"warning", @"device.status.timeout", @{@"session": _directory.lastPathComponent});
            _statusTimedOut = YES;
        }
        return @{@"systemLevel": @0, @"micLevel": @0, @"outputName": @"正在连接…", @"inputName": @"正在连接…",
                 @"warning": @"音频设备响应缓慢，可停止录音并保存已有片段。"};
    }
    @synchronized (self) {
        if (_statusTimedOut) SYLog(@"info", @"device.status.recovered", @{@"session": _directory.lastPathComponent});
        _statusTimedOut = NO;
    }
    return result;
}

- (NSString *)closeCapture {
    SYLog(@"info", @"capture.stop.requested", @{@"session": _directory.lastPathComponent});
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_control, ^{
        if (self->_routeTimer) {
            dispatch_source_cancel(self->_routeTimer);
            self->_routeTimer = nil;
        }
        [self closeSystem];
        [self closeMic];
        NSString *warning = self->_systemIssue ?: self->_micIssue;
        for (SYTrack *track in [self->_systemSegments arrayByAddingObjectsFromArray:self->_micSegments]) {
            warning = warning ?: track.warning;
        }
        if (warning) [warning writeToURL:[self->_directory URLByAppendingPathComponent:@"capture-warning"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        if (!self->_drainFailed) [NSData.data writeToURL:[self->_directory URLByAppendingPathComponent:@"capture.closed"] atomically:YES];
        SYLog(self->_drainFailed ? @"error" : @"info", self->_drainFailed ? @"capture.drain.failed" : @"capture.sealed",
            @{@"session": self->_directory.lastPathComponent, @"warning": warning ?: NSNull.null});
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC))) {
        SYLog(@"error", @"capture.stop.timeout", @{@"session": _directory.lastPathComponent});
        return @"停止音频设备超时，原始片段已保留。可退出并重新打开 Bicord 后重试导出。";
    }
    return _drainFailed ? @"磁盘写入超时，片段已保留，请退出并重新打开后重试导出。" : nil;
}

- (NSString *)stopAndExport:(NSURL *)destination warning:(NSString **)warning {
    NSString *issue = [self closeCapture];
    if (issue) return issue;
    *warning = _systemIssue ?: _micIssue ?: [_systemSegments.lastObject warning] ?: [_micSegments.lastObject warning];
    return exportDirectory(_directory, destination, warning);
}
@end

void *sy_start(const char *directory, bool system, bool microphone, char **error) {
    @autoreleasepool {
        SYLog(@"info", @"capture.start.requested", @{@"session": [@(directory) lastPathComponent], @"directory": @(directory),
            @"systemAudio": @(system), @"microphone": @(microphone)});
        SYRecorder *recorder = [[SYRecorder alloc] initWithDirectory:
            [NSURL fileURLWithPath:[NSString stringWithUTF8String:directory] isDirectory:YES] withSystem:system withMic:microphone];
        NSString *issue = [recorder start];
        if (issue) {
            SYLog(@"error", @"capture.start.failed", @{@"session": [@(directory) lastPathComponent], @"error": issue});
            [recorder closeCapture];
            *error = strdup(issue.UTF8String);
            return NULL;
        }
        SYLog(@"info", @"capture.started", @{@"session": [@(directory) lastPathComponent]});
        return (__bridge_retained void *)recorder;
    }
}

char *sy_snapshot(void *handle) {
    @autoreleasepool {
        NSDictionary *snapshot = handle ? [(__bridge SYRecorder *)handle snapshot] : @{
            @"systemLevel": @0,
            @"micLevel": @0,
            @"outputName": deviceName(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)),
            @"inputName": deviceName(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)),
            @"warning": NSNull.null
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:NULL];
        return strndup(data.bytes, data.length);
    }
}

void sy_stop(void *handle, const char *destination, char **error, char **warning) {
    @autoreleasepool {
        SYRecorder *recorder = (__bridge_transfer SYRecorder *)handle;
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:destination]];
        NSString *notice = nil;
        NSString *issue = [recorder stopAndExport:url warning:&notice];
        if (issue) *error = strdup(issue.UTF8String);
        if (notice) *warning = strdup(notice.UTF8String);
    }
}

void sy_close(void *handle) {
    @autoreleasepool { SYRecorder *recorder = (__bridge_transfer SYRecorder *)handle; [recorder closeCapture]; }
}

void sy_export(const char *directory, const char *destination, char **error, char **warning) {
    @autoreleasepool {
        NSString *notice = nil;
        NSString *issue = exportDirectory([NSURL fileURLWithPath:@(directory)], [NSURL fileURLWithPath:@(destination)], &notice);
        if (issue) *error = strdup(issue.UTF8String);
        if (notice) *warning = strdup(notice.UTF8String);
    }
}

char *sy_publish(const char *source, const char *destination) {
    @autoreleasepool {
        NSError *error = nil;
        if ([NSFileManager.defaultManager moveItemAtPath:[NSString stringWithUTF8String:source]
                                                  toPath:[NSString stringWithUTF8String:destination] error:&error]) {
            return NULL;
        }
        logFileError(@"recording.publish.failed", [NSURL fileURLWithPath:@(source)], error);
        return strdup(error.localizedDescription.UTF8String ?: "Could not move the recording.");
    }
}

char *sy_choose_directory(const char *path) {
    __block char *selected = NULL;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSOpenPanel *panel = NSOpenPanel.openPanel;
        panel.title = @"选择录音保存目录";
        panel.prompt = @"选择";
        panel.directoryURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path] isDirectory:YES];
        panel.canChooseDirectories = YES;
        panel.canChooseFiles = NO;
        panel.allowsMultipleSelection = NO;
        panel.canCreateDirectories = YES;
        if ([panel runModal] == NSModalResponseOK) {
            const char *value = panel.URL.path.UTF8String;
            if (value) selected = strdup(value);
        }
    });
    return selected;
}

double sy_duration(const char *path) {
    @autoreleasepool {
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:
            [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]] error:NULL];
        return file ? (double)file.length / file.fileFormat.sampleRate : 0;
    }
}

void sy_free(char *value) {
    free(value);
}
