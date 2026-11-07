#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/HostTime.h>
#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import <unistd.h>

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
- (void)finish;
- (NSString *)warning;
- (float)level;
@end

@implementation SYTrack
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
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(format.sampleRate),
        AVNumberOfChannelsKey: @(format.channelCount),
        AVLinearPCMBitDepthKey: @16
    };
    _file = [[AVAudioFile alloc] initForWriting:url settings:settings commonFormat:format.commonFormat
                                   interleaved:format.isInterleaved error:error];
    return _file ? self : nil;
}

- (void)enqueue:(const AudioBufferList *)data frames:(AVAudioFrameCount)frames hostTime:(UInt64)hostTime {
    if (!frames || atomic_load(&_writeFailed)) return;
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
            if (!atomic_load(&self->_writeFailed)) {
                [self write:copy hostTime:hostTime];
            }
            dispatch_semaphore_signal(self->_slots);
        }
    });
}

- (void)write:(AVAudioPCMBuffer *)buffer hostTime:(UInt64)hostTime {
    if (!_firstHostTime) _firstHostTime = hostTime;
    AVAudioFramePosition expected = llround((hostSeconds(hostTime) - hostSeconds(_firstHostTime)) * _format.sampleRate);
    AVAudioFramePosition gap = expected - _frames;
    // Ignore small clock jitter and pad actual callback gaps on the shared host timeline.
    if (gap > _format.sampleRate * 0.08) {
        AVAudioFrameCount capacity = (AVAudioFrameCount)_format.sampleRate;
        AVAudioPCMBuffer *silence = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_format frameCapacity:capacity];
        while (gap > 0) {
            silence.frameLength = (AVAudioFrameCount)MIN(gap, capacity);
            AudioBufferList *list = silence.mutableAudioBufferList;
            for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
                memset(list->mBuffers[i].mData, 0, list->mBuffers[i].mDataByteSize);
            }
            if (![_file writeFromBuffer:silence error:NULL]) {
                atomic_store(&_writeFailed, true);
                return;
            }
            _frames += silence.frameLength;
            gap -= silence.frameLength;
        }
    }
    if (![_file writeFromBuffer:buffer error:NULL]) {
        atomic_store(&_writeFailed, true);
        return;
    }
    _frames += buffer.frameLength;

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

- (void)finish {
    dispatch_sync(_writer, ^{ self->_file = nil; });
}

- (NSString *)warning {
    if (atomic_load(&_writeFailed)) return @"写入录音失败，请检查磁盘剩余空间。";
    if (atomic_load(&_overrun)) return @"部分音频缓冲未能写入，录音可能有短暂缺口。";
    return nil;
}

- (float)level {
    UInt64 last = atomic_load(&_lastBuffer);
    if (hostSeconds(AudioGetCurrentHostTime()) - hostSeconds(last) > 0.5) return 0;
    return atomic_load(&_level);
}
@end

static NSString *exportSegments(NSArray<SYTrack *> *system, NSArray<SYTrack *> *mic, BOOL withMic,
                                NSURL *destination, NSString **warning) {
    NSArray<NSArray<SYTrack *> *> *sources = @[system, mic];
    UInt64 origin = UINT64_MAX;
    for (NSArray<SYTrack *> *segments in sources) {
        for (SYTrack *segment in segments) {
            if (segment.frames) origin = MIN(origin, segment.firstHostTime);
            if (segment.warning) *warning = segment.warning;
        }
    }
    if (origin == UINT64_MAX) return @"没有采集到音频。请检查音频设备及系统音频录制权限。";

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
            dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
            if (!audio) return loadError.localizedDescription ?: @"无法读取录音片段。";

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
                return error.localizedDescription ?: @"无法拼接录音片段。";
            }
            end = CMTimeAdd(at, range.duration);
        }
        if (track) {
            [parameters addObject:[AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track]];
        } else if (segments == system || withMic) {
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
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    return export.status == AVAssetExportSessionStatusCompleted ? nil : (export.error.localizedDescription ?: @"M4A 导出失败。");
}

@interface SYRecorder : NSObject {
    NSURL *_directory;
    dispatch_queue_t _control;
    dispatch_source_t _routeTimer;
    BOOL _withMic;
    BOOL _systemRunning;
    BOOL _micTapInstalled;
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
}
- (instancetype)initWithDirectory:(NSURL *)directory withMic:(BOOL)withMic;
- (NSString *)start;
- (NSDictionary *)snapshot;
- (NSString *)stopAndExport:(NSURL *)destination warning:(NSString **)warning;
@end

@implementation SYRecorder
- (instancetype)initWithDirectory:(NSURL *)directory withMic:(BOOL)withMic {
    if (!(self = [super init])) return nil;
    _directory = directory;
    _withMic = withMic;
    _control = dispatch_queue_create("local.bicord.routes", DISPATCH_QUEUE_SERIAL);
    _systemSegments = [NSMutableArray array];
    _micSegments = [NSMutableArray array];
    return self;
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
        @kAudioAggregateDeviceNameKey: @"bicord",
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
        return @"麦克风格式正在变化，请稍后重试。";
    }
    _micTapInstalled = YES;
    if (![engine startAndReturnError:&error]) return error.localizedDescription;
    _inputDevice = input;
    return nil;
}

- (void)finishTrack:(SYTrack *)track inSegments:(NSMutableArray<SYTrack *> *)segments {
    if (!track) return;
    [track finish];
    if (track.frames || track.warning) {
        [segments addObject:track];
    } else {
        [NSFileManager.defaultManager removeItemAtURL:track.url error:NULL];
    }
}

- (void)closeSystem {
    if (_systemRunning) AudioDeviceStop(_aggregate, _ioProc);
    if (_ioProc) AudioDeviceDestroyIOProcID(_aggregate, _ioProc);
    if (_aggregate) AudioHardwareDestroyAggregateDevice(_aggregate);
    if (_tap) AudioHardwareDestroyProcessTap(_tap);
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
    AudioObjectID output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectID input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice);
    AudioStreamBasicDescription format = {0};
    BOOL formatChanged = _systemRunning && tapFormat(_tap, &format) == noErr &&
        memcmp(&format, &_tapFormat, sizeof(format)) != 0;
    if (!_systemRunning || output != _outputDevice || formatChanged) {
        [self closeSystem];
        _systemIssue = [self startSystem:output];
        if (_systemIssue) [self closeSystem];
    }
    BOOL micFormatChanged = _engine.isRunning && ![[_engine.inputNode outputFormatForBus:0] isEqual:_mic.format];
    if (_withMic && (!_engine.isRunning || input != _inputDevice || micFormatChanged)) {
        [self closeMic];
        _micIssue = [self startMic:input];
        if (_micIssue) [self closeMic];
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
            dispatch_semaphore_wait(decision, DISPATCH_TIME_FOREVER);
            permission = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        }
        if (permission != AVAuthorizationStatusAuthorized) {
            return @"请在「系统设置 → 隐私与安全性 → 麦克风」允许bicord访问。";
        }
    }

    __block NSString *error = nil;
    dispatch_sync(_control, ^{
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
    return error;
}

- (NSDictionary *)snapshot {
    __block NSDictionary *result;
    dispatch_sync(_control, ^{
        result = @{
            @"systemLevel": @([self->_system level]),
            @"micLevel": @([self->_mic level]),
            @"outputName": deviceName(self->_outputDevice ?: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)),
            @"inputName": deviceName(self->_inputDevice ?: defaultDevice(kAudioHardwarePropertyDefaultInputDevice)),
            @"warning": self->_systemIssue ?: self->_micIssue ?: [self->_system warning] ?: [self->_mic warning] ?: NSNull.null
        };
    });
    return result;
}

- (NSString *)stopAndExport:(NSURL *)destination warning:(NSString **)warning {
    __block NSString *routeIssue;
    dispatch_sync(_control, ^{
        routeIssue = self->_systemIssue ?: self->_micIssue;
        if (self->_routeTimer) {
            dispatch_source_cancel(self->_routeTimer);
            self->_routeTimer = nil;
        }
        [self closeSystem];
        [self closeMic];
    });
    *warning = routeIssue;
    return exportSegments(_systemSegments, _micSegments, _withMic, destination, warning);
}
@end

void *sy_start(const char *directory, bool microphone, char **error) {
    @autoreleasepool {
        SYRecorder *recorder = [[SYRecorder alloc] initWithDirectory:
            [NSURL fileURLWithPath:[NSString stringWithUTF8String:directory] isDirectory:YES] withMic:microphone];
        NSString *issue = [recorder start];
        if (issue) {
            *error = strdup(issue.UTF8String);
            return NULL;
        }
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
