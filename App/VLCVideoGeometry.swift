import Foundation
import CoreGraphics
#if canImport(TVVLCKit)
@preconcurrency import TVVLCKit

/// `VLCMediaPlayer.videoSize` exposes coded pixel dimensions only. Broadcast
/// video can also carry a source sample-aspect-ratio (SAR), so keep the
/// validated SAR separate from the native pixel size used by the player.
struct RingonomiVLCVideoSampleAspectRatio: Equatable, Sendable {
    let numerator: Double
    let denominator: Double

    var multiplier: Double { numerator / denominator }
}

enum RingonomiVLCVideoGeometry {
    private struct VideoTrack {
        let id: Int?
        let width: Int
        let height: Int
        let sampleAspectRatio: RingonomiVLCVideoSampleAspectRatio?
    }

    /// This reads the track dictionaries only. Callers must obtain
    /// `tracksInformation` off the main actor because TVVLCKit may perform
    /// synchronous media parsing when that property is first accessed.
    static func sampleAspectRatio(
        from tracks: [Any],
        activeTrackID: Int?,
        codedSize: CGSize
    ) -> RingonomiVLCVideoSampleAspectRatio? {
        guard let codedWidth = Int(exactly: Double(codedSize.width.rounded())),
              let codedHeight = Int(exactly: Double(codedSize.height.rounded())),
              codedWidth > 0, codedHeight > 0 else { return nil }

        let videoTracks = tracks.compactMap { object -> VideoTrack? in
            guard let dictionary = object as? NSDictionary,
                  let type = dictionary[VLCMediaTracksInformationType] as? String,
                  type == VLCMediaTracksInformationTypeVideo,
                  let width = integerValue(dictionary[VLCMediaTracksInformationVideoWidth]),
                  let height = integerValue(dictionary[VLCMediaTracksInformationVideoHeight]),
                  width > 0, height > 0 else { return nil }

            let numerator = integerValue(dictionary[VLCMediaTracksInformationSourceAspectRatio])
            let denominator = integerValue(dictionary[VLCMediaTracksInformationSourceAspectRatioDenominator])
            let sar: RingonomiVLCVideoSampleAspectRatio?
            if let numerator, let denominator,
               numerator > 0, denominator > 0,
               numerator <= 100_000, denominator <= 100_000 {
                let ratio = Double(numerator) / Double(denominator)
                sar = ratio.isFinite && ratio > 0 && ratio <= 1_000
                    ? RingonomiVLCVideoSampleAspectRatio(
                        numerator: Double(numerator), denominator: Double(denominator))
                    : nil
            } else {
                sar = nil
            }

            return VideoTrack(
                id: integerValue(dictionary[VLCMediaTracksInformationId]),
                width: width,
                height: height,
                sampleAspectRatio: sar
            )
        }
        guard !videoTracks.isEmpty else { return nil }

        // `currentVideoTrackIndex` is the native track id. Prefer the exact
        // active track; never borrow SAR from another video stream just
        // because its dimensions happen to match.
        let selected: VideoTrack?
        if let activeTrackID,
           activeTrackID >= 0,
           let active = videoTracks.first(where: { $0.id == activeTrackID }) {
            selected = active
        } else {
            let sizeMatches = videoTracks.filter {
                $0.width == codedWidth && $0.height == codedHeight
            }
            if sizeMatches.count == 1 {
                selected = sizeMatches[0]
            } else if videoTracks.count == 1 {
                selected = videoTracks[0]
            } else {
                // Without a trustworthy active id, multiple tracks are
                // ambiguous. Raw pixel geometry is the safe fallback.
                selected = nil
            }
        }
        return selected?.sampleAspectRatio
    }

    static func fittedRect(
        in bounds: CGRect,
        codedSize: CGSize,
        sampleAspectRatio: RingonomiVLCVideoSampleAspectRatio?
    ) -> CGRect {
        guard codedSize.width.isFinite, codedSize.height.isFinite,
              codedSize.width > 0, codedSize.height > 0 else { return bounds }
        let multiplier = sampleAspectRatio?.multiplier ?? 1
        let displayWidth = codedSize.width * multiplier
        guard multiplier.isFinite, multiplier > 0,
              displayWidth.isFinite, displayWidth > 0 else { return bounds }
        let scale = min(bounds.width / displayWidth, bounds.height / codedSize.height)
        guard scale.isFinite, scale >= 0 else { return bounds }
        let fittedWidth = displayWidth * scale
        let fittedHeight = codedSize.height * scale
        guard fittedWidth.isFinite, fittedHeight.isFinite else { return bounds }
        return CGRect(x: (bounds.width - fittedWidth) / 2,
                      y: (bounds.height - fittedHeight) / 2,
                      width: fittedWidth,
                      height: fittedHeight)
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw.isFinite, raw.rounded() == raw else { return nil }
            return Int(exactly: raw)
        }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let string = value as? NSString { return Int(string as String) }
        return nil
    }
}
#endif
