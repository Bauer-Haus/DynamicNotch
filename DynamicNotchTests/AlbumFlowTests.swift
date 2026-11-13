//
//  AlbumFlowTests.swift
//  DynamicNotch
//
//  Album Flow: grouping the library into albums, the covers' layout, and an offscreen
//  render of the flow (ALBUMFLOW_SNAPSHOT=1 prints it as base64 JPEG).
//

import AppKit
import Metal
import QuartzCore
import Testing
@testable import DynamicNotch

@Suite("Album Flow")
@MainActor
struct AlbumFlowTests {
    private func song(_ id: UInt64, _ title: String, album: String, albumID: UInt64, artist: String,
                      albumArtist: String? = nil, disc: Int = 1, number: Int, year: Int = 2000,
                      compilation: Bool = false) -> LibrarySong {
        LibrarySong(persistentID: id, title: title, artist: artist, albumArtist: albumArtist, albumTitle: album,
                    albumID: albumID, isCompilation: compilation, disc: disc, number: number, duration: 200, year: year)
    }

    @Test func groupsSongsIntoAlbumsInOrder() {
        let albums = AlbumGrouping.albums(from: [
            song(1, "Two", album: "Abbey Road", albumID: 10, artist: "The Beatles", number: 2, year: 1969),
            song(2, "Intro", album: "Moon", albumID: 20, artist: "Air", number: 1),
            song(3, "One", album: "Abbey Road", albumID: 10, artist: "The Beatles", number: 1, year: 1969),
            song(4, "Disc Two", album: "Abbey Road", albumID: 10, artist: "The Beatles", disc: 2, number: 1, year: 1969),
            song(5, "Help", album: "Help!", albumID: 30, artist: "The Beatles", number: 1, year: 1965),
        ])
        // Air before Beatles ("The" ignored); the Beatles' albums by year.
        #expect(albums.map(\.title) == ["Moon", "Help!", "Abbey Road"])
        #expect(albums[2].tracks.map(\.title) == ["One", "Two", "Disc Two"])
    }

    @Test func albumArtist() {
        let compilation = AlbumGrouping.albums(from: [
            song(1, "A", album: "Hits", albumID: 1, artist: "X", number: 1, compilation: true),
            song(2, "B", album: "Hits", albumID: 1, artist: "Y", number: 2, compilation: true),
        ])
        #expect(compilation.first?.artist == "Various Artists")
        let set = AlbumGrouping.albums(from: [
            song(1, "A", album: "Duets", albumID: 2, artist: "X & Y", albumArtist: "X", number: 1),
        ])
        #expect(set.first?.artist == "X")
        let most = AlbumGrouping.albums(from: [
            song(1, "A", album: "Live", albumID: 3, artist: "Band", number: 1),
            song(2, "B", album: "Live", albumID: 3, artist: "Band feat. Z", number: 2),
            song(3, "C", album: "Live", albumID: 3, artist: "Band", number: 3),
        ])
        #expect(most.first?.artist == "Band")
    }

    @Test func layoutStacksFaceTheMiddle() {
        let layout = AlbumFlowLayout(size: CGSize(width: 1600, height: 1000))
        // The front cover faces the viewer.
        #expect(layout.placement(offset: 0) == .init(x: 0, z: 0, angle: 0))
        // The cover right of centre turns to face the middle: its outer edge nearer, so
        // drawn taller, and its front towards the viewer even at the screen's edge.
        let inner = layout.project(offset: 1, u: -0.5), outer = layout.project(offset: 1, u: 0.5)
        #expect(outer.scale > inner.scale)
        for d in [1, 4, 8] as [CGFloat] {
            let p = layout.placement(offset: d)
            let normal = (x: sin(p.angle), z: cos(p.angle))
            let toEye = (x: -p.x, z: layout.eyeDistance - p.z)
            #expect(normal.x * toEye.x + normal.z * toEye.z > 0, "cover \(d) shows its back")
        }
        // Stacks are evenly spaced and mirrored.
        let a = layout.placement(offset: 2).x - layout.placement(offset: 1).x
        let b = layout.placement(offset: 3).x - layout.placement(offset: 2).x
        #expect(abs(a - b) < 0.001 && abs(a - layout.spacing) < 0.001)
        #expect(layout.placement(offset: -2).x == -layout.placement(offset: 2).x)
    }

    private static func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 8, y: 40, width: 48, height: 8))
        return ctx.makeImage()!
    }

    /// Renders the view's layers offscreen, 3D and all, with Core Animation's renderer.
    private func render(_ view: AlbumFlowView, width: Int, height: Int) throws -> NSBitmapImageRep {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        let root = try #require(view.layer)
        root.frame = CGRect(x: 0, y: 0, width: width, height: height)
        // The renderer only sees changes committed after it's attached.
        renderer.layer = root
        renderer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        view.redraw()
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let sync = try #require(queue.makeCommandBuffer())
        sync.commit()
        sync.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: width * 4, bitsPerPixel: 32))
        // BGRA to RGBA, and the texture's first row is the bottom.
        for y in 0 ..< height {
            for x in 0 ..< width {
                let from = ((height - 1 - y) * width + x) * 4, to = (y * width + x) * 4
                rep.bitmapData![to] = bytes[from + 2]
                rep.bitmapData![to + 1] = bytes[from + 1]
                rep.bitmapData![to + 2] = bytes[from]
                rep.bitmapData![to + 3] = 255
            }
        }
        return rep
    }

    private func snapshot(_ name: String, _ rep: NSBitmapImageRep) {
        guard ProcessInfo.processInfo.environment["ALBUMFLOW_SNAPSHOT"] == "1",
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else { return }
        let text = jpeg.base64EncodedString()
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 800, limitedBy: text.endIndex) ?? text.endIndex
            print("SNAPSHOT \(name) \(text[start ..< end])")
            start = end
        }
    }

    /// Covers in a row of colours; the one right of centre red, so its shape can be measured.
    private func flow(at position: CGFloat, width: Int = 1200, height: Int = 700) throws -> (AlbumFlowView, NSBitmapImageRep) {
        let colours: [(CGFloat, CGFloat, CGFloat)] = [(0.2, 0.4, 0.9), (0.95, 0.7, 0.1), (0.2, 0.75, 0.4), (0.6, 0.3, 0.8)]
        var albums: [LibraryAlbum] = []
        var covers: [UInt64: CGImage] = [:]
        for i in 0 ..< 30 {
            let id = UInt64(i + 1)
            albums.append(LibraryAlbum(id: id, title: "Album \(i)", artist: "Artist", year: 2000, tracks: []))
            let c = colours[i % colours.count]
            covers[id] = i == 11 ? Self.solid(1, 0, 0) : Self.solid(c.0, c.1, c.2)
        }
        let model = AlbumFlowModel()
        model.show(albums, covers: covers, at: 10)
        model.setPosition(position)
        let view = AlbumFlowView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layout()
        view.redraw()
        return (view, try render(view, width: width, height: height))
    }

    /// Red pixels' vertical extent in column `x` (rows counted from the top).
    private func redHeight(_ rep: NSBitmapImageRep, x: Int) -> Int {
        var count = 0
        for y in 0 ..< rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if c.redComponent > 0.6, c.greenComponent < 0.25, c.blueComponent < 0.25 { count += 1 }
        }
        return count
    }

    @Test func rendersTheFlow() throws {
        let (_, rep) = try flow(at: 10)
        snapshot("centred", rep)
        // The red cover, right of centre: find its columns.
        let columns = (0 ..< rep.pixelsWide).filter { redHeight(rep, x: $0) > 10 }
        let first = try #require(columns.first), last = try #require(columns.last)
        #expect(first > rep.pixelsWide / 2, "red cover should be right of centre")
        // Facing the middle, its outer (right) edge nearer the viewer: taller there.
        let inner = redHeight(rep, x: first + 2), outer = redHeight(rep, x: last - 2)
        #expect(outer > inner, "inner \(inner), outer \(outer)")
        // The front cover (green) in the middle.
        let centre = rep.colorAt(x: rep.pixelsWide / 2, y: Int(Double(rep.pixelsHigh) * 0.44))
        #expect((centre?.greenComponent ?? 0) > 0.5 && (centre?.redComponent ?? 1) < 0.4, "front cover in the middle")
    }

    @Test func rendersMidMove() throws {
        let (_, rep) = try flow(at: 10.45)
        snapshot("moving", rep)
    }

    /// A white cover's reflection: 40% where it meets the cover, black at the bottom, and
    /// no brighter anywhere, edges included.
    @Test func reflectionFadesToBlack() throws {
        let white = Self.solid(1, 1, 1)
        let reflection = try #require(CoverLayer.reflectionImage(of: white))
        let rep = NSBitmapImageRep(cgImage: reflection)
        func brightness(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.brightnessComponent ?? -1 }
        let top = brightness(rep.pixelsWide / 2, 0), bottom = brightness(rep.pixelsWide / 2, rep.pixelsHigh - 1)
        #expect(abs(top - 0.4) < 0.06, "top \(top)")
        #expect(bottom < 0.02, "bottom \(bottom)")
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in [0, 1, rep.pixelsWide - 2, rep.pixelsWide - 1] {
                #expect(brightness(x, y) <= top + 0.02, "edge (\(x), \(y)) brighter than the top")
            }
        }
    }

    @Test func clickFindsTheCover() throws {
        let (view, _) = try flow(at: 10)
        let layout = view.layoutInfo
        #expect(view.album(at: layout.centre) == 10)
        // Just right of the front cover: the next one.
        let right = layout.project(offset: 1, u: 0)
        #expect(view.album(at: NSPoint(x: layout.centre.x + right.x, y: layout.centre.y)) == 11)
        // A stacked cover shows its outer part; its inner part is behind the next one in.
        let left = layout.project(offset: -3, u: -0.42)
        #expect(view.album(at: NSPoint(x: layout.centre.x + left.x, y: layout.centre.y)) == 7)
        // Below the covers (the reflections) isn't a cover.
        #expect(view.album(at: NSPoint(x: layout.centre.x, y: layout.centre.y - layout.side * 0.7)) == nil)
    }
}

@Suite("Album Flow follows the music")
@MainActor
struct AlbumFlowFollowTests {
    private func albums() -> [LibraryAlbum] {
        var albums: [LibraryAlbum] = []
        for i in 0 ..< 10 {
            let albumArtist: String = i == 4 ? "Various Artists" : "Artist \(i)"
            let songArtist: String = i == 4 ? "Guest" : "Artist \(i)"
            let track = LibraryTrack(persistentID: UInt64(100 + i), title: "Song", artist: songArtist,
                                     disc: 1, number: 1, duration: 200)
            albums.append(LibraryAlbum(id: UInt64(i + 1), title: "Album \(i)", artist: albumArtist, year: 2000, tracks: [track]))
        }
        return albums
    }

    private func song(_ title: String, _ artist: String, _ album: String) -> AlbumFlowModel.NowPlaying {
        .init(title: title, artist: artist, album: album)
    }

    @Test func findsTheAlbum() {
        let albums = albums()
        #expect(AlbumFlowModel.index(of: song("Song", "Artist 3", "Album 3"), in: albums) == 3)
        // A compilation: matched by one of its songs' artist.
        #expect(AlbumFlowModel.index(of: song("Song", "Guest", "Album 4"), in: albums) == 4)
        #expect(AlbumFlowModel.index(of: song("Other", "Nobody", "Not Here"), in: albums) == nil)
    }

    @Test func findsTheAlbumSpelledDifferently() {
        let single = LibraryAlbum(id: 50, title: "Life Is Good (feat. Drake) - Single", artist: "Future", year: 2020,
                                  tracks: [LibraryTrack(persistentID: 500, title: "Life Is Good (feat. Drake)", artist: "Future",
                                                        disc: 1, number: 1, duration: 237)])
        let albums = albums() + [single]
        // Now Playing without " - Single", in other case.
        #expect(AlbumFlowModel.index(of: song("Life Is Good (feat. Drake)", "Future", "life is good (feat. drake)"), in: albums) == 10)
        // No album name at all: found by the song and its artist.
        #expect(AlbumFlowModel.index(of: song("Life Is Good (feat. Drake)", "Future & Drake", ""), in: albums) == 10)
        // Accents.
        let accented = LibraryAlbum(id: 60, title: "Café", artist: "Zoë", year: 2001,
                                    tracks: [LibraryTrack(persistentID: 600, title: "Un", artist: "Zoë", disc: 1, number: 1, duration: 100)])
        #expect(AlbumFlowModel.index(of: song("Un", "Zoe", "Cafe"), in: albums + [accented]) == 11)
    }

    @Test func turnsToTheNewAlbum() {
        let model = AlbumFlowModel()
        model.show(albums(), covers: [:], at: 2)
        model.follow(song("Song", "Artist 7", "Album 7"))
        #expect(model.playingIndex == 7)
        #expect(model.target == 7)
        // A song not in the library: stays put.
        model.follow(song("Live", "Someone", "Radio"))
        #expect(model.playingIndex == nil && model.target == 7)
    }

    @Test func waitsWhileYouReadAnotherAlbumsSongs() {
        let model = AlbumFlowModel()
        model.show(albums(), covers: [:], at: 2)
        model.toggleFlip()
        model.follow(song("Song", "Artist 5", "Album 5"))
        #expect(model.playingIndex == 5)
        #expect(model.target == 2 && model.isFlipped)
    }
}
