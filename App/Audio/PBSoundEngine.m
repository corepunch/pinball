//
//  PBSoundEngine.m
//

#import "PBSoundEngine.h"
#import <AVFoundation/AVFoundation.h>

static const double kSampleRate = 44100.0;
static const NSInteger kVoices = 12;

typedef float (^PBSampleFunction)(double t, double *noiseState);

@implementation PBSoundEngine {
    AVAudioEngine *_engine;
    AVAudioFormat *_format;
    NSArray<AVAudioPlayerNode *> *_voices;
    NSDictionary<NSString *, AVAudioPCMBuffer *> *_buffers;
    NSInteger _nextVoice;
    BOOL _running, _enabled;
}

- (instancetype)init {
    if ((self = [super init])) {
        _enabled = YES;
        _engine = [AVAudioEngine new];
        _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kSampleRate channels:1];
        NSMutableArray *voices = [NSMutableArray array];
        for (NSInteger i = 0; i < kVoices; i++) {
            AVAudioPlayerNode *voice = [AVAudioPlayerNode new];
            [_engine attachNode:voice];
            [_engine connect:voice to:_engine.mainMixerNode format:_format];
            [voices addObject:voice];
        }
        _voices = voices;
        _buffers = [self synthesize];
    }
    return self;
}

- (void)setEnabled:(BOOL)enabled {
    @synchronized (self) {
        _enabled = enabled;
        _engine.mainMixerNode.outputVolume = enabled ? 1.0f : 0.0f;
    }
}

- (BOOL)isEnabled { @synchronized (self) { return _enabled; } }

- (void)start {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:NULL];
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];
    NSError *error;
    _running = [_engine startAndReturnError:&error];
    if (!_running) { NSLog(@"Audio unavailable: %@", error); return; }
    for (AVAudioPlayerNode *voice in _voices) [voice play];
}

#pragma mark - Synthesis

- (AVAudioPCMBuffer *)renderSeconds:(double)seconds gain:(float)gain function:(PBSampleFunction)function {
    AVAudioFrameCount frames = (AVAudioFrameCount)(seconds * kSampleRate);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_format frameCapacity:frames];
    buffer.frameLength = frames;
    float *out = buffer.floatChannelData[0];
    double noise = 0;
    for (AVAudioFrameCount i = 0; i < frames; i++) {
        out[i] = function((double)i / kSampleRate, &noise) * gain;
    }
    return buffer;
}

/// Filtered noise. Good for the mechanical clack that makes pinball sound physical.
static float PBNoise(double *state, double smoothing) {
    double white = (double)arc4random_uniform(20001) / 10000.0 - 1.0;
    *state += (white - *state) * smoothing;
    return (float)*state;
}

static float PBTone(double t, double frequency) { return (float)sin(2.0 * M_PI * frequency * t); }

/// A rising sequence of notes for fanfares.
- (AVAudioPCMBuffer *)arpeggio:(NSArray<NSNumber *> *)notes step:(double)step gain:(float)gain {
    double total = step * (double)notes.count + 0.3;
    return [self renderSeconds:total gain:gain function:^float(double t, double *n) {
        NSInteger index = MIN((NSInteger)(t / step), (NSInteger)notes.count - 1);
        double local = t - (double)index * step;
        double frequency = notes[(NSUInteger)index].doubleValue;
        double envelope = exp(-local * 6.0);
        return (float)(envelope * (0.6 * PBTone(t, frequency) + 0.3 * PBTone(t, frequency * 2.0) + 0.1 * PBTone(t, frequency * 3.0)));
    }];
}

- (NSDictionary<NSString *, AVAudioPCMBuffer *> *)synthesize {
    NSMutableDictionary *b = [NSMutableDictionary dictionary];
    b[@"flipperUp"] = [self renderSeconds:0.09 gain:0.8 function:^float(double t, double *n) {
        return (float)exp(-t * 60.0) * (0.7f * PBNoise(n, 0.5) + 0.5f * PBTone(t, 180.0));
    }];
    b[@"flipperDown"] = [self renderSeconds:0.06 gain:0.35 function:^float(double t, double *n) {
        return (float)exp(-t * 90.0) * PBNoise(n, 0.4);
    }];
    b[@"bumper"] = [self renderSeconds:0.18 gain:0.8 function:^float(double t, double *n) {
        double pitch = 150.0 + 240.0 * exp(-t * 40.0);
        return (float)exp(-t * 22.0) * (0.8f * PBTone(t, pitch) + 0.4f * PBNoise(n, 0.7) * (float)exp(-t * 60.0));
    }];
    b[@"sling"] = [self renderSeconds:0.12 gain:0.6 function:^float(double t, double *n) {
        return (float)exp(-t * 35.0) * (0.5f * PBTone(t, 240.0) + 0.6f * PBNoise(n, 0.6));
    }];
    b[@"target"] = [self renderSeconds:0.1 gain:0.5 function:^float(double t, double *n) {
        return (float)exp(-t * 45.0) * (0.6f * PBTone(t, 880.0) + 0.4f * PBNoise(n, 0.8));
    }];
    b[@"rollover"] = [self renderSeconds:0.09 gain:0.3 function:^float(double t, double *n) {
        return (float)exp(-t * 30.0) * PBTone(t, 1320.0);
    }];
    b[@"spinner"] = [self renderSeconds:0.03 gain:0.32 function:^float(double t, double *n) {
        return (float)exp(-t * 180.0) * (PBTone(t, 2400.0) + PBNoise(n, 0.8));
    }];
    b[@"wall"] = [self renderSeconds:0.05 gain:0.28 function:^float(double t, double *n) {
        return (float)exp(-t * 110.0) * (PBNoise(n, 0.35) + 0.5f * PBTone(t, 620.0));
    }];
    b[@"drain"] = [self renderSeconds:0.6 gain:0.5 function:^float(double t, double *n) {
        return (float)exp(-t * 4.0) * PBTone(t, 300.0 * exp(-t * 2.5));
    }];
    b[@"plunger"] = [self renderSeconds:0.16 gain:0.6 function:^float(double t, double *n) {
        return (float)exp(-t * 24.0) * (PBNoise(n, 0.25) + 0.4f * PBTone(t, 110.0));
    }];
    b[@"saucer"] = [self renderSeconds:0.22 gain:0.55 function:^float(double t, double *n) {
        return (float)exp(-t * 15.0) * (PBTone(t, 90.0) + 0.4f * PBNoise(n, 0.2));
    }];
    b[@"start"] = [self arpeggio:@[@392, @523, @659, @784] step:0.09 gain:0.42];
    b[@"jackpot"] = [self arpeggio:@[@523, @659, @784, @1047, @1319, @1568] step:0.075 gain:0.48];
    b[@"multiball"] = [self arpeggio:@[@262, @330, @392, @523, @392, @523, @659, @784, @1047] step:0.09 gain:0.48];
    b[@"extraBall"] = [self arpeggio:@[@784, @1047, @784, @1047, @1319] step:0.11 gain:0.45];
    b[@"ballSave"] = [self arpeggio:@[@659, @523] step:0.09 gain:0.35];
    b[@"tilt"] = [self arpeggio:@[@180, @150, @120] step:0.16 gain:0.55];
    b[@"gameOver"] = [self arpeggio:@[@523, @392, @330, @262] step:0.2 gain:0.42];
    return b;
}

#pragma mark - Playback

- (void)play:(NSString *)name volume:(float)volume {
    if (!_running) return;
    AVAudioPCMBuffer *buffer = _buffers[name];
    if (!buffer) return;
    AVAudioPlayerNode *voice = _voices[(NSUInteger)_nextVoice];
    _nextVoice = (_nextVoice + 1) % kVoices;
    voice.volume = volume;
    [voice scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferInterrupts completionHandler:nil];
}

- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {
    switch (event->kind) {
        case PBEventBumper: [self play:@"bumper" volume:1.0f]; break;
        case PBEventSling: [self play:@"sling" volume:1.0f]; break;
        case PBEventDropTarget:
        case PBEventStandup: [self play:@"target" volume:1.0f]; break;
        case PBEventRollover: [self play:@"rollover" volume:1.0f]; break;
        case PBEventSpinner: [self play:@"spinner" volume:1.0f]; break;
        case PBEventSaucerCapture:
        case PBEventSaucerEject:
        case PBEventKickback: [self play:@"saucer" volume:1.0f]; break;
        case PBEventDrain: [self play:@"drain" volume:1.0f]; break;
        case PBEventFlipperUp: [self play:@"flipperUp" volume:1.0f]; break;
        case PBEventFlipperDown: [self play:@"flipperDown" volume:1.0f]; break;
        case PBEventPlungerRelease: [self play:@"plunger" volume:MAX(0.3f, event->magnitude)]; break;
        case PBEventWallHit: [self play:@"wall" volume:MIN(1.0f, event->magnitude * 0.5f)]; break;
        default: break;
    }
}

- (void)game:(PBGame *)game flash:(NSString *)flasherIdentifier {}

- (void)game:(PBGame *)game fanfare:(NSString *)name { [self play:name volume:1.0f]; }

@end
