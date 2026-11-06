import Foundation
import Testing
@testable import HomelabKit

// Fixes from the security review of 2026-11-06 (its probe tests, turned into real ones).

/// Leftovers: tokens of a deleted install, pictures of a removed server.
@MainActor @Suite(.serialized) struct LeftoverTests {
    @Test func firstLaunchWipesOrphanedTokens() throws {
        let tokens = MemoryTokenStore()
        let orphan = UUID()
        try tokens.setToken("left over", for: orphan)
        let (m, _, storage, _) = makeModel(tokens: tokens)
        #expect(tokens.count == 0)
        // Once there is a server list, a launch keeps the tokens.
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .token)
        try m.save(lab, token: "secret")
        _ = makeModel(storage: storage, tokens: tokens)
        #expect(tokens.token(for: lab.id) == "secret")
    }

    @Test func removingAServerRemovesItsPictures() async throws {
        let (m, _, storage, _) = makeModel()
        let lab = ServerConfig(name: "lab", kind: .companion, baseURL: labURL, auth: .identity)
        let other = ServerConfig(name: "other", kind: .companion, baseURL: URL(string: "https://other.example.ts.net")!,
                                 auth: .identity)
        try m.save(lab, token: nil)
        try m.save(other, token: nil)
        for s in [lab, other] {
            let dir = m.imageDirectory(s.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.img"))
        }
        #expect(m.imageDirectory(lab.id).path.hasPrefix(storage.url("images").path))
        m.remove(lab.id)
        #expect(!FileManager.default.fileExists(atPath: m.imageDirectory(lab.id).path))
        #expect(FileManager.default.fileExists(atPath: m.imageDirectory(other.id).path))
        // A new address for the same entry: its old pictures go too.
        var moved = other
        moved.baseURL = URL(string: "https://moved.example.ts.net")!
        try m.save(moved, token: nil)
        #expect(!FileManager.default.fileExists(atPath: m.imageDirectory(other.id).path))
    }

    @Test func sharedPicturesOfTheFirstVersionAreRemoved() throws {
        let storage = Storage(directory: temporaryDirectory())
        let images = storage.url("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: images.appendingPathComponent("abc.img"))
        _ = makeModel(storage: storage)
        #expect(!FileManager.default.fileExists(atPath: images.appendingPathComponent("abc.img").path))
    }
}
