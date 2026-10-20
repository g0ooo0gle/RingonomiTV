#import "VLCPlayerTiming.h"

#import <TVVLCKit/VLCMediaPlayer.h>
#import <TVVLCKit/vlc/libvlc.h>
#import <TVVLCKit/vlc/libvlc_media.h>
#import <TVVLCKit/vlc/libvlc_renderer_discoverer.h>
#import <TVVLCKit/vlc/libvlc_media_player.h>

// The pinned TVVLCKit framework declares this getter in its private bridging
// header. Keep that third-party dependency here and tolerate its absence in
// future versions. No Apple private API is used.
@interface VLCMediaPlayer (RNGNativePlayerTiming)
@property (nonatomic, readonly) void *libVLCMediaPlayer;
@end

double RNGVLCPlayerDurationSeconds(VLCMediaPlayer *player) {
    if (player == nil || ![player respondsToSelector:@selector(libVLCMediaPlayer)]) {
        return -1.0;
    }

    // The caller holds the player alive and serializes replacement/stop.
    // Never retain this borrowed pointer beyond the synchronous C call.
    void *nativePlayer = player.libVLCMediaPlayer;
    if (nativePlayer == nullptr) {
        return -1.0;
    }
    const libvlc_time_t milliseconds = libvlc_media_player_get_length(
        static_cast<libvlc_media_player_t *>(nativePlayer));
    return milliseconds > 0 ? static_cast<double>(milliseconds) / 1000.0 : -1.0;
}
