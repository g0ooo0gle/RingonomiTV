#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// An immutable snapshot of one libaribcaption RGBA image.
///
/// The image is retained by this object, so callers may keep the snapshot after
/// the native renderer has released its temporary render result.
@interface RNGCaptionImage : NSObject

@property(nonatomic, readonly) CGImageRef image;
@property(nonatomic, readonly) NSInteger x;
@property(nonatomic, readonly) NSInteger y;
@property(nonatomic, readonly) NSInteger canvasWidth;
@property(nonatomic, readonly) NSInteger canvasHeight;

- (instancetype)init NS_UNAVAILABLE;

@end

/// Serial-use Objective-C++ bridge for the libaribcaption C API.
///
/// A caller must serialize decode, render, and reset on one queue. The bridge
/// itself never starts work asynchronously and never exposes decoder text.
@interface RNGCaptionRenderer : NSObject

@property(nonatomic, readonly, getter=isAvailable) BOOL available;

- (NSInteger)decodePayload:(NSData *)payload
         presentationTime:(int64_t)milliseconds
    NS_SWIFT_NAME(decode(payload:presentationTime:));

- (nullable NSArray<RNGCaptionImage *> *)renderAtTime:(int64_t)milliseconds
                                           frameWidth:(NSInteger)width
                                          frameHeight:(NSInteger)height
    NS_SWIFT_NAME(render(at:frameWidth:frameHeight:));

- (void)reset;

@end

NS_ASSUME_NONNULL_END
