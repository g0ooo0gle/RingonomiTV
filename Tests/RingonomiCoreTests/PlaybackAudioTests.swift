import Foundation
import XCTest
@testable import RingonomiCore

final class PlaybackAudioTests: XCTestCase {
    func testFiltersDisabledTracksAndDuplicateEngineIdentifiers() {
        let source = UUID()
        let options = PlaybackAudioCatalog.options(sourceID: source, descriptors: [
            .init(trackID: -1, name: "Disabled"),
            .init(trackID: 204, name: "日本語"),
            .init(trackID: 204, name: "重複"),
            .init(trackID: 409, name: "English")
        ])
        XCTAssertEqual(options.map(\.name), ["日本語", "English"])
        XCTAssertEqual(options.map(\.id), ["\(source.uuidString):204", "\(source.uuidString):409"])
    }

    func testTrimsLabelsAndNumbersUnnamedTracksAfterFiltering() {
        let options = PlaybackAudioCatalog.options(sourceID: UUID(), descriptors: [
            .init(trackID: -1, name: "Disabled"),
            .init(trackID: 0, name: " \n "),
            .init(trackID: 1, name: nil),
            .init(trackID: 2, name: " 日本語 \n")
        ])
        XCTAssertEqual(options.map(\.name), ["音声 1", "音声 2", "日本語"])
        XCTAssertEqual(options.map(\.preferenceKey), [nil, nil, "日本語"])
        XCTAssertNil(PlaybackAudioCatalog.preferredID(named: "音声 2", in: options))
    }

    func testReloadCannotReuseMenuIdentifiersFromEarlierSource() {
        let descriptors = [PlaybackAudioDescriptor(trackID: 10, name: "日本語")]
        let old = PlaybackAudioCatalog.options(sourceID: UUID(), descriptors: descriptors)
        let latest = PlaybackAudioCatalog.options(sourceID: UUID(), descriptors: descriptors)
        XCTAssertNotEqual(old[0].id, latest[0].id)
        XCTAssertEqual(old[0].name, latest[0].name)
    }

    func testSameMediaEnumerationKeepsIdentifiersStable() {
        let source = UUID()
        let first = PlaybackAudioCatalog.options(sourceID: source, descriptors: [.init(trackID: 1, name: "日本語")])
        let parsed = PlaybackAudioCatalog.options(sourceID: source, descriptors: [
            .init(trackID: 1, name: "日本語"), .init(trackID: 2, name: "English")
        ])
        XCTAssertEqual(first[0], parsed[0])
    }

    func testRestoresPreferenceOnlyForUniqueMatchingLabel() {
        let options = [PlaybackAudioOption(id: "a", name: "日本語", preferenceKey: "日本語"),
                       .init(id: "b", name: "English", preferenceKey: "English")]
        XCTAssertEqual(PlaybackAudioCatalog.preferredID(named: "English", in: options), "b")
        XCTAssertNil(PlaybackAudioCatalog.preferredID(named: nil, in: options))
        XCTAssertNil(PlaybackAudioCatalog.preferredID(named: "別の音声", in: options))
        XCTAssertNil(PlaybackAudioCatalog.preferredID(named: "日本語", in: options + [.init(id: "c", name: "日本語", preferenceKey: "日本語")]))
    }

    func testPreferenceDistinguishesMissingAmbiguousAndUnrequestedChoices() {
        let options = [PlaybackAudioOption(id: "new:1", name: "日本語", preferenceKey: "日本語"),
                       .init(id: "new:2", name: "English", preferenceKey: "English")]
        XCTAssertEqual(PlaybackAudioCatalog.preferenceMatch(named: nil, in: options), .notRequested)
        XCTAssertEqual(PlaybackAudioCatalog.preferenceMatch(named: "English", in: options), .matched(id: "new:2"))
        XCTAssertEqual(PlaybackAudioCatalog.preferenceMatch(named: "別の音声", in: options), .missing)
        XCTAssertEqual(PlaybackAudioCatalog.preferenceMatch(named: "English", in: options + [
            .init(id: "new:3", name: "English", preferenceKey: "English")
        ]), .ambiguous)
    }

    func testEmptyCompletedCatalogReportsMissingOnlyForNamedPreference() {
        XCTAssertEqual(PlaybackAudioCatalog.preferenceMatch(named: "English", in: []), .missing)
        XCTAssertEqual(PlaybackAudioCatalog.preferenceMatch(named: nil, in: []), .notRequested)
        let unnamed = PlaybackAudioCatalog.options(sourceID: UUID(), descriptors: [.init(trackID: 1, name: nil)])
        XCTAssertEqual(PlaybackAudioCatalog.preferenceMatch(named: "音声 1", in: unnamed), .missing)
    }

    func testOnlyFailedRestorationProducesNotice() {
        XCTAssertNil(PlaybackAudioPreferenceMatch.notRequested.notice)
        XCTAssertNil(PlaybackAudioPreferenceMatch.matched(id: "new:2").notice)
        XCTAssertNotNil(PlaybackAudioPreferenceMatch.missing.notice)
        XCTAssertNotNil(PlaybackAudioPreferenceMatch.ambiguous.notice)
        XCTAssertNotEqual(PlaybackAudioPreferenceMatch.missing.notice, PlaybackAudioPreferenceMatch.ambiguous.notice)
    }

    func testRejectsOversizedTrackCatalogInsteadOfShowingPartialChoices() {
        let descriptors = (0..<PlaybackAudioCatalog.maximumTracks).map { PlaybackAudioDescriptor(trackID: $0, name: nil) }
        XCTAssertEqual(PlaybackAudioCatalog.options(sourceID: UUID(), descriptors: descriptors).count, PlaybackAudioCatalog.maximumTracks)
        XCTAssertTrue(PlaybackAudioCatalog.options(sourceID: UUID(), descriptors: descriptors + [.init(trackID: 1000, name: "extra")]).isEmpty)
    }
}
