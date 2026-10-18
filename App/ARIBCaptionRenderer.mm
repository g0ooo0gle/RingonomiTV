#import "ARIBCaptionRenderer.h"

#include <aribcaption/aribcaption.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <new>

namespace {

constexpr std::size_t kMinimumPayloadSize = 3;
constexpr std::size_t kMaximumPayloadSize = 64 * 1024;
constexpr int kMaximumFrameWidth = 1920;
constexpr int kMaximumFrameHeight = 1080;
constexpr std::uint32_t kMaximumImagesPerStream = 8;
constexpr std::size_t kMaximumImageBytes = 16 * 1024 * 1024;
constexpr std::size_t kRendererStorageCount = 128;

void discardLog(aribcc_loglevel_t, const char *, void *) {
    // libaribcaption may include decoded text in diagnostic messages. The
    // product bridge deliberately keeps this callback silent.
}

struct NativeStream {
    aribcc_decoder_t *decoder = nullptr;
    aribcc_renderer_t *renderer = nullptr;
};

void freeStream(NativeStream &stream) noexcept {
    if (stream.renderer != nullptr) {
        aribcc_renderer_free(stream.renderer);
        stream.renderer = nullptr;
    }
    if (stream.decoder != nullptr) {
        aribcc_decoder_free(stream.decoder);
        stream.decoder = nullptr;
    }
}

template <typename T>
class CFHolder {
public:
    CFHolder() = default;
    explicit CFHolder(T value) : value_(value) {}
    CFHolder(const CFHolder &) = delete;
    CFHolder &operator=(const CFHolder &) = delete;
    ~CFHolder() {
        if (value_ != nullptr) {
            CFRelease(value_);
        }
    }

    T get() const { return value_; }
    explicit operator bool() const { return value_ != nullptr; }

private:
    T value_ = nullptr;
};

struct CaptionCleanup {
    aribcc_caption_t value{};
    bool active = false;

    ~CaptionCleanup() {
        if (active) {
            aribcc_caption_cleanup(&value);
        }
    }
};

struct RenderCleanup {
    aribcc_render_result_t value{};
    bool active = false;

    ~RenderCleanup() {
        if (active) {
            aribcc_render_result_cleanup(&value);
        }
    }
};

bool initializeStream(aribcc_context_t *context,
                      NativeStream &stream,
                      aribcc_captiontype_t captionType) {
    stream.decoder = aribcc_decoder_alloc(context);
    stream.renderer = aribcc_renderer_alloc(context);
    if (stream.decoder == nullptr || stream.renderer == nullptr) {
        return false;
    }

    if (!aribcc_decoder_initialize(stream.decoder,
                                   ARIBCC_ENCODING_SCHEME_ARIB_STD_B24_JIS,
                                   captionType,
                                   ARIBCC_PROFILE_A,
                                   ARIBCC_LANGUAGEID_FIRST)) {
        return false;
    }

#if defined(ARIBCC_USE_CORETEXT)
    constexpr aribcc_fontprovider_type_t fontProvider = ARIBCC_FONTPROVIDER_TYPE_CORETEXT;
    constexpr aribcc_textrenderer_type_t textRenderer = ARIBCC_TEXTRENDERER_TYPE_CORETEXT;
#else
    constexpr aribcc_fontprovider_type_t fontProvider = ARIBCC_FONTPROVIDER_TYPE_AUTO;
    constexpr aribcc_textrenderer_type_t textRenderer = ARIBCC_TEXTRENDERER_TYPE_AUTO;
#endif
    if (!aribcc_renderer_initialize(stream.renderer, captionType, fontProvider, textRenderer)) {
        return false;
    }

    // Keep the renderer bounded and preserve broadcaster-selected background,
    // colours, ruby, stroke, and DRCS instead of forcing a simplified style.
    aribcc_renderer_set_storage_policy(stream.renderer,
                                       ARIBCC_CAPTION_STORAGE_POLICY_UPPER_LIMIT_COUNT,
                                       kRendererStorageCount);
    aribcc_renderer_set_merge_region_images(stream.renderer, true);
    aribcc_renderer_set_replace_drcs(stream.renderer, false);
    aribcc_renderer_set_force_stroke_text(stream.renderer, false);
    aribcc_renderer_set_force_no_ruby(stream.renderer, false);
    aribcc_renderer_set_force_no_background(stream.renderer, false);

    // CoreText performs the final fallback selection. These families cover
    // Japanese tvOS installations while leaving language/style information to
    // the renderer rather than rasterising text in the bridge.
    const char *families[] = {
        "Hiragino Sans",
        "Hiragino Kaku Gothic ProN",
        "Hiragino Mincho ProN"
    };
    (void)aribcc_renderer_set_default_font_family(
        stream.renderer, families, sizeof(families) / sizeof(families[0]), false);
    (void)aribcc_renderer_set_language_specific_font_family(
        stream.renderer,
        ARIBCC_MAKE_LANG('j', 'p', 'n'),
        families,
        sizeof(families) / sizeof(families[0]));
    return true;
}

bool validPayload(NSData *payload, int64_t milliseconds) {
    if (payload == nil || milliseconds < 0) {
        return false;
    }
    const NSUInteger length = payload.length;
    if (length < kMinimumPayloadSize || length > kMaximumPayloadSize || payload.bytes == nullptr) {
        return false;
    }
    const auto *bytes = static_cast<const std::uint8_t *>(payload.bytes);
    return (bytes[0] == ARIBCC_CAPTIONTYPE_CAPTION ||
            bytes[0] == ARIBCC_CAPTIONTYPE_SUPERIMPOSE) &&
           bytes[1] == 0xff;
}

bool validFrameSize(NSInteger width, NSInteger height) {
    return width > 0 && height > 0 &&
           width <= kMaximumFrameWidth && height <= kMaximumFrameHeight;
}

bool validNativeImage(const aribcc_image_t &image, std::size_t &requiredBytes) {
    if (image.bitmap == nullptr || image.width <= 0 || image.height <= 0 || image.stride <= 0 ||
        image.pixel_format != ARIBCC_PIXELFORMAT_RGBA8888) {
        return false;
    }
    const std::uint64_t rowBytes = static_cast<std::uint64_t>(image.width) * 4u;
    if (rowBytes > std::numeric_limits<std::size_t>::max() ||
        static_cast<std::uint64_t>(image.stride) < rowBytes) {
        return false;
    }
    const std::uint64_t total = static_cast<std::uint64_t>(image.stride) *
                                static_cast<std::uint64_t>(image.height);
    if (total > std::numeric_limits<std::size_t>::max() ||
        total > image.bitmap_size ||
        total > kMaximumImageBytes) {
        return false;
    }
    requiredBytes = static_cast<std::size_t>(total);
    return requiredBytes != 0;
}

} // namespace

@interface RNGCaptionImage ()
- (nullable instancetype)initWithImage:(CGImageRef)image
                                     x:(NSInteger)x
                                     y:(NSInteger)y
                             canvasWidth:(NSInteger)canvasWidth
                            canvasHeight:(NSInteger)canvasHeight;
@end

@implementation RNGCaptionImage {
    CGImageRef _image;
    NSInteger _x;
    NSInteger _y;
    NSInteger _canvasWidth;
    NSInteger _canvasHeight;
}

- (instancetype)initWithImage:(CGImageRef)image
                             x:(NSInteger)x
                             y:(NSInteger)y
                     canvasWidth:(NSInteger)canvasWidth
                    canvasHeight:(NSInteger)canvasHeight {
    if (image == nullptr) {
        return nil;
    }
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _image = CGImageRetain(image);
    _x = x;
    _y = y;
    _canvasWidth = canvasWidth;
    _canvasHeight = canvasHeight;
    return self;
}

- (CGImageRef)image { return _image; }
- (NSInteger)x { return _x; }
- (NSInteger)y { return _y; }
- (NSInteger)canvasWidth { return _canvasWidth; }
- (NSInteger)canvasHeight { return _canvasHeight; }

- (void)dealloc {
    if (_image != nullptr) {
        CGImageRelease(_image);
        _image = nullptr;
    }
}

@end

@interface RNGCaptionRenderer ()
@end

@implementation RNGCaptionRenderer {
    aribcc_context_t *_context;
    NativeStream _captionStream;
    NativeStream _superimposeStream;
    BOOL _available;
    NSInteger _frameWidth;
    NSInteger _frameHeight;
    BOOL _captionHasRendered;
    BOOL _superimposeHasRendered;
    std::size_t _captionImageBytes;
    std::size_t _superimposeImageBytes;
    __strong NSMutableArray<RNGCaptionImage *> *_captionImages;
    __strong NSMutableArray<RNGCaptionImage *> *_superimposeImages;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _captionImages = [NSMutableArray array];
    _superimposeImages = [NSMutableArray array];
    _frameWidth = 0;
    _frameHeight = 0;
    _captionHasRendered = NO;
    _superimposeHasRendered = NO;
    _captionImageBytes = 0;
    _superimposeImageBytes = 0;

    @try {
        try {
            _context = aribcc_context_alloc();
            if (_context == nullptr) {
                return self;
            }
            aribcc_context_set_logcat_callback(_context, discardLog, nullptr);
            if (!initializeStream(_context, _captionStream, ARIBCC_CAPTIONTYPE_CAPTION) ||
                !initializeStream(_context, _superimposeStream, ARIBCC_CAPTIONTYPE_SUPERIMPOSE)) {
                [self releaseNativeState];
                return self;
            }
            _available = YES;
        } catch (const std::bad_alloc &) {
            [self releaseNativeState];
        } catch (const std::exception &) {
            [self releaseNativeState];
        } catch (...) {
            [self releaseNativeState];
        }
    } @catch (NSException *) {
        [self releaseNativeState];
    }
    return self;
}

- (BOOL)isAvailable {
    return _available;
}

- (void)releaseNativeState {
    _available = NO;
    freeStream(_superimposeStream);
    freeStream(_captionStream);
    if (_context != nullptr) {
        aribcc_context_free(_context);
        _context = nullptr;
    }
    _frameWidth = 0;
    _frameHeight = 0;
    _captionHasRendered = NO;
    _superimposeHasRendered = NO;
    [_captionImages removeAllObjects];
    [_superimposeImages removeAllObjects];
    _captionImageBytes = 0;
    _superimposeImageBytes = 0;
}

- (void)dealloc {
    [self releaseNativeState];
}

- (NSInteger)decodePayload:(NSData *)payload presentationTime:(int64_t)milliseconds {
    if (!_available || !validPayload(payload, milliseconds)) {
        return -1;
    }

    @try {
        try {
            const auto *bytes = static_cast<const std::uint8_t *>(payload.bytes);
            const auto type = static_cast<aribcc_captiontype_t>(bytes[0]);
            NativeStream &stream = type == ARIBCC_CAPTIONTYPE_SUPERIMPOSE
                ? _superimposeStream
                : _captionStream;

            CaptionCleanup decoded;
            const aribcc_decode_status_t status = aribcc_decoder_decode(
                stream.decoder,
                bytes,
                payload.length,
                milliseconds,
                &decoded.value);
            if (status == ARIBCC_DECODE_STATUS_ERROR) {
                return -1;
            }
            if (status == ARIBCC_DECODE_STATUS_NO_CAPTION) {
                return 0;
            }
            if (status != ARIBCC_DECODE_STATUS_GOT_CAPTION) {
                return -1;
            }
            decoded.active = true;
            if (!aribcc_renderer_append_caption(stream.renderer, &decoded.value)) {
                return -1;
            }
            return 1;
        } catch (const std::bad_alloc &) {
            return -1;
        } catch (const std::exception &) {
            return -1;
        } catch (...) {
            return -1;
        }
    } @catch (NSException *) {
        return -1;
    }
}

- (BOOL)setFrameSizeIfNeeded:(NSInteger)width height:(NSInteger)height {
    if (_frameWidth == width && _frameHeight == height) {
        return YES;
    }
    const bool captionOK = aribcc_renderer_set_frame_size(
        _captionStream.renderer, static_cast<int>(width), static_cast<int>(height));
    const bool superimposeOK = aribcc_renderer_set_frame_size(
        _superimposeStream.renderer, static_cast<int>(width), static_cast<int>(height));
    [_captionImages removeAllObjects];
    [_superimposeImages removeAllObjects];
    _captionImageBytes = 0;
    _superimposeImageBytes = 0;
    _captionHasRendered = NO;
    _superimposeHasRendered = NO;
    if (!captionOK || !superimposeOK) {
        _frameWidth = 0;
        _frameHeight = 0;
        return NO;
    }
    _frameWidth = width;
    _frameHeight = height;
    return YES;
}

- (nullable RNGCaptionImage *)imageFromNativeImage:(const aribcc_image_t &)nativeImage
                                               width:(NSInteger)canvasWidth
                                              height:(NSInteger)canvasHeight
                                        totalBytes:(std::size_t &)totalBytes {
    std::size_t requiredBytes = 0;
    if (!validNativeImage(nativeImage, requiredBytes) ||
        totalBytes > kMaximumImageBytes - requiredBytes) {
        return nil;
    }
    totalBytes += requiredBytes;

    CFHolder<CGColorSpaceRef> colorSpace(CGColorSpaceCreateDeviceRGB());
    if (!colorSpace) {
        return nil;
    }
    CFHolder<CFDataRef> data(CFDataCreate(
        kCFAllocatorDefault,
        nativeImage.bitmap,
        static_cast<CFIndex>(requiredBytes)));
    if (!data) {
        return nil;
    }
    CFHolder<CGDataProviderRef> provider(CGDataProviderCreateWithCFData(data.get()));
    if (!provider) {
        return nil;
    }

    const CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Big | kCGImageAlphaLast;
    CFHolder<CGImageRef> image(CGImageCreate(
        static_cast<size_t>(nativeImage.width),
        static_cast<size_t>(nativeImage.height),
        8,
        32,
        static_cast<size_t>(nativeImage.stride),
        colorSpace.get(),
        bitmapInfo,
        provider.get(),
        nullptr,
        false,
        kCGRenderingIntentDefault));
    if (!image) {
        return nil;
    }
    return [[RNGCaptionImage alloc] initWithImage:image.get()
                                                 x:nativeImage.dst_x
                                                 y:nativeImage.dst_y
                                         canvasWidth:canvasWidth
                                        canvasHeight:canvasHeight];
}

typedef NS_ENUM(NSInteger, RNGCaptionStreamUpdate) {
    RNGCaptionStreamUpdateUnchanged = 0,
    RNGCaptionStreamUpdateUpdated = 1,
    RNGCaptionStreamUpdateCleared = 2,
    RNGCaptionStreamUpdateError = 3,
};

- (RNGCaptionStreamUpdate)updateStream:(NativeStream &)stream
                                  cache:(NSMutableArray<RNGCaptionImage *> *)cache
                           hasRendered:(BOOL *)hasRendered
                           cachedBytes:(std::size_t *)cachedBytes
                                    at:(int64_t)milliseconds
                                  width:(NSInteger)width
                                 height:(NSInteger)height {
    const aribcc_render_status_t expected = aribcc_renderer_try_render(
        stream.renderer, milliseconds);
    if (expected == ARIBCC_RENDER_STATUS_ERROR) {
        return RNGCaptionStreamUpdateError;
    }
    if (expected == ARIBCC_RENDER_STATUS_GOT_IMAGE_UNCHANGED && cache.count > 0) {
        return RNGCaptionStreamUpdateUnchanged;
    }
    if (expected == ARIBCC_RENDER_STATUS_NO_IMAGE && cache.count == 0 && *hasRendered) {
        return RNGCaptionStreamUpdateUnchanged;
    }

    RenderCleanup rendered;
    const aribcc_render_status_t status = aribcc_renderer_render(
        stream.renderer, milliseconds, &rendered.value);
    rendered.active = true;
    if (status == ARIBCC_RENDER_STATUS_ERROR) {
        return RNGCaptionStreamUpdateError;
    }
    if (status == ARIBCC_RENDER_STATUS_NO_IMAGE) {
        [cache removeAllObjects];
        *cachedBytes = 0;
        *hasRendered = YES;
        return RNGCaptionStreamUpdateCleared;
    }
    if (status != ARIBCC_RENDER_STATUS_GOT_IMAGE &&
        status != ARIBCC_RENDER_STATUS_GOT_IMAGE_UNCHANGED) {
        return RNGCaptionStreamUpdateError;
    }

    // An unchanged result normally includes the renderer's image array. If a
    // backend reports no array, keep a valid previous cache rather than
    // turning a transient no-copy result into a blank frame.
    if (status == ARIBCC_RENDER_STATUS_GOT_IMAGE_UNCHANGED &&
        rendered.value.image_count == 0 && cache.count > 0) {
        *hasRendered = YES;
        return RNGCaptionStreamUpdateUnchanged;
    }
    if (rendered.value.images == nullptr ||
        rendered.value.image_count > kMaximumImagesPerStream) {
        if (rendered.value.image_count == 0) {
            [cache removeAllObjects];
            *cachedBytes = 0;
            *hasRendered = YES;
        }
        return rendered.value.image_count == 0
            ? RNGCaptionStreamUpdateCleared
            : RNGCaptionStreamUpdateError;
    }

    NSMutableArray<RNGCaptionImage *> *newImages = [NSMutableArray arrayWithCapacity:rendered.value.image_count];
    std::size_t totalBytes = 0;
    for (std::uint32_t index = 0; index < rendered.value.image_count; ++index) {
        RNGCaptionImage *image = [self imageFromNativeImage:rendered.value.images[index]
                                                       width:width
                                                      height:height
                                                totalBytes:totalBytes];
        if (image == nil) {
            return RNGCaptionStreamUpdateError;
        }
        [newImages addObject:image];
    }
    if (newImages.count == 0) {
        [cache removeAllObjects];
        *cachedBytes = 0;
        *hasRendered = YES;
        return RNGCaptionStreamUpdateCleared;
    }
    [cache removeAllObjects];
    [cache addObjectsFromArray:newImages];
    *cachedBytes = totalBytes;
    *hasRendered = YES;
    return RNGCaptionStreamUpdateUpdated;
}

- (nullable NSArray<RNGCaptionImage *> *)renderAtTime:(int64_t)milliseconds
                                           frameWidth:(NSInteger)width
                                          frameHeight:(NSInteger)height {
    if (!_available || milliseconds < 0 || !validFrameSize(width, height)) {
        return @[];
    }

    @try {
        try {
            if (![self setFrameSizeIfNeeded:width height:height]) {
                return @[];
            }
            const RNGCaptionStreamUpdate captionUpdate = [self updateStream:_captionStream
                                                                       cache:_captionImages
                                                                hasRendered:&_captionHasRendered
                                                                cachedBytes:&_captionImageBytes
                                                                         at:milliseconds
                                                                       width:width
                                                                      height:height];
            const RNGCaptionStreamUpdate superimposeUpdate = [self updateStream:_superimposeStream
                                                                            cache:_superimposeImages
                                                                     hasRendered:&_superimposeHasRendered
                                                                     cachedBytes:&_superimposeImageBytes
                                                                              at:milliseconds
                                                                            width:width
                                                                           height:height];
            if (captionUpdate == RNGCaptionStreamUpdateError ||
                superimposeUpdate == RNGCaptionStreamUpdateError) {
                [self reset];
                return @[];
            }
            if (captionUpdate == RNGCaptionStreamUpdateUnchanged &&
                superimposeUpdate == RNGCaptionStreamUpdateUnchanged) {
                return nil;
            }

            const NSUInteger combinedCount = _captionImages.count + _superimposeImages.count;
            if (combinedCount > kMaximumImagesPerStream ||
                _captionImageBytes > kMaximumImageBytes ||
                _superimposeImageBytes > kMaximumImageBytes - _captionImageBytes) {
                [self reset];
                return @[];
            }
            if (combinedCount == 0) {
                return @[];
            }
            NSMutableArray<RNGCaptionImage *> *combined =
                [NSMutableArray arrayWithCapacity:combinedCount];
            [combined addObjectsFromArray:_captionImages];
            [combined addObjectsFromArray:_superimposeImages];
            return [combined copy];
        } catch (const std::bad_alloc &) {
            [self reset];
            return @[];
        } catch (const std::exception &) {
            [self reset];
            return @[];
        } catch (...) {
            [self reset];
            return @[];
        }
    } @catch (NSException *) {
        [self reset];
        return @[];
    }
}

- (void)reset {
    if (!_available) {
        [_captionImages removeAllObjects];
        [_superimposeImages removeAllObjects];
        return;
    }
    @try {
        try {
            aribcc_decoder_flush(_captionStream.decoder);
            aribcc_decoder_flush(_superimposeStream.decoder);
            aribcc_renderer_flush(_captionStream.renderer);
            aribcc_renderer_flush(_superimposeStream.renderer);
        } catch (...) {
            // The state is still made unusable for the current frame even if a
            // defensive C++ exception escapes a third-party C implementation.
        }
    } @catch (NSException *) {
        // Keep reset non-throwing for a player teardown or seek path.
    }
    [_captionImages removeAllObjects];
    [_superimposeImages removeAllObjects];
    _captionHasRendered = NO;
    _superimposeHasRendered = NO;
    _captionImageBytes = 0;
    _superimposeImageBytes = 0;
    _frameWidth = 0;
    _frameHeight = 0;
}

@end
