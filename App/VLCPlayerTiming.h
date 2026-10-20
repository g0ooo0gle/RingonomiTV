#import <Foundation/Foundation.h>

@class VLCMediaPlayer;

/// Reads the active input duration in seconds; returns -1 when unavailable.
/// Call synchronously on the playback owner's serialized execution domain.
FOUNDATION_EXPORT double RNGVLCPlayerDurationSeconds(VLCMediaPlayer * _Nullable player);
