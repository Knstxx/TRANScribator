#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Real-time-safe recorder for every input stream exposed by an aggregate device.
///
/// The implementation follows Apple's Core Audio taps sample and writes one CAF
/// per input stream. Swift later combines these system-audio streams with the
/// independently captured microphone track.
@interface AudioCaptureRecorder : NSObject

@property(nonatomic, readonly, getter=isRecording) BOOL recording;
@property(nonatomic, copy, readonly) NSArray<NSURL *> *recordingURLs;

- (BOOL)startWithDeviceID:(AudioObjectID)deviceID
             directoryURL:(NSURL *)directoryURL
                    error:(NSError * _Nullable * _Nullable)error;

- (NSArray<NSURL *> *)stop;

@end

/// Lock-free flag shared with the real-time microphone callback.
@interface AudioCaptureMuteState : NSObject

@property(nonatomic, getter=isMuted) BOOL muted;

@end

NS_ASSUME_NONNULL_END
