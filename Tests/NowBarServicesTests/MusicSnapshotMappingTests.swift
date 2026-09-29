import AppKit
import Foundation
import Testing
import NowBarCore
@testable import NowBarServices

@Suite struct MusicSnapshotMappingTests {
    let now = Date(timeIntervalSinceReferenceDate: 5_000)

    func fields(state: String? = "playing") -> MusicRawFields {
        MusicRawFields(state: state, trackID: "A1B2C3D4E5F60708", title: "Song", artist: "Artist", album: "Album",
                       duration: 215.5, position: 42.25, isFavorited: true)
    }

    func snapshot(_ raw: MusicRawFields) -> PlayerSnapshot {
        MusicSnapshotMapper.snapshot(from: raw, capturedAt: now)
    }

    let song = Track(id: "A1B2C3D4E5F60708", title: "Song", artist: "Artist", album: "Album", duration: 215.5, isFavorited: true)

    // MARK: States

    @Test func mapsAPlayingTrack() {
        #expect(snapshot(fields(state: "playing")) == PlayerSnapshot(availability: .running, state: .playing, track: song, position: 42.25, capturedAt: now))
    }

    @Test func mapsAPausedTrack() {
        #expect(snapshot(fields(state: "paused")) == PlayerSnapshot(availability: .running, state: .paused, track: song, position: 42.25, capturedAt: now))
    }

    @Test func fastForwardingAndRewindingCountAsPlaying() {
        #expect(snapshot(fields(state: "fast forwarding")).state == .playing)
        #expect(snapshot(fields(state: "rewinding")).state == .playing)
        #expect(snapshot(fields(state: "rewinding")).track == song)
    }

    @Test func stoppedHasNoTrackEvenIfFieldsArrive() {
        #expect(snapshot(fields(state: "stopped")) == PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0, capturedAt: now))
    }

    @Test func stoppedWithoutAnyTrackFields() {
        let result = snapshot(MusicRawFields(state: "stopped"))
        #expect(result.availability == .running)
        #expect(result.state == .stopped)
        #expect(result.track == nil)
        #expect(result.position == 0)
    }

    @Test func noCurrentTrackIsStoppedWhateverTheState() {
        for state in ["playing", "paused", "fast forwarding", "rewinding"] {
            let result = snapshot(MusicRawFields(state: state))
            #expect(result == PlayerSnapshot(availability: .running, state: .stopped, track: nil, position: 0, capturedAt: now), "\(state)")
        }
        // A stale position without a track is dropped too.
        #expect(snapshot(MusicRawFields(state: "playing", position: 30)).position == 0)
    }

    @Test func emptyTextAndNoIDMeansNoTrack() {
        let raw = MusicRawFields(state: "playing", trackID: "", title: "", artist: "", album: "", duration: 0, position: 3)
        #expect(snapshot(raw).track == nil)
        #expect(snapshot(raw).state == .stopped)
    }

    @Test func stateTextIsNormalised() {
        #expect(snapshot(fields(state: " Playing\n")).state == .playing)
        #expect(snapshot(fields(state: "PAUSED")).state == .paused)
        #expect(snapshot(fields(state: "Stopped")).track == nil)
        #expect(MusicSnapshotMapper.reportedState("Fast Forwarding") == .playing)
    }

    @Test func understandsEnumerationCodesToo() {
        #expect(MusicSnapshotMapper.reportedState("«constant ****kPSP»") == .playing)
        #expect(MusicSnapshotMapper.reportedState("«constant ****kPSp»") == .paused)
        #expect(MusicSnapshotMapper.reportedState("«constant ****kPSS»") == .stopped)
        #expect(MusicSnapshotMapper.reportedState("kPSF") == .playing)
        #expect(MusicSnapshotMapper.reportedState("kPSR") == .playing)
        #expect(snapshot(fields(state: "«constant ****kPSp»")).state == .paused)
    }

    @Test func unrecognisedStateNeverClaimsToBePlaying() {
        #expect(snapshot(fields(state: "buffering")).state == .paused)
        #expect(snapshot(fields(state: "buffering")).track == song)
        #expect(snapshot(fields(state: nil)).state == .paused)
        #expect(snapshot(MusicRawFields(state: "buffering")).state == .stopped)
        #expect(MusicSnapshotMapper.reportedState("") == .unrecognized)
    }

    // MARK: Missing and odd fields

    @Test func missingTextBecomesEmpty() {
        var raw = fields()
        raw.title = nil
        raw.artist = nil
        raw.album = nil
        let track = snapshot(raw).track
        #expect(track?.id == song.id)
        #expect(track?.title == "")
        #expect(track?.artist == "")
        #expect(track?.album == "")
    }

    @Test func missingDurationPositionAndFavoriteDefault() {
        var raw = fields()
        raw.duration = nil
        raw.position = nil
        raw.isFavorited = nil
        let result = snapshot(raw)
        #expect(result.state == .playing)
        #expect(result.track?.duration == 0)
        #expect(result.track?.isFavorited == false)
        #expect(result.position == 0)
    }

    @Test func impossibleNumbersBecomeZero() {
        for bad in [-5, Double.nan, .infinity, -.infinity] {
            var raw = fields()
            raw.duration = bad
            raw.position = bad
            let result = snapshot(raw)
            #expect(result.track?.duration == 0, "duration \(bad)")
            #expect(result.position == 0, "position \(bad)")
        }
    }

    @Test func keepsUnusualButValidNumbers() {
        var raw = fields()
        raw.duration = 0.5
        raw.position = 0
        #expect(snapshot(raw).track?.duration == 0.5)
        #expect(snapshot(raw).position == 0)
    }

    @Test func trackWithoutAPersistentIDStillShows() {
        var raw = fields()
        raw.trackID = nil
        let track = snapshot(raw).track
        #expect(track?.title == "Song")
        #expect(track?.id.isEmpty == false)
    }

    @Test func madeUpIDsFollowTheTrack() {
        var first = fields()
        first.trackID = nil
        var second = first
        second.position = 100
        var other = first
        other.title = "Another Song"
        #expect(snapshot(first).track?.id == snapshot(second).track?.id)
        #expect(snapshot(first).track?.id != snapshot(other).track?.id)
    }

    @Test func blankPersistentIDCountsAsMissing() {
        var raw = fields()
        raw.trackID = "  \n"
        #expect(snapshot(raw).track?.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        #expect(snapshot(raw).track?.id != "  \n")
    }

    @Test func trackWithOnlyAnIDStillShows() {
        let raw = MusicRawFields(state: "playing", trackID: "FFFF", duration: 100, position: 5)
        let result = snapshot(raw)
        #expect(result.state == .playing)
        #expect(result.track == Track(id: "FFFF", title: "", artist: "", album: "", duration: 100, isFavorited: false))
    }

    @Test func availabilityIsRunning() {
        #expect(snapshot(fields()).availability == .running)
        #expect(snapshot(MusicRawFields(state: "stopped")).availability == .running)
    }

    // MARK: Script results

    @Test func readsTheQueryList() {
        let value = ScriptValue.list([
            .text("playing"), .text("A1B2C3D4E5F60708"), .text("Song"), .text("Artist"), .text("Album"),
            .number(215.5), .number(42.25), .bool(true),
        ])
        #expect(MusicRawFields(value) == fields())
    }

    @Test func readsAListWithMissingValues() {
        let value = ScriptValue.list([.text("playing"), .null, .text("Live Radio"), .text(""), .null, .null, .number(12), .null])
        let raw = MusicRawFields(value)
        #expect(raw == MusicRawFields(state: "playing", trackID: nil, title: "Live Radio", artist: "", album: nil, duration: nil, position: 12, isFavorited: nil))
        #expect(raw.map(snapshot)?.track?.title == "Live Radio")
    }

    @Test func readsAShortList() {
        #expect(MusicRawFields(.list([.text("stopped")])) == MusicRawFields(state: "stopped"))
    }

    @Test func ignoresValuesOfTheWrongType() {
        let value = ScriptValue.list([.number(1), .number(2), .bool(true), .text("x"), .null, .text("1"), .bool(false), .text("yes")])
        #expect(MusicRawFields(value) == MusicRawFields(state: nil, trackID: nil, title: nil, artist: "x", album: nil, duration: nil, position: nil, isFavorited: nil))
    }

    @Test func nothingToReadMeansNotRunning() {
        #expect(MusicRawFields(.null) == nil)
        #expect(MusicRawFields(.list([])) == nil)
        #expect(MusicRawFields(.text("playing")) == nil)
        #expect(MusicRawFields(.data(Data([1]))) == nil)
    }

    // MARK: Descriptors

    @Test func convertsDescriptorsByType() {
        let list = NSAppleEventDescriptor.list()
        let items: [NSAppleEventDescriptor] = [
            NSAppleEventDescriptor(string: "Café"),
            NSAppleEventDescriptor(double: 215.5),
            NSAppleEventDescriptor(int32: 7),
            NSAppleEventDescriptor(boolean: true),
            NSAppleEventDescriptor(boolean: false),
            NSAppleEventDescriptor.null(),
            NSAppleEventDescriptor(typeCode: fourCharCode("msng")), // `missing value` inside a list
            NSAppleEventDescriptor(descriptorType: fourCharCode("tdta"), data: Data([0xFF, 0xD8, 0xFF]))!,
        ]
        for (offset, item) in items.enumerated() { list.insert(item, at: offset + 1) }

        #expect(ScriptValue(list) == .list([
            .text("Café"), .number(215.5), .number(7), .bool(true), .bool(false), .null, .null, .data(Data([0xFF, 0xD8, 0xFF])),
        ]))
    }

    @Test func numbersStayNumbers() {
        // A real must arrive as a real, whatever the locale's decimal separator.
        #expect(ScriptValue(NSAppleEventDescriptor(double: 0.001)) == .number(0.001))
        #expect(ScriptValue(NSAppleEventDescriptor(double: 12345.678)) == .number(12345.678))
    }

    @Test func convertsNestedAndEmptyLists() {
        let inner = NSAppleEventDescriptor.list()
        inner.insert(NSAppleEventDescriptor(int32: 1), at: 1)
        let outer = NSAppleEventDescriptor.list()
        outer.insert(inner, at: 1)
        outer.insert(NSAppleEventDescriptor.list(), at: 2)
        #expect(ScriptValue(outer) == .list([.list([.number(1)]), .list([])]))
    }
}

@Suite struct ArtworkCacheTests {
    func bytes(_ value: UInt8) -> Data { Data([value]) }

    @Test func returnsWhatWasStored() {
        var cache = ArtworkCache(capacity: 8)
        cache.store(bytes(1), for: "a")
        #expect(cache.data(for: "a") == bytes(1))
        #expect(cache.data(for: "b") == nil)
    }

    @Test func evictsTheLeastRecentlyUsed() {
        var cache = ArtworkCache(capacity: 3)
        for (index, id) in ["a", "b", "c"].enumerated() { cache.store(bytes(UInt8(index)), for: id) }
        _ = cache.data(for: "a") // a is now the most recently used
        cache.store(bytes(9), for: "d")
        #expect(cache.count == 3)
        #expect(cache.data(for: "b") == nil)
        #expect(cache.data(for: "a") == bytes(0))
        #expect(cache.data(for: "c") == bytes(2))
        #expect(cache.data(for: "d") == bytes(9))
    }

    @Test func keepsTheLastEightByDefaultSize() {
        var cache = ArtworkCache(capacity: 8)
        for index in 0..<12 { cache.store(bytes(UInt8(index)), for: "track\(index)") }
        #expect(cache.count == 8)
        #expect(cache.data(for: "track3") == nil)
        #expect(cache.data(for: "track4") != nil)
        #expect(cache.data(for: "track11") != nil)
    }

    @Test func storingAgainReplacesWithoutGrowing() {
        var cache = ArtworkCache(capacity: 2)
        cache.store(bytes(1), for: "a")
        cache.store(bytes(2), for: "a")
        #expect(cache.count == 1)
        #expect(cache.data(for: "a") == bytes(2))
    }

    @Test func capacityIsAtLeastOne() {
        var cache = ArtworkCache(capacity: 0)
        cache.store(bytes(1), for: "a")
        #expect(cache.data(for: "a") == bytes(1))
    }
}

@Suite struct ArtworkImageTests {
    func imageData(_ type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: type, properties: [:])!
    }

    @Test func acceptsRealImages() {
        #expect(ArtworkImage.isDecodable(imageData(.png)))
        #expect(ArtworkImage.isDecodable(imageData(.jpeg)))
        #expect(ArtworkImage.isDecodable(imageData(.tiff)))
    }

    @Test func rejectsEverythingElse() {
        #expect(!ArtworkImage.isDecodable(Data()))
        #expect(!ArtworkImage.isDecodable(Data([1, 2, 3, 4, 5, 6, 7, 8])))
        #expect(!ArtworkImage.isDecodable(Data("not an image".utf8)))
        // NSImage(data:) accepts a truncated file; the artwork must not.
        #expect(!ArtworkImage.isDecodable(imageData(.png).prefix(20)))
    }
}
