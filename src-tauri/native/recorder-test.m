#import "recorder.m"

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

int main(void) {
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
        NSString *error = exportSegments(@[system, systemNext], @[mic, micNext], YES, output, &warning);
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
        assert([NSFileManager.defaultManager removeItemAtURL:directory error:NULL]);
        puts("M4A mix preserved both sources before and after a device format change.");
    }
}
