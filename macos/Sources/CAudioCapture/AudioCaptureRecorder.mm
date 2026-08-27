#import "AudioCaptureRecorder.h"

#import <AudioToolbox/ExtendedAudioFile.h>
#include <atomic>
#include <memory>
#include <vector>

namespace {

AudioObjectPropertyAddress PropertyAddress(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
    AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) noexcept {
    return { selector, scope, element };
}

NSError *RecorderError(NSString *operation, OSStatus status) {
    return [NSError errorWithDomain:@"TranscribatorAudioCapture"
                               code:status
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (Core Audio: %d)", operation, status]
    }];
}

OSStatus RecorderIOProc(AudioObjectID,
                        const AudioTimeStamp *,
                        const AudioBufferList *inputData,
                        const AudioTimeStamp *,
                        AudioBufferList *,
                        const AudioTimeStamp *,
                        void *clientData) noexcept;

} // namespace

@interface AudioCaptureRecorder ()

@property(nonatomic) AudioObjectID deviceID;
@property(nonatomic) AudioDeviceIOProcID ioProcID;
@property(nonatomic, readwrite, getter=isRecording) BOOL recording;
@property(nonatomic, copy, readwrite) NSArray<NSURL *> *recordingURLs;
@property(nonatomic) std::shared_ptr<std::vector<AudioStreamBasicDescription>> inputFormats;
@property(nonatomic) std::shared_ptr<std::vector<ExtAudioFileRef>> files;

@end

@implementation AudioCaptureMuteState {
    std::atomic_bool _muted;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _muted.store(false, std::memory_order_relaxed);
    }
    return self;
}

- (BOOL)isMuted {
    return _muted.load(std::memory_order_relaxed);
}

- (void)setMuted:(BOOL)muted {
    _muted.store(muted, std::memory_order_relaxed);
}

@end

@implementation AudioCaptureRecorder

- (instancetype)init {
    self = [super init];
    if (self) {
        _deviceID = kAudioObjectUnknown;
        _ioProcID = nullptr;
        _recording = NO;
        _recordingURLs = @[];
        _inputFormats = std::make_shared<std::vector<AudioStreamBasicDescription>>();
        _files = std::make_shared<std::vector<ExtAudioFileRef>>();
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)startWithDeviceID:(AudioObjectID)deviceID
             directoryURL:(NSURL *)directoryURL
                    error:(NSError **)error {
    [self stop];

    self.deviceID = deviceID;
    if (![self catalogInputStreams:error]) {
        return NO;
    }
    if (![self createRecordingFilesAt:directoryURL error:error]) {
        return NO;
    }

    AudioDeviceIOProcID ioProcID = nullptr;
    OSStatus status = AudioDeviceCreateIOProcID(deviceID, RecorderIOProc, (__bridge void *)self, &ioProcID);
    if (status != kAudioHardwareNoError) {
        [self disposeFiles];
        if (error) *error = RecorderError(@"Не удалось создать обработчик записи", status);
        return NO;
    }

    self.ioProcID = ioProcID;
    status = AudioDeviceStart(deviceID, ioProcID);
    if (status != kAudioHardwareNoError) {
        AudioDeviceDestroyIOProcID(deviceID, ioProcID);
        self.ioProcID = nullptr;
        [self disposeFiles];
        if (error) *error = RecorderError(@"Не удалось запустить запись", status);
        return NO;
    }

    self.recording = YES;
    return YES;
}

- (NSArray<NSURL *> *)stop {
    if (self.ioProcID != nullptr && self.deviceID != kAudioObjectUnknown) {
        AudioDeviceStop(self.deviceID, self.ioProcID);
        AudioDeviceDestroyIOProcID(self.deviceID, self.ioProcID);
    }
    self.ioProcID = nullptr;
    self.recording = NO;
    [self disposeFiles];
    self.deviceID = kAudioObjectUnknown;
    return self.recordingURLs;
}

- (BOOL)catalogInputStreams:(NSError **)error {
    self.inputFormats->clear();

    auto address = PropertyAddress(kAudioDevicePropertyStreams);
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(self.deviceID, &address, 0, nullptr, &size);
    if (status != kAudioHardwareNoError) {
        if (error) *error = RecorderError(@"Не удалось получить аудиопотоки", status);
        return NO;
    }

    const size_t streamCount = size / sizeof(AudioObjectID);
    std::vector<AudioObjectID> streams(streamCount);
    status = AudioObjectGetPropertyData(self.deviceID, &address, 0, nullptr, &size, streams.data());
    if (status != kAudioHardwareNoError) {
        if (error) *error = RecorderError(@"Не удалось прочитать аудиопотоки", status);
        return NO;
    }

    for (AudioObjectID streamID : streams) {
        UInt32 direction = 0;
        address = PropertyAddress(kAudioStreamPropertyDirection);
        size = sizeof(direction);
        status = AudioObjectGetPropertyData(streamID, &address, 0, nullptr, &size, &direction);
        if (status != kAudioHardwareNoError || direction == 0) {
            continue;
        }

        AudioStreamBasicDescription format = {};
        address = PropertyAddress(kAudioStreamPropertyVirtualFormat);
        size = sizeof(format);
        status = AudioObjectGetPropertyData(streamID, &address, 0, nullptr, &size, &format);
        if (status == kAudioHardwareNoError) {
            self.inputFormats->push_back(format);
        }
    }

    if (self.inputFormats->empty()) {
        if (error) {
            *error = [NSError errorWithDomain:@"TranscribatorAudioCapture"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Aggregate Device не содержит входных аудиопотоков"}];
        }
        return NO;
    }
    return YES;
}

- (BOOL)createRecordingFilesAt:(NSURL *)directoryURL error:(NSError **)error {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    self.files->clear();

    for (size_t index = 0; index < self.inputFormats->size(); ++index) {
        NSURL *url = [directoryURL URLByAppendingPathComponent:
                      [NSString stringWithFormat:@"source-%02zu.caf", index]];
        AudioStreamBasicDescription format = self.inputFormats->at(index);
        ExtAudioFileRef file = nullptr;
        OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)url,
                                                    kAudioFileCAFType,
                                                    &format,
                                                    nullptr,
                                                    kAudioFileFlags_EraseFile,
                                                    &file);
        if (status != kAudioHardwareNoError) {
            [self disposeFiles];
            if (error) *error = RecorderError(@"Не удалось создать временный аудиофайл", status);
            return NO;
        }

        // Prime asynchronous writing before the real-time callback starts.
        ExtAudioFileWriteAsync(file, 0, nullptr);
        self.files->push_back(file);
        [urls addObject:url];
    }

    self.recordingURLs = urls;
    return YES;
}

- (void)disposeFiles {
    for (ExtAudioFileRef file : *self.files) {
        if (file) ExtAudioFileDispose(file);
    }
    self.files->clear();
}

@end

namespace {

OSStatus RecorderIOProc(AudioObjectID,
                        const AudioTimeStamp *,
                        const AudioBufferList *inputData,
                        const AudioTimeStamp *,
                        AudioBufferList *,
                        const AudioTimeStamp *,
                        void *clientData) noexcept {
    AudioCaptureRecorder *recorder = (__bridge AudioCaptureRecorder *)clientData;
    if (!recorder || !inputData) return kAudioHardwareNoError;

    auto files = recorder.files;
    auto formats = recorder.inputFormats;
    const UInt32 count = std::min<UInt32>(inputData->mNumberBuffers, static_cast<UInt32>(files->size()));

    for (UInt32 index = 0; index < count; ++index) {
        AudioBuffer buffer = inputData->mBuffers[index];
        if (!buffer.mData || buffer.mDataByteSize == 0) continue;

        const AudioStreamBasicDescription &format = formats->at(index);
        UInt32 bytesPerFrame = format.mBytesPerFrame;
        if (bytesPerFrame == 0) {
            bytesPerFrame = std::max<UInt32>(1, buffer.mNumberChannels) * sizeof(Float32);
        }
        const UInt32 frames = buffer.mDataByteSize / bytesPerFrame;
        if (frames == 0) continue;

        AudioBufferList writeData = {};
        writeData.mNumberBuffers = 1;
        writeData.mBuffers[0] = buffer;
        ExtAudioFileWriteAsync(files->at(index), frames, &writeData);
    }
    return kAudioHardwareNoError;
}

} // namespace
