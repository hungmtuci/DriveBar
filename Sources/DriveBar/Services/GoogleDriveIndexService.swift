import Foundation
import AppKit
import CoreServices
import Darwin
import os

struct DriveAccountMount: Identifiable, Equatable, Sendable {
    var id: String { email }
    let email: String
    let rootPath: String
    let myDrivePath: String?
    let sharedDrivesPath: String?
    let shortcutTargetsPath: String?
}

struct InstalledAppEntry: Sendable {
    let nameEN: String
    let nameVI: String
    var name: String { L(nameVI, nameEN) }
    let path: String
    let bundleIdentifier: String
    let cleanFull: String
    let cleanFullVI: String
    let acronym: String
    let acronymVI: String
    let words: [String]
    let aliasWords: [String]
    let isNestedHelper: Bool
}

// MARK: - Compact Packed Binary Index Representation (DBIX v1, §5.2)

enum BinaryIndexCodec {
    @inline(__always)
    nonisolated static func writeU16LE(_ ptr: UnsafeMutablePointer<UInt8>, _ offset: Int, _ val: Int) {
        let u = UInt16(clamping: max(0, val))
        ptr[offset] = UInt8(truncatingIfNeeded: u)
        ptr[offset &+ 1] = UInt8(truncatingIfNeeded: u >> 8)
    }

    @inline(__always)
    nonisolated static func writeU32LE(_ ptr: UnsafeMutablePointer<UInt8>, _ offset: Int, _ val: Int) {
        let u = UInt32(clamping: max(0, val))
        ptr[offset] = UInt8(truncatingIfNeeded: u)
        ptr[offset &+ 1] = UInt8(truncatingIfNeeded: u >> 8)
        ptr[offset &+ 2] = UInt8(truncatingIfNeeded: u >> 16)
        ptr[offset &+ 3] = UInt8(truncatingIfNeeded: u >> 24)
    }

    @inline(__always)
    nonisolated static func appendU16LE(_ data: inout Data, _ val: Int) {
        let u = UInt16(clamping: max(0, val))
        let b0 = UInt8(truncatingIfNeeded: u)
        let b1 = UInt8(truncatingIfNeeded: u >> 8)
        data.append(b0)
        data.append(b1)
    }

    @inline(__always)
    nonisolated static func appendU32LE(_ data: inout Data, _ val: Int) {
        let u = UInt32(clamping: max(0, val))
        var le = u.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    @inline(__always)
    nonisolated static func appendU64LE(_ data: inout Data, _ val: UInt64) {
        var le = val.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    @inline(__always)
    nonisolated static func readU16LE(_ base: UnsafePointer<UInt8>, _ offset: Int) -> Int {
        Int(base[offset]) | (Int(base[offset &+ 1]) << 8)
    }

    @inline(__always)
    nonisolated static func readU32LE(_ base: UnsafePointer<UInt8>, _ offset: Int) -> Int {
        Int(base[offset])
            | (Int(base[offset &+ 1]) << 8)
            | (Int(base[offset &+ 2]) << 16)
            | (Int(base[offset &+ 3]) << 24)
    }

    @inline(__always)
    nonisolated static func readU64LE(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
        var out: UInt64 = 0
        for i in 0..<8 {
            out |= UInt64(base[offset &+ i]) << (i &* 8)
        }
        return out
    }

    @inline(__always)
    nonisolated static func compareSliceToBytes(
        _ base: UnsafePointer<UInt8>,
        _ sliceOffset: Int,
        _ sliceLen: Int,
        _ target: [UInt8]
    ) -> Int {
        let tLen = target.count
        let minLen = sliceLen < tLen ? sliceLen : tLen
        var i = 0
        while i < minLen {
            let a = Int(base[sliceOffset &+ i])
            let b = Int(target[i])
            if a != b { return a &- b }
            i &+= 1
        }
        return sliceLen &- tLen
    }

    @inline(__always)
    nonisolated static func sliceHasPrefix(
        _ base: UnsafePointer<UInt8>,
        _ sliceOffset: Int,
        _ sliceLen: Int,
        _ prefix: [UInt8]
    ) -> Bool {
        let pLen = prefix.count
        if sliceLen < pLen { return false }
        var i = 0
        while i < pLen {
            if base[sliceOffset &+ i] != prefix[i] { return false }
            i &+= 1
        }
        return true
    }

    @inline(__always)
    nonisolated static func decodeUTF8(_ base: UnsafePointer<UInt8>, _ offset: Int, _ len: Int) -> String {
        if len <= 0 { return "" }
        return String(decoding: UnsafeBufferPointer(start: base.advanced(by: offset), count: len), as: UTF8.self)
    }
}

struct FastFolderIndex: Sendable {
    let blob: Data
    let count: Int

    var isEmpty: Bool { count == 0 }
    static let empty = FastFolderIndex(blob: Data([0, 0, 0, 0]), count: 0)

    nonisolated static func build(from entries: [DriveFolderEntry]) -> FastFolderIndex {
        if entries.isEmpty { return .empty }
        let sorted = entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        let n = sorted.count
        let headerBytes = 4 &+ n &* 4
        var out = Data(count: headerBytes)
        out.reserveCapacity(headerBytes &+ n &* 96)
        var offsets = [Int](repeating: 0, count: n)

        for i in 0..<n {
            let e = sorted[i]
            offsets[i] = out.count
            let pUTF8 = e.path.utf8
            let pLen = min(65535, pUTF8.count)
            BinaryIndexCodec.appendU16LE(&out, pLen)
            out.append(contentsOf: pUTF8.prefix(pLen))

            let segCount = min(255, e.cleanSegs.count)
            out.append(UInt8(segCount))
            for s in 0..<segCount {
                let cUTF8 = e.cleanSegs[s].utf8
                let cLen = min(255, cUTF8.count)
                out.append(UInt8(cLen))
                out.append(contentsOf: cUTF8.prefix(cLen))

                let aStr = s < e.acrSegs.count ? e.acrSegs[s] : ""
                let aUTF8 = aStr.utf8
                let aLen = min(255, aUTF8.count)
                out.append(UInt8(aLen))
                out.append(contentsOf: aUTF8.prefix(aLen))
            }
        }

        out.withUnsafeMutableBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            BinaryIndexCodec.writeU32LE(ptr, 0, n)
            for i in 0..<n {
                BinaryIndexCodec.writeU32LE(ptr, 4 &+ i &* 4, offsets[i])
            }
        }
        return FastFolderIndex(blob: out, count: n)
    }

    nonisolated func indexOfPath(_ targetPath: String) -> Int? {
        guard count > 0 else { return nil }
        let targetBytes = Array(targetPath.utf8)
        return blob.withUnsafeBytes { rawBuf -> Int? in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var low = 0
            var high = count - 1
            while low <= high {
                let mid = (low &+ high) >> 1
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ mid &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let cmp = BinaryIndexCodec.compareSliceToBytes(base, recOff &+ 2, pLen, targetBytes)
                if cmp == 0 {
                    return mid
                } else if cmp < 0 {
                    low = mid &+ 1
                } else {
                    high = mid &- 1
                }
            }
            return nil
        }
    }

    nonisolated func containsPath(_ targetPath: String) -> Bool {
        indexOfPath(targetPath) != nil
    }

    nonisolated func path(at recIdx: Int) -> String {
        guard recIdx >= 0 && recIdx < count else { return "" }
        return blob.withUnsafeBytes { rawBuf -> String in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return "" }
            let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ recIdx &* 4)
            let pLen = BinaryIndexCodec.readU16LE(base, recOff)
            return BinaryIndexCodec.decodeUTF8(base, recOff &+ 2, pLen)
        }
    }

    nonisolated func children(ofParent parentPath: String) -> [String] {
        guard count > 0 else { return [] }
        let prefixBytes = Array((parentPath + "/").utf8)
        let prefixLen = prefixBytes.count
        return blob.withUnsafeBytes { rawBuf -> [String] in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
            var low = 0
            var high = count
            while low < high {
                let mid = (low &+ high) >> 1
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ mid &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                if BinaryIndexCodec.compareSliceToBytes(base, recOff &+ 2, pLen, prefixBytes) < 0 {
                    low = mid &+ 1
                } else {
                    high = mid
                }
            }

            var out: [String] = []
            var idx = low
            while idx < count {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ idx &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let pStart = recOff &+ 2
                if !BinaryIndexCodec.sliceHasPrefix(base, pStart, pLen, prefixBytes) {
                    break
                }
                // Check if direct child (no further '/' in remaining bytes)
                var hasNestedSlash = false
                var k = prefixLen
                while k < pLen {
                    if base[pStart &+ k] == 47 {
                        hasNestedSlash = true
                        break
                    }
                    k &+= 1
                }
                if !hasNestedSlash && pLen > prefixLen {
                    out.append(BinaryIndexCodec.decodeUTF8(base, pStart, pLen))
                }
                idx &+= 1
            }
            return out
        }
    }

    nonisolated func rootFolderPaths(excluding: Set<String>, limit: Int) -> [String] {
        guard count > 0 && limit > 0 else { return [] }
        return blob.withUnsafeBytes { rawBuf -> [String] in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
            var out: [String] = []
            for idx in 0..<count {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ idx &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let pStart = recOff &+ 2
                let segCount = Int(base[pStart &+ pLen])
                if segCount <= 1 {
                    let p = BinaryIndexCodec.decodeUTF8(base, pStart, pLen)
                    if !excluding.contains(p) {
                        out.append(p)
                        if out.count >= limit { break }
                    }
                }
            }
            return out
        }
    }

    nonisolated func decodeEntries() -> [DriveFolderEntry] {
        guard count > 0 else { return [] }
        return blob.withUnsafeBytes { rawBuf -> [DriveFolderEntry] in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
            var out: [DriveFolderEntry] = []
            out.reserveCapacity(count)
            for idx in 0..<count {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ idx &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let pStart = recOff &+ 2
                let path = BinaryIndexCodec.decodeUTF8(base, pStart, pLen)
                var pos = pStart &+ pLen
                let segCount = Int(base[pos])
                pos &+= 1
                var cleanSegs: [String] = []
                var acrSegs: [String] = []
                cleanSegs.reserveCapacity(segCount)
                acrSegs.reserveCapacity(segCount)
                for _ in 0..<segCount {
                    let cLen = Int(base[pos])
                    pos &+= 1
                    cleanSegs.append(BinaryIndexCodec.decodeUTF8(base, pos, cLen))
                    pos &+= cLen
                    let aLen = Int(base[pos])
                    pos &+= 1
                    acrSegs.append(BinaryIndexCodec.decodeUTF8(base, pos, aLen))
                    pos &+= aLen
                }
                out.append(DriveFolderEntry(path: path, cleanSegs: cleanSegs, acrSegs: acrSegs))
            }
            return out
        }
    }
}

struct FastSharedIndex: Sendable {
    let blob: Data
    let count: Int

    var isEmpty: Bool { count == 0 }
    static let empty = FastSharedIndex(blob: Data([0, 0, 0, 0]), count: 0)

    nonisolated static func build(from entries: [SharedDriveEntry]) -> FastSharedIndex {
        if entries.isEmpty { return .empty }
        let sorted = entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        let n = sorted.count
        let headerBytes = 4 &+ n &* 4
        var out = Data(count: headerBytes)
        out.reserveCapacity(headerBytes &+ n &* 128)
        var offsets = [Int](repeating: 0, count: n)

        for i in 0..<n {
            let e = sorted[i]
            offsets[i] = out.count
            let pUTF8 = e.path.utf8
            let pLen = min(65535, pUTF8.count)
            BinaryIndexCodec.appendU16LE(&out, pLen)
            out.append(contentsOf: pUTF8.prefix(pLen))

            out.append(e.isDir ? 1 : 0)

            let dUTF8 = e.displaySub.utf8
            let dLen = min(65535, dUTF8.count)
            BinaryIndexCodec.appendU16LE(&out, dLen)
            out.append(contentsOf: dUTF8.prefix(dLen))

            let segCount = min(255, e.cleanSegs.count)
            out.append(UInt8(segCount))
            for s in 0..<segCount {
                let cUTF8 = e.cleanSegs[s].utf8
                let cLen = min(255, cUTF8.count)
                out.append(UInt8(cLen))
                out.append(contentsOf: cUTF8.prefix(cLen))

                let aStr = s < e.acrSegs.count ? e.acrSegs[s] : ""
                let aUTF8 = aStr.utf8
                let aLen = min(255, aUTF8.count)
                out.append(UInt8(aLen))
                out.append(contentsOf: aUTF8.prefix(aLen))
            }
        }

        out.withUnsafeMutableBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            BinaryIndexCodec.writeU32LE(ptr, 0, n)
            for i in 0..<n {
                BinaryIndexCodec.writeU32LE(ptr, 4 &+ i &* 4, offsets[i])
            }
        }
        return FastSharedIndex(blob: out, count: n)
    }

    nonisolated func indexOfPath(_ targetPath: String) -> Int? {
        guard count > 0 else { return nil }
        let targetBytes = Array(targetPath.utf8)
        return blob.withUnsafeBytes { rawBuf -> Int? in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var low = 0
            var high = count - 1
            while low <= high {
                let mid = (low &+ high) >> 1
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ mid &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let cmp = BinaryIndexCodec.compareSliceToBytes(base, recOff &+ 2, pLen, targetBytes)
                if cmp == 0 {
                    return mid
                } else if cmp < 0 {
                    low = mid &+ 1
                } else {
                    high = mid &- 1
                }
            }
            return nil
        }
    }

    nonisolated func isDir(forPath targetPath: String) -> Bool? {
        guard let idx = indexOfPath(targetPath) else { return nil }
        return blob.withUnsafeBytes { rawBuf -> Bool? in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ idx &* 4)
            let pLen = BinaryIndexCodec.readU16LE(base, recOff)
            return base[recOff &+ 2 &+ pLen] != 0
        }
    }

    nonisolated func entry(at recIdx: Int) -> SharedDriveEntry {
        blob.withUnsafeBytes { rawBuf -> SharedDriveEntry in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  recIdx >= 0 && recIdx < count else {
                return SharedDriveEntry(path: "", isDir: false, displaySub: "", cleanSegs: [], acrSegs: [])
            }
            return Self.decodeSingleEntry(base: base, recOff: BinaryIndexCodec.readU32LE(base, 4 &+ recIdx &* 4))
        }
    }

    private nonisolated static func decodeSingleEntry(base: UnsafePointer<UInt8>, recOff: Int) -> SharedDriveEntry {
        let pLen = BinaryIndexCodec.readU16LE(base, recOff)
        let pStart = recOff &+ 2
        let path = BinaryIndexCodec.decodeUTF8(base, pStart, pLen)
        var pos = pStart &+ pLen
        let isDir = base[pos] != 0
        pos &+= 1
        let dLen = BinaryIndexCodec.readU16LE(base, pos)
        pos &+= 2
        let displaySub = BinaryIndexCodec.decodeUTF8(base, pos, dLen)
        pos &+= dLen
        let segCount = Int(base[pos])
        pos &+= 1
        var cleanSegs: [String] = []
        var acrSegs: [String] = []
        cleanSegs.reserveCapacity(segCount)
        acrSegs.reserveCapacity(segCount)
        for _ in 0..<segCount {
            let cLen = Int(base[pos])
            pos &+= 1
            cleanSegs.append(BinaryIndexCodec.decodeUTF8(base, pos, cLen))
            pos &+= cLen
            let aLen = Int(base[pos])
            pos &+= 1
            acrSegs.append(BinaryIndexCodec.decodeUTF8(base, pos, aLen))
            pos &+= aLen
        }
        return SharedDriveEntry(path: path, isDir: isDir, displaySub: displaySub, cleanSegs: cleanSegs, acrSegs: acrSegs)
    }

    nonisolated func children(ofParent parentPath: String) -> [(path: String, isDir: Bool)] {
        guard count > 0 else { return [] }
        let prefixBytes = Array((parentPath + "/").utf8)
        let prefixLen = prefixBytes.count
        return blob.withUnsafeBytes { rawBuf -> [(path: String, isDir: Bool)] in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
            var low = 0
            var high = count
            while low < high {
                let mid = (low &+ high) >> 1
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ mid &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                if BinaryIndexCodec.compareSliceToBytes(base, recOff &+ 2, pLen, prefixBytes) < 0 {
                    low = mid &+ 1
                } else {
                    high = mid
                }
            }

            var out: [(path: String, isDir: Bool)] = []
            var idx = low
            while idx < count {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ idx &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let pStart = recOff &+ 2
                if !BinaryIndexCodec.sliceHasPrefix(base, pStart, pLen, prefixBytes) {
                    break
                }
                var hasNestedSlash = false
                var k = prefixLen
                while k < pLen {
                    if base[pStart &+ k] == 47 {
                        hasNestedSlash = true
                        break
                    }
                    k &+= 1
                }
                if !hasNestedSlash && pLen > prefixLen {
                    let isDir = base[pStart &+ pLen] != 0
                    out.append((BinaryIndexCodec.decodeUTF8(base, pStart, pLen), isDir))
                }
                idx &+= 1
            }
            return out
        }
    }

    nonisolated func prefixEntries(limit: Int) -> [SharedDriveEntry] {
        guard count > 0 && limit > 0 else { return [] }
        let take = min(limit, count)
        return blob.withUnsafeBytes { rawBuf -> [SharedDriveEntry] in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
            var out: [SharedDriveEntry] = []
            out.reserveCapacity(take)
            for idx in 0..<take {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ idx &* 4)
                out.append(Self.decodeSingleEntry(base: base, recOff: recOff))
            }
            return out
        }
    }

    nonisolated func decodeEntries() -> [SharedDriveEntry] {
        prefixEntries(limit: count)
    }
}

struct FastFileIndex: Sendable {
    let blob: Data
    let count: Int

    var isEmpty: Bool { count == 0 }
    static let empty = FastFileIndex(blob: Data([0, 0, 0, 0]), count: 0)

    nonisolated static func build(from entries: [DriveFileEntry]) -> FastFileIndex {
        if entries.isEmpty { return .empty }
        let sorted = entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        let n = sorted.count
        let headerBytes = 4 &+ n &* 4
        var out = Data(count: headerBytes)
        out.reserveCapacity(headerBytes &+ n &* 84)
        var offsets = [Int](repeating: 0, count: n)

        for i in 0..<n {
            let e = sorted[i]
            offsets[i] = out.count
            let pUTF8 = e.path.utf8
            let pLen = min(65535, pUTF8.count)
            BinaryIndexCodec.appendU16LE(&out, pLen)
            out.append(contentsOf: pUTF8.prefix(pLen))

            let extUTF8 = e.ext.utf8
            let extLen = min(255, extUTF8.count)
            out.append(UInt8(extLen))
            out.append(contentsOf: extUTF8.prefix(extLen))

            let cUTF8 = e.cleanName.utf8
            let cLen = min(255, cUTF8.count)
            out.append(UInt8(cLen))
            out.append(contentsOf: cUTF8.prefix(cLen))

            let aUTF8 = e.acronym.utf8
            let aLen = min(255, aUTF8.count)
            out.append(UInt8(aLen))
            out.append(contentsOf: aUTF8.prefix(aLen))

            let parUTF8 = e.cleanParent.utf8
            let parLen = min(255, parUTF8.count)
            out.append(UInt8(parLen))
            out.append(contentsOf: parUTF8.prefix(parLen))
        }

        out.withUnsafeMutableBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            BinaryIndexCodec.writeU32LE(ptr, 0, n)
            for i in 0..<n {
                BinaryIndexCodec.writeU32LE(ptr, 4 &+ i &* 4, offsets[i])
            }
        }
        return FastFileIndex(blob: out, count: n)
    }

    nonisolated func indexOfPath(_ targetPath: String) -> Int? {
        guard count > 0 else { return nil }
        let targetBytes = Array(targetPath.utf8)
        return blob.withUnsafeBytes { rawBuf -> Int? in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var low = 0
            var high = count - 1
            while low <= high {
                let mid = (low &+ high) >> 1
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ mid &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let cmp = BinaryIndexCodec.compareSliceToBytes(base, recOff &+ 2, pLen, targetBytes)
                if cmp == 0 {
                    return mid
                } else if cmp < 0 {
                    low = mid &+ 1
                } else {
                    high = mid &- 1
                }
            }
            return nil
        }
    }

    nonisolated func containsPath(_ targetPath: String) -> Bool {
        indexOfPath(targetPath) != nil
    }

    nonisolated func entry(at recIdx: Int) -> DriveFileEntry {
        blob.withUnsafeBytes { rawBuf -> DriveFileEntry in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  recIdx >= 0 && recIdx < count else {
                return DriveFileEntry(path: "", ext: "", cleanName: "", acronym: "", cleanParent: "")
            }
            return Self.decodeSingleFileEntry(base: base, recOff: BinaryIndexCodec.readU32LE(base, 4 &+ recIdx &* 4))
        }
    }

    private nonisolated static func decodeSingleFileEntry(base: UnsafePointer<UInt8>, recOff: Int) -> DriveFileEntry {
        let pLen = BinaryIndexCodec.readU16LE(base, recOff)
        var pos = recOff &+ 2
        let path = BinaryIndexCodec.decodeUTF8(base, pos, pLen)
        pos &+= pLen

        let extLen = Int(base[pos])
        pos &+= 1
        let ext = BinaryIndexCodec.decodeUTF8(base, pos, extLen)
        pos &+= extLen

        let cLen = Int(base[pos])
        pos &+= 1
        let cleanName = BinaryIndexCodec.decodeUTF8(base, pos, cLen)
        pos &+= cLen

        let aLen = Int(base[pos])
        pos &+= 1
        let acronym = BinaryIndexCodec.decodeUTF8(base, pos, aLen)
        pos &+= aLen

        let parLen = Int(base[pos])
        pos &+= 1
        let cleanParent = BinaryIndexCodec.decodeUTF8(base, pos, parLen)

        return DriveFileEntry(path: path, ext: ext, cleanName: cleanName, acronym: acronym, cleanParent: cleanParent)
    }

    nonisolated func prefixEntries(limit: Int) -> [DriveFileEntry] {
        guard count > 0 && limit > 0 else { return [] }
        let take = min(limit, count)
        return blob.withUnsafeBytes { rawBuf -> [DriveFileEntry] in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
            var out: [DriveFileEntry] = []
            out.reserveCapacity(take)
            for idx in 0..<take {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ idx &* 4)
                out.append(Self.decodeSingleFileEntry(base: base, recOff: recOff))
            }
            return out
        }
    }

    nonisolated func candidateFileURLs(matchingFilter filterTerm: String) -> [URL] {
        guard count > 0 else { return [] }
        return blob.withUnsafeBytes { rawBuf -> [URL] in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
            var out: [URL] = []
            for idx in 0..<count {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ idx &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let p = BinaryIndexCodec.decodeUTF8(base, recOff &+ 2, pLen)
                if filterTerm.isEmpty || p.localizedCaseInsensitiveContains(filterTerm) {
                    out.append(URL(fileURLWithPath: p))
                }
            }
            return out
        }
    }

    nonisolated func filterEntries(maxCount: Int, predicate: (DriveFileEntry) -> Bool) -> [DriveFileEntry] {
        guard count > 0 && maxCount > 0 else { return [] }
        return blob.withUnsafeBytes { rawBuf -> [DriveFileEntry] in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
            var out: [DriveFileEntry] = []
            for idx in 0..<count {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ idx &* 4)
                let entry = Self.decodeSingleFileEntry(base: base, recOff: recOff)
                if predicate(entry) {
                    out.append(entry)
                    if out.count >= maxCount { break }
                }
            }
            return out
        }
    }
}

@MainActor
final class GoogleDriveIndexService: ObservableObject {
    static let shared = GoogleDriveIndexService()

    @Published private(set) var availableAccounts: [DriveAccountMount] = []
    @Published private(set) var accountRoot: String?
    @Published private(set) var myDrivePath: String?
    @Published private(set) var sharedDrivesPath: String?
    @Published private(set) var shortcutTargetsPath: String?
    @Published private(set) var isRealtimeWatcherActive: Bool = false

    @Published private(set) var folderCount: Int = 0
    @Published private(set) var sharedCount: Int = 0
    @Published private(set) var fileCount: Int = 0
    @Published private(set) var macFolderItemCount: Int = 0
    @Published private(set) var isRebuildingFolders: Bool = false
    @Published private(set) var isRebuildingShared: Bool = false
    @Published private(set) var isRebuildingFiles: Bool = false
    @Published private(set) var isRebuildingMacFolders: Bool = false
    @Published private(set) var rebuildProgressText: String?
    @Published private(set) var lastCacheUpdate: Date?

    private var macFolderRootsSnapshot: [String] = []
    private(set) var fastFolderIndex: FastFolderIndex = .empty
    private(set) var fastSharedIndex: FastSharedIndex = .empty
    private(set) var fastFileIndex: FastFileIndex = .empty
    private(set) var fastMacFolderIndex: FastSharedIndex = .empty
    private var macFoldersRebuildGen: UInt64 = 0
    private(set) var history: [String: HistoryRecord] = [:]
    private(set) var queryHistory: [String: [String: QueryLatchRecord]] = [:]
    private(set) var installedApps: [InstalledAppEntry] = []
    private var lastAppScanUptime: TimeInterval = 0
    private var isScanningApps: Bool = false

    nonisolated(unsafe) private var driveFSStream: FSEventStreamRef?
    private var watcherGeneration: UInt64 = 0
    private let driveFSQueue = DispatchQueue(label: "com.hunglx.DriveBar.driveFSEvents", qos: .utility)
    private var pendingEventPaths = Set<String>()
    private var isProcessingFSEvents: Bool = false
    private var debounceTask: Task<Void, Never>?
    private var binaryCachePersistTask: Task<Void, Never>?
    private var alfredCompatPersistTask: Task<Void, Never>?
    nonisolated private static let fileWriteQueuesLock = OSAllocatedUnfairLock(initialState: [String: DispatchQueue]())

    private struct FolderPrefixRefineCache: Sendable {
        let queryKey: String
        let indexIdentityCount: Int
        let candidateIndices: [Int]
    }
    private struct FilePrefixRefineCache: Sendable {
        let queryKey: String
        let indexIdentityCount: Int
        let candidateIndices: [Int]
    }
    nonisolated private static let folderRefineLock = OSAllocatedUnfairLock(initialState: FolderPrefixRefineCache?.none)
    nonisolated private static let sharedRefineLock = OSAllocatedUnfairLock(initialState: FolderPrefixRefineCache?.none)
    nonisolated private static let fileRefineLock = OSAllocatedUnfairLock(initialState: FilePrefixRefineCache?.none)

    private let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    private var cacheDir: String { "\(homePath)/.config/alfred-scripts" }
    private var binaryCachePath: String { "\(cacheDir)/drivebar_index_v1.bin" }
    private var folderCachePath: String { "\(cacheDir)/folder_cache.json" }
    private var sharedCachePath: String { "\(cacheDir)/shared_cache.json" }
    private var fileCachePath: String { "\(cacheDir)/file_cache.json" }
    private var macFoldersCachePath: String { "\(cacheDir)/mac_folders_cache.json" }
    private var historyPath: String { "\(cacheDir)/folder_history.json" }
    private var queryHistoryPath: String { "\(cacheDir)/query_history.json" }

    nonisolated private static let skipExtensions: Set<String> = [
        "app", "photoslibrary", "xcodeproj", "xcworkspace",
        "bundle", "framework", "dsym", "git", "svn"
    ]

    private init() {
        refreshAccountPaths()
        loadInitialDataAsync()
    }

    var activeAccounts: [DriveAccountMount] {
        let filter = AppSettings.shared.selectedDriveAccountFilter
        if filter == "ALL" || filter.isEmpty {
            return availableAccounts
        }
        let filtered = availableAccounts.filter { $0.email == filter }
        return filtered.isEmpty ? availableAccounts : filtered
    }

    // MARK: - Multi-Account Path Detection

    func refreshAccountPaths() {
        let cloudStorage = "\(homePath)/Library/CloudStorage"
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: cloudStorage) else {
            availableAccounts = []
            accountRoot = nil
            myDrivePath = nil
            sharedDrivesPath = nil
            shortcutTargetsPath = nil
            stopRealtimeDriveWatcher()
            return
        }

        var discovered: [DriveAccountMount] = []
        for name in items.sorted() where name.hasPrefix("GoogleDrive-") && !name.contains("(") {
            let full = "\(cloudStorage)/\(name)"
            let email = String(name.dropFirst("GoogleDrive-".count))
            // Construct standard DriveFS mount subpaths without synchronous FileProvider open() on Main Thread
            let mount = DriveAccountMount(
                email: email,
                rootPath: full,
                myDrivePath: "\(full)/My Drive",
                sharedDrivesPath: "\(full)/Shared drives",
                shortcutTargetsPath: "\(full)/.shortcut-targets-by-id"
            )
            discovered.append(mount)
        }

        availableAccounts = discovered

        guard let primary = activeAccounts.first else {
            accountRoot = nil
            myDrivePath = nil
            sharedDrivesPath = nil
            shortcutTargetsPath = nil
            updateRealtimeWatcherState()
            return
        }

        accountRoot = primary.rootPath
        myDrivePath = primary.myDrivePath
        sharedDrivesPath = primary.sharedDrivesPath
        shortcutTargetsPath = primary.shortcutTargetsPath
        updateRealtimeWatcherState()
    }

    func applyAccountFilterChange() {
        refreshAccountPaths()
        rebuildAllCaches()
    }

    func isPathInGoogleDrive(_ path: String) -> Bool {
        if availableAccounts.contains(where: { path.hasPrefix($0.rootPath) }) {
            return true
        }
        return LocalFolderDriveSyncService.mappedDrivePath(forLocalPath: path) != nil
    }

    func isDirectGoogleDriveCloudStoragePath(_ path: String) -> Bool {
        availableAccounts.contains { path.hasPrefix($0.rootPath) }
    }

    func noteExternalDirectoryCreated(at path: String) {
        enqueueIncrementalFolderEvents([path])
    }

    func accountForPath(_ path: String) -> DriveAccountMount? {
        availableAccounts.first { path.hasPrefix($0.rootPath) }
    }

    // MARK: - Cloud Online-Only (Dataless) Detection

    nonisolated static func isCloudDatalessFile(_ url: URL) -> Bool {
        var st = Darwin.stat()
        if Darwin.lstat(url.path, &st) == 0 {
            // SF_DATALESS on macOS APFS CloudStorage = 0x40000000
            let sfDataless: UInt32 = 0x4000_0000
            if (st.st_flags & sfDataless) != 0 {
                return true
            }
        }
        if let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .ubiquitousItemDownloadingStatusKey]) {
            if let dlStatus = vals.ubiquitousItemDownloadingStatus, dlStatus == .notDownloaded {
                return true
            }
            if let fSize = vals.fileSize, let allocSize = vals.fileAllocatedSize,
               fSize > 4096, allocSize == 0 {
                return true
            }
        }
        return false
    }

    // MARK: - Real-time FSEvents Incremental Indexer

    func updateRealtimeWatcherState() {
        let hasCustomMac = !AppSettings.shared.customMacFolders.isEmpty
        if AppSettings.shared.enableRealtimeFSEvents, (!activeAccounts.isEmpty || hasCustomMac) {
            startRealtimeDriveWatcher()
        } else {
            stopRealtimeDriveWatcher()
        }
    }

    private func startRealtimeDriveWatcher() {
        var candidateRoots: [String] = []
        var seenRoots = Set<String>()
        for acc in activeAccounts {
            if let md = acc.myDrivePath, seenRoots.insert(md).inserted { candidateRoots.append(md) }
            if let sd = acc.sharedDrivesPath, seenRoots.insert(sd).inserted { candidateRoots.append(sd) }
        }
        let macRoots = AppSettings.shared.customMacFolders.map {
            $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0
        }
        for mr in macRoots where seenRoots.insert(mr).inserted {
            candidateRoots.append(mr)
        }
        guard !candidateRoots.isEmpty else {
            stopRealtimeDriveWatcher()
            return
        }

        watcherGeneration &+= 1
        let expectedGen = watcherGeneration
        let rootsSnapshot = candidateRoots
        let macRootsSet = macRoots
        let queue = driveFSQueue
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownDriveFSStreamOnQueue()

            let validPaths = rootsSnapshot.filter { FileManager.default.fileExists(atPath: $0) }
            guard !validPaths.isEmpty else {
                Task { @MainActor in
                    if GoogleDriveIndexService.shared.watcherGeneration == expectedGen {
                        GoogleDriveIndexService.shared.isRealtimeWatcherActive = false
                    }
                }
                return
            }
            let cfPaths = validPaths as CFArray

            let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPathsPtr, eventFlagsPtr, _ in
                guard numEvents > 0 else { return }
                let cfArray = unsafeBitCast(eventPathsPtr, to: CFArray.self)
                guard let paths = cfArray as? [String] else { return }

                var eventCandidates: [String] = []
                for i in 0..<min(numEvents, paths.count) {
                    let flags = eventFlagsPtr[i]
                    let cleanPath = paths[i].hasSuffix("/") && paths[i].count > 1
                        ? String(paths[i].dropLast())
                        : paths[i]
                    let isDirEvent = (flags & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0
                    let isMustScanSubDirs = (flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs)) != 0
                    let isLocalNonCloud = !cleanPath.contains("/Library/CloudStorage/")
                    if isDirEvent || isMustScanSubDirs || isLocalNonCloud {
                        eventCandidates.append(cleanPath)
                    }
                }
                guard !eventCandidates.isEmpty else { return }
                let capturedCandidates = eventCandidates
                _ = clientCallBackInfo

                Task { @MainActor in
                    GoogleDriveIndexService.shared.enqueueIncrementalFolderEvents(capturedCandidates)
                }
            }
            _ = macRootsSet

            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer
            )
            if let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                nil,
                cfPaths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.85,
                flags
            ) {
                FSEventStreamSetDispatchQueue(stream, queue)
                FSEventStreamStart(stream)
                self.driveFSStream = stream
                Task { @MainActor in
                    if GoogleDriveIndexService.shared.watcherGeneration == expectedGen {
                        GoogleDriveIndexService.shared.isRealtimeWatcherActive = true
                    }
                }
            }
        }
    }

    private func stopRealtimeDriveWatcher() {
        watcherGeneration &+= 1
        isRealtimeWatcherActive = false
        driveFSQueue.async { [weak self] in
            self?.teardownDriveFSStreamOnQueue()
        }
    }

    nonisolated private func teardownDriveFSStreamOnQueue() {
        if let stream = driveFSStream {
            driveFSStream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func enqueueIncrementalFolderEvents(_ paths: [String]) {
        for p in paths {
            let lastName = (p as NSString).lastPathComponent
            if !Self.shouldSkip(lastName) {
                pendingEventPaths.insert(p)
            }
        }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            self.processPendingFSEvents()
        }
    }

    private func processPendingFSEvents() {
        guard !pendingEventPaths.isEmpty,
              !isRebuildingFolders,
              !isRebuildingShared,
              !isRebuildingMacFolders,
              !isProcessingFSEvents else { return }

        isProcessingFSEvents = true
        let batch = Array(pendingEventPaths)
        pendingEventPaths.removeAll()

        let accountsSnap = activeAccounts
        let folderIdxSnap = fastFolderIndex
        let sharedIdxSnap = fastSharedIndex
        let macIdxSnap = fastMacFolderIndex
        let macRootsSnap = AppSettings.shared.customMacFolders.map {
            $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0
        }
        let homeSnap = homePath

        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var sortedFolders: [DriveFolderEntry]? = nil
            var sortedShared: [SharedDriveEntry]? = nil
            var sortedMac: [SharedDriveEntry]? = nil
            var didMutateFolders = false
            var didMutateShared = false
            var didMutateMac = false
            var shouldScheduleFullSharedRebuild = false

            for eventPath in batch {
                // 1. Check Custom Mac Folders incremental updates (files & subfolders)
                if let matchedMacRoot = macRootsSnap.first(where: { eventPath == $0 || eventPath.hasPrefix($0 + "/") }) {
                    if sortedMac == nil {
                        sortedMac = macIdxSnap.decodeEntries()
                    }
                    var isDirObj: ObjCBool = false
                    let exists = fm.fileExists(atPath: eventPath, isDirectory: &isDirObj)
                    if exists {
                        if isDirObj.boolValue {
                            var freshMac: [SharedDriveEntry] = []
                            Self.scanMacFolderSubtreePOSIX(
                                startDir: eventPath,
                                rootDir: matchedMacRoot,
                                homePath: homeSnap,
                                maxSubDepth: 3,
                                maxLimit: 5_000,
                                into: &freshMac
                            )
                            _ = Self.removePathAndDescendants(from: &sortedMac!, rootPath: eventPath, pathOf: \.path)
                            Self.upsertSortedEntries(into: &sortedMac!, newItems: freshMac, pathOf: \.path)
                            didMutateMac = true
                        } else if let fileEntry = Self.makeSingleMacEntry(path: eventPath, isDir: false, rootDir: matchedMacRoot, homePath: homeSnap) {
                            Self.upsertSortedEntries(into: &sortedMac!, newItems: [fileEntry], pathOf: \.path)
                            didMutateMac = true
                        }
                    } else {
                        if Self.removePathAndDescendants(from: &sortedMac!, rootPath: eventPath, pathOf: \.path) {
                            didMutateMac = true
                        }
                    }
                }

                // 2. Check Google Drive incremental updates
                guard let acc = accountsSnap.first(where: { eventPath.hasPrefix($0.rootPath) }) else { continue }

                var isDir: ObjCBool = false
                let existsAsDir = fm.fileExists(atPath: eventPath, isDirectory: &isDir) && isDir.boolValue

                if let md = acc.myDrivePath, eventPath.hasPrefix(md + "/") {
                    if sortedFolders == nil {
                        sortedFolders = folderIdxSnap.decodeEntries()
                    }
                    if existsAsDir {
                        let newSubtree = Self.scanFolderSubtree(at: eventPath, myDriveRoot: md, maxSubDepth: 4)
                        _ = Self.removePathAndDescendants(from: &sortedFolders!, rootPath: eventPath, pathOf: \.path)
                        Self.upsertSortedEntries(into: &sortedFolders!, newItems: newSubtree, pathOf: \.path)
                        didMutateFolders = true
                    } else {
                        if Self.removePathAndDescendants(from: &sortedFolders!, rootPath: eventPath, pathOf: \.path) {
                            didMutateFolders = true
                        }
                    }
                } else if let sd = acc.sharedDrivesPath, eventPath.hasPrefix(sd + "/") {
                    if sortedShared == nil {
                        sortedShared = sharedIdxSnap.decodeEntries()
                    }
                    if existsAsDir {
                        var fresh: [SharedDriveEntry] = []
                        let rel = String(eventPath.dropFirst(sd.count + 1))
                        let segs = rel.split(separator: "/").map(String.init)
                        let sigs = segs.map { Self.extractSignatures($0) }
                        let sharedPrefix = L("Bộ nhớ dùng chung", "Shared Drives")
                        fresh.append(SharedDriveEntry(
                            path: eventPath,
                            isDir: true,
                            displaySub: "\(sharedPrefix)/\(rel)",
                            cleanSegs: ["bonhodungchungshareddrives"] + sigs.map(\.clean),
                            acrSegs: [""] + sigs.map(\.acronym)
                        ))
                        let hitCap = Self.walkSharedTree(
                            rootDir: eventPath,
                            baseStripPath: sd,
                            prefixDisplay: sharedPrefix,
                            prefixClean: "bonhodungchungshareddrives",
                            maxDepth: 4,
                            maxItems: 5_000,
                            into: &fresh
                        )
                        if hitCap {
                            shouldScheduleFullSharedRebuild = true
                        }
                        _ = Self.removePathAndDescendants(from: &sortedShared!, rootPath: eventPath, pathOf: \.path)
                        Self.upsertSortedEntries(into: &sortedShared!, newItems: fresh, pathOf: \.path)
                        didMutateShared = true
                    } else {
                        if Self.removePathAndDescendants(from: &sortedShared!, rootPath: eventPath, pathOf: \.path) {
                            didMutateShared = true
                        }
                    }
                }
            }

            let updatedFastFolders = didMutateFolders ? sortedFolders.map { FastFolderIndex.build(from: $0) } : nil
            let updatedFastShared = didMutateShared ? sortedShared.map { FastSharedIndex.build(from: $0) } : nil
            let updatedFastMac = didMutateMac ? sortedMac.map { FastSharedIndex.build(from: $0) } : nil
            let needSharedRebuild = shouldScheduleFullSharedRebuild
            let mutatedAny = didMutateFolders || didMutateShared || didMutateMac
            let mutatedAlfred = didMutateFolders || didMutateShared

            await MainActor.run {
                let svc = GoogleDriveIndexService.shared
                if let updatedFastFolders {
                    svc.fastFolderIndex = updatedFastFolders
                    svc.folderCount = updatedFastFolders.count
                    svc.lastCacheUpdate = Date()
                    Self.folderRefineLock.withLock { $0 = nil }
                }
                if let updatedFastShared {
                    svc.fastSharedIndex = updatedFastShared
                    svc.sharedCount = updatedFastShared.count
                    Self.sharedRefineLock.withLock { $0 = nil }
                }
                if let updatedFastMac {
                    svc.fastMacFolderIndex = updatedFastMac
                    svc.macFolderItemCount = updatedFastMac.count
                }
                if mutatedAny {
                    svc.scheduleBinaryIndexPersist()
                }
                if mutatedAlfred && AppSettings.shared.keepAlfredCacheCompatible {
                    svc.scheduleAlfredCompatibilityJSONPersist()
                }
                svc.isProcessingFSEvents = false
                if needSharedRebuild {
                    svc.rebuildSharedCacheInBackground()
                } else if !svc.pendingEventPaths.isEmpty {
                    svc.processPendingFSEvents()
                }
                if mutatedAny && LauncherPanelController.shared.isVisible {
                    LauncherViewModel.shared.refreshSearchResults()
                }
            }
        }
    }

    /// Removes `rootPath` and all descendants with prefix `rootPath + "/"` from a path-sorted array in O(log N) binary search + single subrange removal (§4.3).
    private nonisolated static func removePathAndDescendants<T>(
        from sortedArray: inout [T],
        rootPath: String,
        pathOf: (T) -> String
    ) -> Bool {
        var didRemove = false
        let exactIdx = lowerBoundIndex(in: sortedArray, target: rootPath, pathOf: pathOf)
        if exactIdx < sortedArray.count && pathOf(sortedArray[exactIdx]) == rootPath {
            sortedArray.remove(at: exactIdx)
            didRemove = true
        }
        let lowerPrefix = rootPath + "/"
        let upperPrefix = rootPath + "0"
        let startIdx = lowerBoundIndex(in: sortedArray, target: lowerPrefix, pathOf: pathOf)
        let endIdx = lowerBoundIndex(in: sortedArray, target: upperPrefix, pathOf: pathOf)
        if startIdx < endIdx {
            sortedArray.removeSubrange(startIdx..<endIdx)
            didRemove = true
        }
        return didRemove
    }

    private nonisolated static func lowerBoundIndex<T>(
        in sortedArray: [T],
        target: String,
        pathOf: (T) -> String
    ) -> Int {
        var low = 0
        var high = sortedArray.count
        while low < high {
            let mid = (low + high) >> 1
            if pathOf(sortedArray[mid]) < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private nonisolated static func upsertSortedEntries<T>(
        into sortedArray: inout [T],
        newItems: [T],
        pathOf: (T) -> String
    ) {
        guard !newItems.isEmpty else { return }
        for item in newItems {
            let p = pathOf(item)
            let idx = lowerBoundIndex(in: sortedArray, target: p, pathOf: pathOf)
            if idx < sortedArray.count && pathOf(sortedArray[idx]) == p {
                sortedArray[idx] = item
            } else {
                sortedArray.insert(item, at: idx)
            }
        }
    }

    private nonisolated static func scanFolderSubtree(
        at startDir: String,
        myDriveRoot: String,
        maxSubDepth: Int
    ) -> [DriveFolderEntry] {
        let fm = FileManager.default
        let rootPrefixLen = myDriveRoot.count + 1
        var out: [DriveFolderEntry] = []
        var stack: [(String, Int)] = [(startDir, 0)]

        while let (cur, d) = stack.popLast() {
            let name = (cur as NSString).lastPathComponent
            if shouldSkip(name) { continue }
            let rel = cur.hasPrefix(myDriveRoot + "/") ? String(cur.dropFirst(rootPrefixLen)) : name
            let rawSegs = rel.split(separator: "/").map(String.init)
            let sigs = rawSegs.map { extractSignatures($0) }
            out.append(DriveFolderEntry(
                path: cur,
                cleanSegs: sigs.map(\.clean),
                acrSegs: sigs.map(\.acronym)
            ))

            guard d < maxSubDepth, let children = try? fm.contentsOfDirectory(atPath: cur) else { continue }
            for child in children where !shouldSkip(child) {
                let full = "\(cur)/\(child)"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    stack.append((full, d + 1))
                }
            }
        }
        return out
    }

    // MARK: - DBIX v1 Binary Cache Persistence & Alfred Compatibility (§5.2)

    struct LoadedBinaryIndex: Sendable {
        let timestamp: Double
        let macRoots: [String]
        let folderIndex: FastFolderIndex
        let sharedIndex: FastSharedIndex
        let fileIndex: FastFileIndex
        let macIndex: FastSharedIndex
    }

    nonisolated static func saveBinaryIndexToDisk(
        to filePath: String,
        timestamp: Double,
        macRoots: [String],
        folderIndex: FastFolderIndex,
        sharedIndex: FastSharedIndex,
        fileIndex: FastFileIndex,
        macIndex: FastSharedIndex
    ) {
        let rootsData = (try? JSONEncoder().encode(macRoots)) ?? Data("[]".utf8)
        let fBlob = folderIndex.blob
        let sBlob = sharedIndex.blob
        let flBlob = fileIndex.blob
        let mBlob = macIndex.blob

        var out = Data()
        out.reserveCapacity(52 &+ rootsData.count &+ fBlob.count &+ sBlob.count &+ flBlob.count &+ mBlob.count)

        // 52-byte header:
        // [0..<4]   Magic "DBIX"
        // [4..<8]   Version = 1 (UInt32 LE)
        // [8..<16]  Timestamp (Float64 bitPattern UInt64 LE)
        // [16..<20] folderCount (UInt32 LE)
        // [20..<24] sharedCount (UInt32 LE)
        // [24..<28] fileCount (UInt32 LE)
        // [28..<32] macCount (UInt32 LE)
        // [32..<36] rootsDataLen (UInt32 LE)
        // [36..<40] folderBlobLen (UInt32 LE)
        // [40..<44] sharedBlobLen (UInt32 LE)
        // [44..<48] fileBlobLen (UInt32 LE)
        // [48..<52] macBlobLen (UInt32 LE)
        out.append(contentsOf: [0x44, 0x42, 0x49, 0x58]) // "DBIX"
        BinaryIndexCodec.appendU32LE(&out, 1)
        BinaryIndexCodec.appendU64LE(&out, timestamp.bitPattern)
        BinaryIndexCodec.appendU32LE(&out, folderIndex.count)
        BinaryIndexCodec.appendU32LE(&out, sharedIndex.count)
        BinaryIndexCodec.appendU32LE(&out, fileIndex.count)
        BinaryIndexCodec.appendU32LE(&out, macIndex.count)
        BinaryIndexCodec.appendU32LE(&out, rootsData.count)
        BinaryIndexCodec.appendU32LE(&out, fBlob.count)
        BinaryIndexCodec.appendU32LE(&out, sBlob.count)
        BinaryIndexCodec.appendU32LE(&out, flBlob.count)
        BinaryIndexCodec.appendU32LE(&out, mBlob.count)

        out.append(rootsData)
        out.append(fBlob)
        out.append(sBlob)
        out.append(flBlob)
        out.append(mBlob)

        writeQueue(for: filePath).sync {
            let fm = FileManager.default
            let dir = (filePath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? out.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        }
    }

    nonisolated static func loadBinaryIndexFromDisk(at filePath: String) -> LoadedBinaryIndex? {
        guard let mapped = try? Data(contentsOf: URL(fileURLWithPath: filePath), options: .alwaysMapped),
              mapped.count >= 52 else {
            return nil
        }

        let headerMeta: (
            ts: Double,
            fCount: Int,
            sCount: Int,
            flCount: Int,
            mCount: Int,
            rootsLen: Int,
            fLen: Int,
            sLen: Int,
            flLen: Int,
            mLen: Int
        )? = mapped.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            guard base[0] == 0x44, base[1] == 0x42, base[2] == 0x49, base[3] == 0x58 else { return nil }
            let version = BinaryIndexCodec.readU32LE(base, 4)
            guard version == 1 else { return nil }
            let tsBits = BinaryIndexCodec.readU64LE(base, 8)
            let ts = Double(bitPattern: tsBits)
            let fCount = BinaryIndexCodec.readU32LE(base, 16)
            let sCount = BinaryIndexCodec.readU32LE(base, 20)
            let flCount = BinaryIndexCodec.readU32LE(base, 24)
            let mCount = BinaryIndexCodec.readU32LE(base, 28)
            let rootsLen = BinaryIndexCodec.readU32LE(base, 32)
            let fLen = BinaryIndexCodec.readU32LE(base, 36)
            let sLen = BinaryIndexCodec.readU32LE(base, 40)
            let flLen = BinaryIndexCodec.readU32LE(base, 44)
            let mLen = BinaryIndexCodec.readU32LE(base, 48)
            return (ts, fCount, sCount, flCount, mCount, rootsLen, fLen, sLen, flLen, mLen)
        }

        guard let m = headerMeta else { return nil }
        let totalExpected = 52 + m.rootsLen + m.fLen + m.sLen + m.flLen + m.mLen
        guard mapped.count == totalExpected,
              m.fLen >= 4 + m.fCount * 4,
              m.sLen >= 4 + m.sCount * 4,
              m.flLen >= 4 + m.flCount * 4,
              m.mLen >= 4 + m.mCount * 4 else {
            return nil
        }

        var cursor = 52
        let rootsSlice = mapped.subdata(in: cursor..<(cursor + m.rootsLen))
        cursor += m.rootsLen
        let fSlice = mapped.subdata(in: cursor..<(cursor + m.fLen))
        cursor += m.fLen
        let sSlice = mapped.subdata(in: cursor..<(cursor + m.sLen))
        cursor += m.sLen
        let flSlice = mapped.subdata(in: cursor..<(cursor + m.flLen))
        cursor += m.flLen
        let mSlice = mapped.subdata(in: cursor..<(cursor + m.mLen))

        let roots = (try? JSONDecoder().decode([String].self, from: rootsSlice)) ?? []
        return LoadedBinaryIndex(
            timestamp: m.ts,
            macRoots: roots,
            folderIndex: FastFolderIndex(blob: fSlice, count: m.fCount),
            sharedIndex: FastSharedIndex(blob: sSlice, count: m.sCount),
            fileIndex: FastFileIndex(blob: flSlice, count: m.flCount),
            macIndex: FastSharedIndex(blob: mSlice, count: m.mCount)
        )
    }

    func scheduleBinaryIndexPersist(delayNanoseconds: UInt64 = 1_500_000_000) {
        binaryCachePersistTask?.cancel()
        let binPath = binaryCachePath
        let ts = (lastCacheUpdate ?? Date()).timeIntervalSince1970
        let rootsSnap = macFolderRootsSnapshot
        let fIdx = fastFolderIndex
        let sIdx = fastSharedIndex
        let flIdx = fastFileIndex
        let mIdx = fastMacFolderIndex

        binaryCachePersistTask = Task.detached(priority: .utility) {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            Self.saveBinaryIndexToDisk(
                to: binPath,
                timestamp: ts,
                macRoots: rootsSnap,
                folderIndex: fIdx,
                sharedIndex: sIdx,
                fileIndex: flIdx,
                macIndex: mIdx
            )
        }
    }

    /// Writes `folder_cache.json` and `shared_cache.json` at `.background` priority debounced by 30s when `keepAlfredCacheCompatible` is enabled (§5.2).
    func scheduleAlfredCompatibilityJSONPersist() {
        alfredCompatPersistTask?.cancel()
        guard AppSettings.shared.keepAlfredCacheCompatible else { return }
        let fIdx = fastFolderIndex
        let sIdx = fastSharedIndex
        let mdRoot = myDrivePath
        let accRoot = accountRoot
        let fPath = folderCachePath
        let sPath = sharedCachePath

        alfredCompatPersistTask = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            let now = Date().timeIntervalSince1970
            if !fIdx.isEmpty {
                let fPayload = FolderCachePayload(
                    timestamp: now,
                    root: mdRoot,
                    items: fIdx.decodeEntries(),
                    folders: nil
                )
                Self.writeCodableAtomic(fPayload, to: fPath)
            }
            if !sIdx.isEmpty {
                let sPayload = SharedCachePayload(
                    timestamp: now,
                    root: accRoot,
                    items: sIdx.decodeEntries()
                )
                Self.writeCodableAtomic(sPayload, to: sPath)
            }
        }
    }

    // MARK: - Initial Load

    private func loadInitialDataAsync() {
        let bCache = binaryCachePath
        let fCache = folderCachePath
        let sCache = sharedCachePath
        let flCache = fileCachePath
        let mCache = macFoldersCachePath
        let hPath = historyPath
        let qPath = queryHistoryPath
        let currentAccount = accountRoot
        let configuredMacRoots = AppSettings.shared.customMacFolders.map {
            $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0
        }

        let cDir = cacheDir
        Task.detached(priority: .userInitiated) {
            Self.cleanupStaleTempFiles(in: cDir)
            var loadedHistory = Self.readHistoryDisk(at: hPath)
            var loadedQueryHistory = Self.readQueryHistoryDisk(at: qPath)
            let nowSeed = Date().timeIntervalSince1970
            if loadedQueryHistory["sleep"] == nil && loadedHistory["sys:sys.sleep_displays"] == nil {
                loadedHistory["sys:sys.sleep_displays"] = HistoryRecord(count: 5, last_used: nowSeed)
                loadedHistory["sys:sys.sleep"] = HistoryRecord(count: 4, last_used: nowSeed - 5)
                loadedQueryHistory["sleep"] = [
                    "sys:sys.sleep_displays": QueryLatchRecord(count: 5, last_used: nowSeed),
                    "sys:sys.sleep": QueryLatchRecord(count: 4, last_used: nowSeed - 5)
                ]
                Self.writeCodableAtomic(loadedHistory, to: hPath)
                Self.writeCodableAtomic(loadedQueryHistory, to: qPath)
            }
            let finalHistory = loadedHistory
            let finalQueryHistory = loadedQueryHistory

            // Fast path (§5.2): memory-map `drivebar_index_v1.bin` in < 80 ms!
            if let binLoaded = Self.loadBinaryIndexFromDisk(at: bCache) {
                let scannedApps = Self.scanInstalledApplications()
                await MainActor.run {
                    let service = GoogleDriveIndexService.shared
                    service.history = finalHistory
                    service.queryHistory = finalQueryHistory
                    service.installedApps = scannedApps
                    service.lastAppScanUptime = ProcessInfo.processInfo.systemUptime

                    service.fastFolderIndex = binLoaded.folderIndex
                    service.folderCount = binLoaded.folderIndex.count
                    service.fastSharedIndex = binLoaded.sharedIndex
                    service.sharedCount = binLoaded.sharedIndex.count
                    service.fastFileIndex = binLoaded.fileIndex
                    service.fileCount = binLoaded.fileIndex.count
                    service.fastMacFolderIndex = binLoaded.macIndex
                    service.macFolderItemCount = binLoaded.macIndex.count
                    service.macFolderRootsSnapshot = binLoaded.macRoots
                    service.lastCacheUpdate = Date(timeIntervalSince1970: binLoaded.timestamp)

                    let age = Date().timeIntervalSince1970 - binLoaded.timestamp
                    if (binLoaded.folderIndex.isEmpty && currentAccount != nil) || age > 86_400 {
                        service.rebuildFolderCacheInBackground()
                    }
                    if (binLoaded.sharedIndex.isEmpty && (service.sharedDrivesPath != nil || service.shortcutTargetsPath != nil)) || age > 86_400 {
                        service.rebuildSharedCacheInBackground()
                    }
                    if binLoaded.macRoots != configuredMacRoots || (!configuredMacRoots.isEmpty && binLoaded.macIndex.isEmpty) {
                        service.rebuildMacFoldersCacheInBackground()
                    }

                    SyncAndLatchingService.shared.start()
                    LauncherViewModel.shared.refreshSearchResults()
                }
                return
            }

            // Fallback path: migrate from legacy JSON caches on first run and immediately write `drivebar_index_v1.bin`
            let loadedFolders = Self.readFolderCacheDisk(at: fCache)
            let builtFastFolders = loadedFolders.map { FastFolderIndex.build(from: $0.0) } ?? .empty
            let loadedShared = Self.readSharedCacheDisk(at: sCache)
            let builtFastShared = loadedShared.map { FastSharedIndex.build(from: $0.0) } ?? .empty
            let loadedFiles = Self.readFileCacheDisk(at: flCache)
            let builtFastFiles = loadedFiles.map { FastFileIndex.build(from: $0.0) } ?? .empty
            let loadedMac = Self.readMacFoldersCacheDisk(at: mCache)
            let builtFastMac = loadedMac.map { FastSharedIndex.build(from: $0.items) } ?? .empty
            let ts = loadedFolders?.1 ?? loadedFiles?.1 ?? Date().timeIntervalSince1970
            let macRoots = loadedMac?.roots ?? configuredMacRoots

            if !builtFastFolders.isEmpty || !builtFastShared.isEmpty || !builtFastFiles.isEmpty || !builtFastMac.isEmpty {
                Self.saveBinaryIndexToDisk(
                    to: bCache,
                    timestamp: ts,
                    macRoots: macRoots,
                    folderIndex: builtFastFolders,
                    sharedIndex: builtFastShared,
                    fileIndex: builtFastFiles,
                    macIndex: builtFastMac
                )
                // Remove redundant non-Alfred JSON caches once `drivebar_index_v1.bin` is active (§5.2)
                try? FileManager.default.removeItem(atPath: flCache)
                try? FileManager.default.removeItem(atPath: mCache)
            }

            let scannedApps = Self.scanInstalledApplications()

            await MainActor.run {
                let service = GoogleDriveIndexService.shared
                service.history = finalHistory
                service.queryHistory = finalQueryHistory
                service.installedApps = scannedApps
                service.lastAppScanUptime = ProcessInfo.processInfo.systemUptime

                service.fastFolderIndex = builtFastFolders
                service.folderCount = builtFastFolders.count
                service.fastSharedIndex = builtFastShared
                service.sharedCount = builtFastShared.count
                service.fastFileIndex = builtFastFiles
                service.fileCount = builtFastFiles.count
                service.fastMacFolderIndex = builtFastMac
                service.macFolderItemCount = builtFastMac.count
                service.macFolderRootsSnapshot = macRoots
                service.lastCacheUpdate = Date(timeIntervalSince1970: ts)

                if builtFastFolders.isEmpty && currentAccount != nil {
                    service.rebuildFolderCacheInBackground()
                } else if Date().timeIntervalSince1970 - ts > 86_400 {
                    service.rebuildFolderCacheInBackground()
                }

                if builtFastShared.isEmpty && (service.sharedDrivesPath != nil || service.shortcutTargetsPath != nil) {
                    service.rebuildSharedCacheInBackground()
                }

                if builtFastFiles.isEmpty {
                    service.rebuildFileCacheInBackground()
                }

                if macRoots != configuredMacRoots || (!configuredMacRoots.isEmpty && builtFastMac.isEmpty) {
                    service.rebuildMacFoldersCacheInBackground()
                }

                SyncAndLatchingService.shared.start()
                LauncherViewModel.shared.refreshSearchResults()
            }
        }
    }

    private nonisolated static func readMacFoldersCacheDisk(at path: String) -> MacFoldersCachePayload? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let payload = try? JSONDecoder().decode(MacFoldersCachePayload.self, from: data) else {
            return nil
        }
        return payload
    }

    private nonisolated static func readFileCacheDisk(at path: String) -> ([DriveFileEntry], Double)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let payload = try? JSONDecoder().decode(FileCachePayload.self, from: data) else {
            return nil
        }
        return (payload.items, payload.timestamp)
    }

    private nonisolated static func readHistoryDisk(at path: String) -> [String: HistoryRecord] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([String: HistoryRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private nonisolated static func readQueryHistoryDisk(at path: String) -> [String: [String: QueryLatchRecord]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([String: [String: QueryLatchRecord]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private nonisolated static func readFolderCacheDisk(at path: String) -> ([DriveFolderEntry], Double)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let payload = try? JSONDecoder().decode(FolderCachePayload.self, from: data) else {
            return nil
        }
        let items = payload.items ?? payload.folders ?? []
        return (items, payload.timestamp)
    }

    private nonisolated static func readSharedCacheDisk(at path: String) -> ([SharedDriveEntry], Double)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let payload = try? JSONDecoder().decode(SharedCachePayload.self, from: data) else {
            return nil
        }
        return (payload.items, payload.timestamp)
    }

    func refreshInstalledAppsIfNeeded(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !isScanningApps else { return }
        guard force || installedApps.isEmpty || (now - lastAppScanUptime) > 30.0 else { return }
        isScanningApps = true

        Task.detached(priority: .utility) {
            let scanned = Self.scanInstalledApplications()
            await MainActor.run {
                let svc = GoogleDriveIndexService.shared
                svc.installedApps = scanned
                svc.lastAppScanUptime = ProcessInfo.processInfo.systemUptime
                svc.isScanningApps = false
            }
        }
    }

    private nonisolated static let skippedAppSubfolderNames: Set<String> = [
        "contents", "frameworks", "plugins", "helpers", "services",
        "xpcservices", "library", "_codesignature", "resources", "macos"
    ]

    private nonisolated static func scanInstalledApplications() -> [InstalledAppEntry] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let scanRoots: [(path: String, maxDepth: Int)] = [
            ("/Applications", 5),
            ("/System/Applications", 2),
            ("/System/Cryptexes/App/System/Applications", 2),
            ("\(home)/Applications", 3),
            ("/System/Library/CoreServices/Applications", 1)
        ]

        var candidatePaths: [(path: String, depth: Int)] = []
        if fm.fileExists(atPath: "/System/Library/CoreServices/Finder.app") {
            candidatePaths.append(("/System/Library/CoreServices/Finder.app", 0))
        }

        for root in scanRoots {
            collectAppBundles(in: root.path, currentDepth: 0, maxDepth: root.maxDepth, fm: fm, into: &candidatePaths)
        }

        var seenCanonicalPaths = Set<String>()
        var seenBundleAndName = Set<String>()
        var entries: [InstalledAppEntry] = []
        entries.reserveCapacity(candidatePaths.count)

        for candidate in candidatePaths {
            let full = candidate.path
            let canonical = URL(fileURLWithPath: full).resolvingSymlinksInPath().path.lowercased()
            guard seenCanonicalPaths.insert(canonical).inserted else { continue }

            let rawFileName = ((full as NSString).lastPathComponent as NSString).deletingPathExtension
            guard !rawFileName.isEmpty else { continue }

            let infoPlistPath = "\(full)/Contents/Info.plist"
            let plist = NSDictionary(contentsOfFile: infoPlistPath) as? [String: Any]
            if let bgOnly = plist?["LSBackgroundOnly"] as? Bool, bgOnly {
                continue
            }
            if let bgStr = plist?["LSBackgroundOnly"] as? String, (bgStr == "1" || bgStr.lowercased() == "true") {
                continue
            }

            let bundleID = (plist?["CFBundleIdentifier"] as? String) ?? ""
            let bundleDisplayName = (plist?["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let bundleShortName = (plist?["CFBundleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let finderDisplay = fm.displayName(atPath: full)
                .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive, .anchored, .backwards])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let (locEN, locVI, locKeywords) = AppLocalization.localizedBundleNames(
                forAppAt: full,
                plist: plist,
                rawFileName: rawFileName
            )
            let nameEN = locEN.isEmpty ? rawFileName : locEN
            let nameVI = locVI.isEmpty ? nameEN : locVI

            let dedupKey = "\(bundleID.lowercased())::\(nameEN.lowercased())"
            if !bundleID.isEmpty && !seenBundleAndName.insert(dedupKey).inserted {
                continue
            }

            var wordList: [String] = []
            var seenWords = Set<String>()
            for variant in ([nameEN, nameVI, rawFileName, bundleDisplayName, bundleShortName, finderDisplay] + locKeywords) where !variant.isEmpty {
                for w in extractAppWords(variant) where seenWords.insert(w).inserted {
                    wordList.append(w)
                }
            }

            let wordsEN = extractAppWords(nameEN)
            let wordsVI = extractAppWords(nameVI)
            let acronym: String = {
                if wordsEN.count > 1 {
                    return String(wordsEN.compactMap(\.first))
                }
                if wordList.count > 1 {
                    return String(wordList.compactMap(\.first))
                }
                return ""
            }()
            let acronymVI: String = wordsVI.count > 1 ? String(wordsVI.compactMap(\.first)) : ""

            let rawCleanEN = cleanString(nameEN)
            let cleanFull = rawCleanEN.isEmpty ? cleanString(rawFileName) : rawCleanEN
            let rawCleanVI = cleanString(nameVI)
            let cleanFullVI = rawCleanVI.isEmpty ? cleanFull : rawCleanVI

            var aliases = builtInAliases(bundleID: bundleID, cleanFull: cleanFull, rawFileClean: cleanString(rawFileName))
            var seenAliases = Set(aliases)
            for extraAlias in [cleanFullVI, cleanFull, cleanString(rawFileName), acronymVI] where !extraAlias.isEmpty {
                if extraAlias != cleanFull && seenAliases.insert(extraAlias).inserted {
                    aliases.append(extraAlias)
                }
            }

            let lowerName = "\(nameEN) \(rawFileName)".lowercased()
            let isHelper = candidate.depth >= 2 && (
                lowerName.contains("uninstall") ||
                lowerName.contains("license") ||
                lowerName.contains("updater") ||
                lowerName.contains("helper") ||
                lowerName.contains("python2 ") ||
                lowerName.contains("python3 ")
            )

            entries.append(InstalledAppEntry(
                nameEN: nameEN,
                nameVI: nameVI,
                path: full,
                bundleIdentifier: bundleID,
                cleanFull: cleanFull,
                cleanFullVI: cleanFullVI,
                acronym: acronym,
                acronymVI: acronymVI,
                words: wordList,
                aliasWords: aliases,
                isNestedHelper: isHelper
            ))
        }

        entries.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return entries
    }

    private nonisolated static func collectAppBundles(
        in dirPath: String,
        currentDepth: Int,
        maxDepth: Int,
        fm: FileManager,
        into results: inout [(path: String, depth: Int)]
    ) {
        guard currentDepth <= maxDepth,
              let names = try? fm.contentsOfDirectory(atPath: dirPath) else { return }

        for name in names {
            if name.hasPrefix(".") { continue }
            let lower = name.lowercased()
            if lower.hasSuffix(".backup") || lower.hasSuffix(".workflow") || lower.hasSuffix(".bundle") || lower.hasSuffix(".framework") {
                continue
            }
            let full = "\(dirPath)/\(name)"
            if lower.hasSuffix(".app") {
                results.append((full, currentDepth))
                continue
            }
            guard currentDepth < maxDepth else { continue }
            if skippedAppSubfolderNames.contains(lower) { continue }

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                collectAppBundles(in: full, currentDepth: currentDepth + 1, maxDepth: maxDepth, fm: fm, into: &results)
            }
        }
    }

    nonisolated static func extractAppWords(_ raw: String) -> [String] {
        let unaccented = removeAccents(raw)
        let chars = Array(unaccented)
        var spaced = ""
        spaced.reserveCapacity(chars.count + 4)

        for i in chars.indices {
            let c = chars[i]
            if i > 0 {
                let prev = chars[i - 1]
                let boundaryCamel = prev.isLowercase && c.isUppercase
                let boundaryAcronymWord = prev.isUppercase && c.isUppercase && (i + 1 < chars.count && chars[i + 1].isLowercase)
                let boundaryNumLetter = (prev.isNumber && c.isLetter) || (prev.isLetter && c.isNumber)
                if boundaryCamel || boundaryAcronymWord || boundaryNumLetter {
                    spaced.append(" ")
                }
            }
            spaced.append(c)
        }

        let lower = spaced.lowercased()
        var out: [String] = []
        var cur = ""
        for scalar in lower.unicodeScalars {
            let isAlphaNum = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            if isAlphaNum {
                cur.unicodeScalars.append(scalar)
            } else if !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty {
            out.append(cur)
        }
        return out
    }

    private nonisolated static func builtInAliases(bundleID: String, cleanFull: String, rawFileClean: String) -> [String] {
        switch bundleID {
        case "com.apple.ActivityMonitor":
            return ["active", "monitor", "task", "manager", "process", "cpu", "ram", "memory", "giam", "sat", "hoat", "dong"]
        case "com.apple.systempreferences":
            return ["system", "preferences", "settings", "cai", "dat", "he", "thong", "tuy", "chon"]
        case "com.apple.iCal":
            return ["calendar", "ical", "lich"]
        case "com.apple.Notes":
            return ["notes", "ghi", "chu"]
        case "com.apple.reminders":
            return ["reminders", "loi", "nhac"]
        case "com.apple.mail":
            return ["mail", "thu", "email"]
        case "com.apple.MobileSMS":
            return ["messages", "imessage", "tin", "nhan"]
        case "com.apple.AddressBook":
            return ["contacts", "danh", "ba"]
        case "com.apple.Maps":
            return ["maps", "ban", "do"]
        case "com.apple.Photos":
            return ["photos", "anh", "hinh"]
        case "com.apple.calculator":
            return ["calculator", "calc", "may", "tinh"]
        case "com.apple.Preview":
            return ["preview", "xem", "truoc"]
        case "com.apple.Dictionary":
            return ["dictionary", "tu", "dien"]
        case "com.apple.Music":
            return ["music", "itunes", "nhac"]
        case "com.apple.weather":
            return ["weather", "thoi", "tiet"]
        case "com.apple.clock":
            return ["clock", "dong", "ho", "alarm"]
        case "com.apple.VoiceMemos":
            return ["voice", "memos", "ghi", "am"]
        case "com.apple.Passwords":
            return ["passwords", "keychain", "mat", "khau"]
        case "com.microsoft.edgemac":
            return ["msedge", "edge", "browser", "trinh", "duyet"]
        case "com.microsoft.Word":
            return ["msword", "doc", "docx", "van", "ban"]
        case "com.microsoft.Excel":
            return ["msexcel", "xls", "xlsx", "spreadsheet", "bang", "tinh"]
        case "com.microsoft.Powerpoint":
            return ["mspowerpoint", "ppt", "pptx", "slide", "thuyet", "trinh"]
        case "com.google.Chrome":
            return ["chrome", "browser", "trinh", "duyet"]
        case "com.apple.Safari":
            return ["safari", "browser", "trinh", "duyet"]
        case "com.apple.Terminal":
            return ["terminal", "shell", "zsh", "bash", "cli", "console"]
        case "com.apple.DiskUtility":
            return ["disk", "utility", "o", "dia", "format"]
        case "com.apple.screencaptureui":
            return ["screenshot", "screen", "capture", "chup", "man", "hinh"]
        case "com.apple.finder":
            return ["finder", "file", "tep", "thu", "muc"]
        default:
            if rawFileClean != cleanFull && !rawFileClean.isEmpty {
                return [rawFileClean]
            }
            return []
        }
    }

    // MARK: - Vietnamese Normalization & Signatures (Exact parity with folder_search.py)

    nonisolated static func removeAccents(_ s: String) -> String {
        let replaced = s
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "D")
        let decomposed = replaced.decomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(decomposed.unicodeScalars.count)
        for scalar in decomposed.unicodeScalars {
            if !CharacterSet.nonBaseCharacters.contains(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    nonisolated static func cleanString(_ s: String) -> String {
        let unaccented = removeAccents(s).lowercased()
        var out = ""
        out.reserveCapacity(unaccented.utf8.count)
        for ch in unaccented.unicodeScalars {
            if (ch.value >= 97 && ch.value <= 122) || (ch.value >= 48 && ch.value <= 57) {
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    nonisolated static func extractSignatures(_ name: String) -> (clean: String, acronym: String) {
        let unaccented = removeAccents(name)
        var spaced = ""
        let chars = Array(unaccented)
        for i in chars.indices {
            let c = chars[i]
            if i > 0 {
                let prev = chars[i - 1]
                let boundaryCamel = prev.isLowercase && c.isUppercase
                let boundaryNumLetter = (prev.isNumber && c.isLetter) || (prev.isLetter && c.isNumber)
                if boundaryCamel || boundaryNumLetter {
                    spaced.append(" ")
                }
            }
            spaced.append(c)
        }

        let lower = spaced.lowercased()
        var words: [String] = []
        var currentWord = ""
        for scalar in lower.unicodeScalars {
            let isAlphaNum = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            if isAlphaNum {
                currentWord.unicodeScalars.append(scalar)
            } else if !currentWord.isEmpty {
                if !currentWord.allSatisfy(\.isNumber) {
                    words.append(currentWord)
                }
                currentWord = ""
            }
        }
        if !currentWord.isEmpty && !currentWord.allSatisfy(\.isNumber) {
            words.append(currentWord)
        }

        let acronym = words.count > 1 ? String(words.compactMap(\.first)) : ""
        let clean = cleanString(unaccented)
        return (clean, acronym)
    }

    private nonisolated static func shouldSkip(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return skipExtensions.contains(ext)
    }

    // MARK: - Background Cache Builders (Multi-Account Capable)

    // MARK: - Single-Pass Parallel Index Rebuild (§4.2)

    func rebuildAllCaches() {
        refreshAccountPaths()
        refreshInstalledAppsIfNeeded(force: true)
        rebuildUnifiedDriveAndLocalIndexInBackground()
        rebuildSharedCacheInBackground()
        rebuildMacFoldersCacheInBackground()
    }

    func rebuildFolderCacheInBackground() {
        rebuildUnifiedDriveAndLocalIndexInBackground()
    }

    func rebuildFileCacheInBackground() {
        if !isRebuildingFolders {
            rebuildUnifiedDriveAndLocalIndexInBackground()
        }
    }

    private struct SubtreeScanChunk: Sendable {
        var folders: [DriveFolderEntry] = []
        var files: [DriveFileEntry] = []
    }

    private nonisolated static let unifiedSkippedDirNames: Set<String> = [
        "node_modules", ".git", ".svn", ".venv", "venv", "__pycache__",
        ".build", "build", "deriveddata", "pods", "library"
    ]

    /// Traverses a directory tree in a single POSIX `opendir`/`readdir` (`d_type`) pass,
    /// carrying parent `(cleanSegs, acrSegs, cleanParent)` down the stack so `extractSignatures`
    /// is computed exactly ONCE per directory/file name (§4.2).
    private nonisolated static func scanSubtreeSinglePassPOSIX(
        startDir: String,
        initialDepth: Int,
        maxDepth: Int,
        collectFolders: Bool,
        initialCleanSegs: [String],
        initialAcrSegs: [String],
        initialCleanParent: String,
        maxFiles: Int,
        progressPing: (@Sendable (Int) -> Void)? = nil
    ) -> SubtreeScanChunk {
        var chunk = SubtreeScanChunk()
        if collectFolders && !initialCleanSegs.isEmpty {
            chunk.folders.append(DriveFolderEntry(
                path: startDir,
                cleanSegs: initialCleanSegs,
                acrSegs: initialAcrSegs
            ))
        }

        struct StackFrame {
            let dir: String
            let depth: Int
            let cleanSegs: [String]
            let acrSegs: [String]
            let cleanParent: String
        }

        var stack: [StackFrame] = [
            StackFrame(
                dir: startDir,
                depth: initialDepth,
                cleanSegs: initialCleanSegs,
                acrSegs: initialAcrSegs,
                cleanParent: initialCleanParent
            )
        ]

        while let frame = stack.popLast() {
            if chunk.files.count >= maxFiles { break }
            guard let dirPtr = Darwin.opendir(frame.dir) else { continue }
            var childFrames: [StackFrame] = []

            while let ent = Darwin.readdir(dirPtr) {
                let nameLen = Int(ent.pointee.d_namlen)
                guard nameLen > 0 else { continue }
                let dType = ent.pointee.d_type

                let name: String = withUnsafePointer(to: ent.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { utf8Ptr in
                        String(decoding: UnsafeBufferPointer(start: utf8Ptr, count: nameLen), as: UTF8.self)
                    }
                }
                if name.isEmpty || name.hasPrefix(".") || name == "Icon\r" { continue }

                let fullPath = "\(frame.dir)/\(name)"
                let isDirectory: Bool
                if dType == DT_DIR {
                    isDirectory = true
                } else if dType == DT_REG || dType == DT_LNK {
                    isDirectory = false
                } else {
                    if fullPath.contains("/Library/CloudStorage/") {
                        isDirectory = (name as NSString).pathExtension.isEmpty
                    } else {
                        var st = Darwin.stat()
                        isDirectory = (Darwin.lstat(fullPath, &st) == 0) && ((st.st_mode & S_IFMT) == S_IFDIR)
                    }
                }

                if isDirectory {
                    let lowerName = name.lowercased()
                    if unifiedSkippedDirNames.contains(lowerName) || shouldSkip(name) { continue }
                    let (cSeg, aSeg) = extractSignatures(name)
                    let nextCleanSegs = frame.cleanSegs + [cSeg]
                    let nextAcrSegs = frame.acrSegs + [aSeg]
                    let nextCleanParent = frame.cleanParent.isEmpty ? cSeg : (frame.cleanParent + cSeg)

                    if collectFolders {
                        chunk.folders.append(DriveFolderEntry(
                            path: fullPath,
                            cleanSegs: nextCleanSegs,
                            acrSegs: nextAcrSegs
                        ))
                        if chunk.folders.count % 2500 == 0 {
                            progressPing?(chunk.folders.count)
                        }
                    }

                    if frame.depth < maxDepth {
                        childFrames.append(StackFrame(
                            dir: fullPath,
                            depth: frame.depth + 1,
                            cleanSegs: nextCleanSegs,
                            acrSegs: nextAcrSegs,
                            cleanParent: nextCleanParent
                        ))
                    }
                } else {
                    let ext = (name as NSString).pathExtension.lowercased()
                    if ext == "tmp" || ext == "part" || ext == "crdownload" || ext == "ds_store" { continue }
                    let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
                    let (cStem, acr) = extractSignatures(stem)
                    let cFull = ext.isEmpty ? cStem : "\(cStem)\(ext)"
                    chunk.files.append(DriveFileEntry(
                        path: fullPath,
                        ext: ext,
                        cleanName: cFull,
                        acronym: acr,
                        cleanParent: frame.cleanParent
                    ))
                    if chunk.files.count >= maxFiles { break }
                }
            }
            Darwin.closedir(dirPtr)

            childFrames.sort { $0.dir < $1.dir }
            for cf in childFrames.reversed() {
                stack.append(cf)
            }
        }
        return chunk
    }

    /// Single-pass parallel index builder across My Drive, Shared drives, and local folders (§4.2).
    func rebuildUnifiedDriveAndLocalIndexInBackground() {
        guard !isRebuildingFolders && !isRebuildingFiles else { return }
        refreshAccountPaths()

        isRebuildingFolders = true
        isRebuildingFiles = true
        rebuildProgressText = L("Đang quét nhanh chỉ mục Google Drive...", "Fast-scanning Google Drive index...")

        let myDriveRoots = activeAccounts.compactMap(\.myDrivePath)
        let sharedDriveRoots = activeAccounts.compactMap(\.sharedDrivesPath)
        let home = homePath
        let customMac = AppSettings.shared.customMacFolders.map {
            $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0
        }.filter { !$0.isEmpty }
        let targetFileCache = fileCachePath

        Task.detached(priority: .utility) {
            let (allFolders, allFiles) = await Self.performParallelUnifiedScan(
                myDriveRoots: myDriveRoots,
                sharedDriveRoots: sharedDriveRoots,
                homePath: home,
                customMacFolders: customMac,
                reportProgress: true
            )
            let now = Date().timeIntervalSince1970
            let builtFastFolders = FastFolderIndex.build(from: allFolders)
            let builtFastFiles = FastFileIndex.build(from: allFiles)
            try? FileManager.default.removeItem(atPath: targetFileCache)

            await MainActor.run {
                let svc = GoogleDriveIndexService.shared
                svc.fastFolderIndex = builtFastFolders
                svc.folderCount = builtFastFolders.count
                svc.fastFileIndex = builtFastFiles
                svc.fileCount = builtFastFiles.count
                svc.lastCacheUpdate = Date(timeIntervalSince1970: now)
                svc.isRebuildingFolders = false
                svc.isRebuildingFiles = false
                svc.rebuildProgressText = nil
                Self.folderRefineLock.withLock { $0 = nil }
                Self.fileRefineLock.withLock { $0 = nil }
                svc.scheduleBinaryIndexPersist(delayNanoseconds: 0)
                if AppSettings.shared.keepAlfredCacheCompatible {
                    svc.scheduleAlfredCompatibilityJSONPersist()
                }
                if !svc.pendingEventPaths.isEmpty {
                    svc.processPendingFSEvents()
                }
                if LauncherPanelController.shared.isVisible {
                    LauncherViewModel.shared.refreshSearchResults()
                }
            }
        }
    }

    nonisolated static func performParallelUnifiedScan(
        myDriveRoots: [String],
        sharedDriveRoots: [String],
        homePath: String,
        customMacFolders: [String],
        reportProgress: Bool
    ) async -> (folders: [DriveFolderEntry], files: [DriveFileEntry]) {
        struct WorkUnit: Sendable {
            let startDir: String
            let initialDepth: Int
            let maxDepth: Int
            let collectFolders: Bool
            let initialCleanSegs: [String]
            let initialAcrSegs: [String]
            let initialCleanParent: String
        }

        var workUnits: [WorkUnit] = []
        var rootLevelFiles: [DriveFileEntry] = []

        // 1. Expand top-level children of My Drive roots so `withTaskGroup` scans subtrees in parallel
        for mdRoot in myDriveRoots {
            guard let dirPtr = Darwin.opendir(mdRoot) else { continue }
            while let ent = Darwin.readdir(dirPtr) {
                let nameLen = Int(ent.pointee.d_namlen)
                guard nameLen > 0 else { continue }
                let dType = ent.pointee.d_type
                let name: String = withUnsafePointer(to: ent.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { utf8Ptr in
                        String(decoding: UnsafeBufferPointer(start: utf8Ptr, count: nameLen), as: UTF8.self)
                    }
                }
                if name.isEmpty || name.hasPrefix(".") || name == "Icon\r" { continue }
                let fullPath = "\(mdRoot)/\(name)"
                let isDir: Bool
                if dType == DT_DIR {
                    isDir = true
                } else if dType == DT_REG || dType == DT_LNK {
                    isDir = false
                } else {
                    isDir = (name as NSString).pathExtension.isEmpty
                }
                if isDir {
                    if unifiedSkippedDirNames.contains(name.lowercased()) || shouldSkip(name) { continue }
                    let (c, a) = extractSignatures(name)
                    workUnits.append(WorkUnit(
                        startDir: fullPath,
                        initialDepth: 1,
                        maxDepth: 10,
                        collectFolders: true,
                        initialCleanSegs: [c],
                        initialAcrSegs: [a],
                        initialCleanParent: c
                    ))
                } else {
                    let ext = (name as NSString).pathExtension.lowercased()
                    if ext == "tmp" || ext == "part" || ext == "crdownload" || ext == "ds_store" { continue }
                    let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
                    let (cStem, acr) = extractSignatures(stem)
                    let cFull = ext.isEmpty ? cStem : "\(cStem)\(ext)"
                    rootLevelFiles.append(DriveFileEntry(
                        path: fullPath,
                        ext: ext,
                        cleanName: cFull,
                        acronym: acr,
                        cleanParent: ""
                    ))
                }
            }
            Darwin.closedir(dirPtr)
        }

        // 2. Shared drives & Local roots (file collection only, folders handled by Shared/Mac indexers)
        var seenFileRoots = Set<String>(myDriveRoots)
        for sd in sharedDriveRoots where seenFileRoots.insert(sd).inserted {
            workUnits.append(WorkUnit(
                startDir: sd,
                initialDepth: 0,
                maxDepth: 8,
                collectFolders: false,
                initialCleanSegs: [],
                initialAcrSegs: [],
                initialCleanParent: ""
            ))
        }
        for sub in ["Desktop", "Downloads", "Documents"] {
            let p = "\(homePath)/\(sub)"
            if seenFileRoots.insert(p).inserted {
                workUnits.append(WorkUnit(
                    startDir: p,
                    initialDepth: 0,
                    maxDepth: 4,
                    collectFolders: false,
                    initialCleanSegs: [],
                    initialAcrSegs: [],
                    initialCleanParent: ""
                ))
            }
        }
        for custom in customMacFolders where seenFileRoots.insert(custom).inserted {
            workUnits.append(WorkUnit(
                startDir: custom,
                initialDepth: 0,
                maxDepth: 6,
                collectFolders: false,
                initialCleanSegs: [],
                initialAcrSegs: [],
                initialCleanParent: ""
            ))
        }

        let maxConcurrent = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 6))
        let progressLock = OSAllocatedUnfairLock(initialState: (totalFolders: 0, lastUptime: 0.0))

        let pingHandler: (@Sendable (Int) -> Void)?
        if reportProgress {
            pingHandler = { (_: Int) in
                let nowUp = ProcessInfo.processInfo.systemUptime
                let shouldPost: Int? = progressLock.withLock { state -> Int? in
                    state.totalFolders += 2500
                    // Throttle UI progress updates to <= 4/sec (every 0.25s, §4.2)
                    if nowUp - state.lastUptime >= 0.25 {
                        state.lastUptime = nowUp
                        return state.totalFolders
                    }
                    return nil
                }
                if let countSnap = shouldPost {
                    Task { @MainActor in
                        GoogleDriveIndexService.shared.rebuildProgressText = L(
                            "Đang quét: \(countSnap.formatted()) thư mục...",
                            "Scanning: \(countSnap.formatted()) folders..."
                        )
                    }
                }
            }
        } else {
            pingHandler = nil
        }

        var mergedFolders: [DriveFolderEntry] = []
        mergedFolders.reserveCapacity(60_000)
        var mergedFiles: [DriveFileEntry] = rootLevelFiles
        mergedFiles.reserveCapacity(60_000)

        let unitsSnap = workUnits
        await withTaskGroup(of: SubtreeScanChunk.self) { group in
            var nextIdx = 0
            let initialBatch = min(maxConcurrent, unitsSnap.count)
            while nextIdx < initialBatch {
                let u = unitsSnap[nextIdx]
                nextIdx += 1
                group.addTask {
                    Self.scanSubtreeSinglePassPOSIX(
                        startDir: u.startDir,
                        initialDepth: u.initialDepth,
                        maxDepth: u.maxDepth,
                        collectFolders: u.collectFolders,
                        initialCleanSegs: u.initialCleanSegs,
                        initialAcrSegs: u.initialAcrSegs,
                        initialCleanParent: u.initialCleanParent,
                        maxFiles: 80_000,
                        progressPing: pingHandler
                    )
                }
            }

            while let chunk = await group.next() {
                mergedFolders.append(contentsOf: chunk.folders)
                if mergedFiles.count < 200_000 {
                    mergedFiles.append(contentsOf: chunk.files)
                }
                if nextIdx < unitsSnap.count {
                    let u = unitsSnap[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        Self.scanSubtreeSinglePassPOSIX(
                            startDir: u.startDir,
                            initialDepth: u.initialDepth,
                            maxDepth: u.maxDepth,
                            collectFolders: u.collectFolders,
                            initialCleanSegs: u.initialCleanSegs,
                            initialAcrSegs: u.initialAcrSegs,
                            initialCleanParent: u.initialCleanParent,
                            maxFiles: 80_000,
                            progressPing: pingHandler
                        )
                    }
                }
            }
        }

        mergedFolders.sort { $0.path < $1.path }
        return (mergedFolders, mergedFiles)
    }

    func rebuildSharedCacheInBackground() {
        guard !isRebuildingShared else { return }
        let mounts = activeAccounts
        guard mounts.contains(where: { $0.sharedDrivesPath != nil || $0.shortcutTargetsPath != nil }) else { return }

        isRebuildingShared = true

        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var items: [SharedDriveEntry] = []

            for mount in mounts {
                if let sdPath = mount.sharedDrivesPath, let drives = try? fm.contentsOfDirectory(atPath: sdPath) {
                    for d in drives where !d.hasPrefix(".") {
                        let drivePath = "\(sdPath)/\(d)"
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: drivePath, isDirectory: &isDir), isDir.boolValue else { continue }
                        let (c, a) = Self.extractSignatures(d)
                        let sharedPrefix = L("Bộ nhớ dùng chung", "Shared Drives")
                        items.append(SharedDriveEntry(
                            path: drivePath,
                            isDir: true,
                            displaySub: "\(sharedPrefix)/\(d)",
                            cleanSegs: ["bonhodungchungshareddrives", c],
                            acrSegs: ["", a]
                        ))
                        _ = Self.walkSharedTree(
                            rootDir: drivePath,
                            baseStripPath: sdPath,
                            prefixDisplay: sharedPrefix,
                            prefixClean: "bonhodungchungshareddrives",
                            maxDepth: 8,
                            maxItems: 80_000,
                            into: &items
                        )
                    }
                }

                if let stPath = mount.shortcutTargetsPath, let targetIDs = try? fm.contentsOfDirectory(atPath: stPath) {
                    for tid in targetIDs where !tid.hasPrefix(".") {
                        let idDir = "\(stPath)/\(tid)"
                        guard let names = try? fm.contentsOfDirectory(atPath: idDir) else { continue }
                        for name in names where !name.hasPrefix(".") {
                            let itemPath = "\(idDir)/\(name)"
                            var isDir: ObjCBool = false
                            guard fm.fileExists(atPath: itemPath, isDirectory: &isDir) else { continue }
                            let (c, a) = Self.extractSignatures(name)
                            let sharedWithMePrefix = L("Được chia sẻ", "Shared With Me")
                            items.append(SharedDriveEntry(
                                path: itemPath,
                                isDir: isDir.boolValue,
                                displaySub: "\(sharedWithMePrefix)/\(name)",
                                cleanSegs: ["duocchiase", c],
                                acrSegs: ["", a]
                            ))
                            if isDir.boolValue {
                                _ = Self.walkSharedTree(
                                    rootDir: itemPath,
                                    baseStripPath: idDir,
                                    prefixDisplay: sharedWithMePrefix,
                                    prefixClean: "duocchiase",
                                    maxDepth: 8,
                                    maxItems: 80_000,
                                    into: &items
                                )
                            }
                        }
                    }
                }
            }

            let finalFastShared = FastSharedIndex.build(from: items)
            await MainActor.run {
                let service = GoogleDriveIndexService.shared
                service.fastSharedIndex = finalFastShared
                service.sharedCount = finalFastShared.count
                service.isRebuildingShared = false
                Self.sharedRefineLock.withLock { $0 = nil }
                service.scheduleBinaryIndexPersist(delayNanoseconds: 0)
                if AppSettings.shared.keepAlfredCacheCompatible {
                    service.scheduleAlfredCompatibilityJSONPersist()
                }
                if !service.pendingEventPaths.isEmpty {
                    service.processPendingFSEvents()
                }
            }
        }
    }

    @discardableResult
    private nonisolated static func walkSharedTree(
        rootDir: String,
        baseStripPath: String,
        prefixDisplay: String,
        prefixClean: String,
        maxDepth: Int = 8,
        maxItems: Int = 80_000,
        into items: inout [SharedDriveEntry]
    ) -> Bool {
        let baseLen = baseStripPath.count + 1
        let rootRel = rootDir.hasPrefix(baseStripPath + "/") ? String(rootDir.dropFirst(baseLen)) : (rootDir as NSString).lastPathComponent
        let rootSegs = rootRel.split(separator: "/").map(String.init)
        let rootSigs = rootSegs.map { extractSignatures($0) }

        struct SharedFrame {
            let dir: String
            let depth: Int
            let relDisplay: String
            let cleanSegs: [String]
            let acrSegs: [String]
        }

        var stack: [SharedFrame] = [
            SharedFrame(
                dir: rootDir,
                depth: 0,
                relDisplay: rootRel,
                cleanSegs: [prefixClean] + rootSigs.map(\.clean),
                acrSegs: [""] + rootSigs.map(\.acronym)
            )
        ]
        let startCount = items.count
        var hitCap = false

        while let frame = stack.popLast() {
            if frame.depth > maxDepth { continue }
            if (items.count - startCount) >= maxItems {
                hitCap = true
                break
            }
            guard let dirPtr = Darwin.opendir(frame.dir) else { continue }
            var childFrames: [SharedFrame] = []

            while let ent = Darwin.readdir(dirPtr) {
                let nameLen = Int(ent.pointee.d_namlen)
                guard nameLen > 0 else { continue }
                let dType = ent.pointee.d_type

                let name: String = withUnsafePointer(to: ent.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { utf8Ptr in
                        String(decoding: UnsafeBufferPointer(start: utf8Ptr, count: nameLen), as: UTF8.self)
                    }
                }
                if name.isEmpty || shouldSkip(name) || name == "Icon\r" { continue }

                let full = "\(frame.dir)/\(name)"
                let isDir: Bool
                if dType == DT_DIR {
                    isDir = true
                } else if dType == DT_REG || dType == DT_LNK {
                    isDir = false
                } else {
                    isDir = (name as NSString).pathExtension.isEmpty
                }

                let (c, a) = extractSignatures(name)
                let nextClean = frame.cleanSegs + [c]
                let nextAcr = frame.acrSegs + [a]
                let nextRel = frame.relDisplay.isEmpty ? name : "\(frame.relDisplay)/\(name)"

                items.append(SharedDriveEntry(
                    path: full,
                    isDir: isDir,
                    displaySub: "\(prefixDisplay)/\(nextRel)",
                    cleanSegs: nextClean,
                    acrSegs: nextAcr
                ))
                if (items.count - startCount) >= maxItems {
                    hitCap = true
                    break
                }
                if isDir && frame.depth < maxDepth {
                    childFrames.append(SharedFrame(
                        dir: full,
                        depth: frame.depth + 1,
                        relDisplay: nextRel,
                        cleanSegs: nextClean,
                        acrSegs: nextAcr
                    ))
                }
            }
            Darwin.closedir(dirPtr)

            for cf in childFrames.reversed() {
                stack.append(cf)
            }
        }
        return hitCap
    }

    func rebuildMacFoldersCacheInBackground() {
        macFoldersRebuildGen &+= 1
        let gen = macFoldersRebuildGen
        let rawRoots = AppSettings.shared.customMacFolders.map {
            $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0
        }
        var uniqueRoots: [String] = []
        var seenRoots = Set<String>()
        for r in rawRoots where !r.isEmpty && seenRoots.insert(r).inserted {
            uniqueRoots.append(r)
        }

        if uniqueRoots.isEmpty {
            fastMacFolderIndex = .empty
            macFolderItemCount = 0
            macFolderRootsSnapshot = []
            isRebuildingMacFolders = false
            let targetCache = macFoldersCachePath
            Task.detached(priority: .background) {
                try? FileManager.default.removeItem(atPath: targetCache)
            }
            scheduleBinaryIndexPersist(delayNanoseconds: 0)
            if LauncherPanelController.shared.isVisible {
                LauncherViewModel.shared.refreshSearchResults()
            }
            return
        }

        isRebuildingMacFolders = true
        let targetCache = macFoldersCachePath
        let homeSnap = homePath

        Task.detached(priority: .utility) {
            var collected: [SharedDriveEntry] = []
            collected.reserveCapacity(16_384)
            let maxItems = 120_000
            var seenPaths = Set<String>()

            for root in uniqueRoots {
                guard collected.count < maxItems else { break }
                var subItems: [SharedDriveEntry] = []
                Self.scanMacFolderSubtreePOSIX(
                    startDir: root,
                    rootDir: root,
                    homePath: homeSnap,
                    maxSubDepth: 8,
                    maxLimit: maxItems - collected.count,
                    into: &subItems
                )
                for item in subItems where seenPaths.insert(item.path).inserted {
                    collected.append(item)
                }
            }

            try? FileManager.default.removeItem(atPath: targetCache)
            let builtFast = FastSharedIndex.build(from: collected)
            await MainActor.run {
                let svc = GoogleDriveIndexService.shared
                guard svc.macFoldersRebuildGen == gen else { return }
                svc.fastMacFolderIndex = builtFast
                svc.macFolderItemCount = builtFast.count
                svc.macFolderRootsSnapshot = uniqueRoots
                svc.isRebuildingMacFolders = false
                svc.scheduleBinaryIndexPersist(delayNanoseconds: 0)
                if LauncherPanelController.shared.isVisible {
                    LauncherViewModel.shared.refreshSearchResults()
                }
            }
        }
    }

    private nonisolated static let skippedMacIndexDirNames: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", ".venv", "venv", "__pycache__",
        ".build", "build", "deriveddata", "pods", "library", ".trash", "trash",
        ".cache", ".npm", ".gradle", ".cargo"
    ]

    private nonisolated static func makeSingleMacEntry(
        path: String,
        isDir: Bool,
        rootDir: String,
        homePath: String
    ) -> SharedDriveEntry? {
        let name = (path as NSString).lastPathComponent
        if name.isEmpty || name.hasPrefix(".") || name == "Icon\r" { return nil }
        if !isDir {
            let ext = (name as NSString).pathExtension.lowercased()
            if ext == "tmp" || ext == "part" || ext == "crdownload" || ext == "ds_store" { return nil }
        }

        let rootParent = (rootDir as NSString).deletingLastPathComponent
        let rel: String
        if rootParent != "/" && path.hasPrefix(rootParent + "/") {
            rel = String(path.dropFirst(rootParent.count + 1))
        } else {
            rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        }

        let segs = rel.split(separator: "/").map(String.init)
        var cleanSegs: [String] = []
        var acrSegs: [String] = []
        cleanSegs.reserveCapacity(segs.count)
        acrSegs.reserveCapacity(segs.count)

        for (idx, seg) in segs.enumerated() {
            let isLeafFile = (!isDir && idx == segs.count - 1)
            if isLeafFile {
                let ext = (seg as NSString).pathExtension.lowercased()
                let stem = ext.isEmpty ? seg : (seg as NSString).deletingPathExtension
                let (cStem, acr) = extractSignatures(stem)
                cleanSegs.append(ext.isEmpty ? cStem : "\(cStem)\(ext)")
                acrSegs.append(acr)
            } else {
                let (c, a) = extractSignatures(seg)
                cleanSegs.append(c)
                acrSegs.append(a)
            }
        }

        let displaySub = path.replacingOccurrences(of: homePath, with: "~")
        return SharedDriveEntry(
            path: path,
            isDir: isDir,
            displaySub: displaySub,
            cleanSegs: cleanSegs,
            acrSegs: acrSegs
        )
    }

    private nonisolated static func scanMacFolderSubtreePOSIX(
        startDir: String,
        rootDir: String,
        homePath: String,
        maxSubDepth: Int,
        maxLimit: Int,
        into out: inout [SharedDriveEntry]
    ) {
        guard maxLimit > 0 else { return }
        var stRoot = Darwin.stat()
        guard Darwin.lstat(startDir, &stRoot) == 0, (stRoot.st_mode & S_IFMT) == S_IFDIR else { return }

        if let rootEntry = makeSingleMacEntry(path: startDir, isDir: true, rootDir: rootDir, homePath: homePath) {
            out.append(rootEntry)
        }

        var stack: [(dir: String, depth: Int)] = [(startDir, 0)]
        let initialCount = out.count

        while let (curDir, depth) = stack.popLast() {
            if (out.count - initialCount) >= maxLimit { break }
            guard let dirPtr = Darwin.opendir(curDir) else { continue }
            var childDirs: [String] = []

            while let ent = Darwin.readdir(dirPtr) {
                let nameLen = Int(ent.pointee.d_namlen)
                guard nameLen > 0 else { continue }
                let dType = ent.pointee.d_type

                let name: String = withUnsafePointer(to: ent.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { utf8Ptr in
                        String(decoding: UnsafeBufferPointer(start: utf8Ptr, count: nameLen), as: UTF8.self)
                    }
                }
                if name.isEmpty || name.hasPrefix(".") || name == "Icon\r" { continue }

                let fullPath = curDir == "/" ? "/\(name)" : "\(curDir)/\(name)"
                let isDirectory: Bool
                if dType == DT_DIR {
                    isDirectory = true
                } else if dType == DT_REG || dType == DT_LNK {
                    isDirectory = false
                } else {
                    if fullPath.contains("/Library/CloudStorage/") {
                        isDirectory = (name as NSString).pathExtension.isEmpty
                    } else {
                        var st = Darwin.stat()
                        isDirectory = (Darwin.lstat(fullPath, &st) == 0) && ((st.st_mode & S_IFMT) == S_IFDIR)
                    }
                }

                if isDirectory {
                    let lowerName = name.lowercased()
                    if skippedMacIndexDirNames.contains(lowerName) { continue }
                    let ext = (name as NSString).pathExtension.lowercased()
                    let isPackageBundle = skipExtensions.contains(ext)
                    if let dirEntry = makeSingleMacEntry(path: fullPath, isDir: !isPackageBundle, rootDir: rootDir, homePath: homePath) {
                        out.append(dirEntry)
                        if (out.count - initialCount) >= maxLimit { break }
                    }
                    if !isPackageBundle && depth < maxSubDepth {
                        childDirs.append(fullPath)
                    }
                } else {
                    if let fileEntry = makeSingleMacEntry(path: fullPath, isDir: false, rootDir: rootDir, homePath: homePath) {
                        out.append(fileEntry)
                        if (out.count - initialCount) >= maxLimit { break }
                    }
                }
            }
            Darwin.closedir(dirPtr)

            childDirs.sort()
            for sub in childDirs.reversed() {
                stack.append((sub, depth + 1))
            }
        }
    }

    private nonisolated static func writeQueue(for filePath: String) -> DispatchQueue {
        fileWriteQueuesLock.withLock { dict in
            if let existing = dict[filePath] {
                return existing
            }
            let q = DispatchQueue(label: "com.hunglx.DriveBar.cachewrite.\(filePath.hashValue)", qos: .utility)
            dict[filePath] = q
            return q
        }
    }

    private nonisolated static func cleanupStaleTempFiles(in dirPath: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dirPath) else { return }
        for name in names where name.contains(".tmp.") {
            try? fm.removeItem(atPath: "\(dirPath)/\(name)")
        }
    }

    private nonisolated static func writeCodableAtomic<T: Encodable>(_ value: T, to filePath: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        writeQueue(for: filePath).sync {
            let fm = FileManager.default
            let dir = (filePath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        }
    }

    // MARK: - History Management & Cross-Mac Portable Syncthing Sync

    func recordUsed(_ path: String, query: String? = nil) {
        let now = Date().timeIntervalSince1970
        let isSpecialOrBundle = path.hasPrefix("sys:") || path.lowercased().hasSuffix(".app")
        let ext = isSpecialOrBundle ? "" : (path as NSString).pathExtension
        let looksLikeFile = !isSpecialOrBundle && !ext.isEmpty && !Self.skipExtensions.contains(ext.lowercased())
        let targetDir = looksLikeFile ? (path as NSString).deletingLastPathComponent : path

        var dirRec = history[targetDir] ?? HistoryRecord(count: 0, last_used: now)
        dirRec.count += 1
        dirRec.last_used = now
        history[targetDir] = dirRec

        if looksLikeFile {
            var fileRec = history[path] ?? HistoryRecord(count: 0, last_used: now)
            fileRec.count += 1
            fileRec.last_used = now
            history[path] = fileRec
        }

        if history.count > 500 {
            let sorted = history.sorted { $0.value.last_used > $1.value.last_used }.prefix(500)
            history = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
        }

        if let rawQuery = query {
            let trimmedQ = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanQ = Self.cleanString(trimmedQ)
            if !cleanQ.isEmpty && !trimmedQ.hasPrefix("/") {
                var itemMap = queryHistory[cleanQ] ?? [:]
                var qRec = itemMap[path] ?? QueryLatchRecord(count: 0, last_used: now)
                qRec.count += 1
                qRec.last_used = now
                itemMap[path] = qRec
                if itemMap.count > 16 {
                    let topItems = itemMap.sorted { $0.value.last_used > $1.value.last_used }.prefix(16)
                    itemMap = Dictionary(uniqueKeysWithValues: topItems.map { ($0.key, $0.value) })
                }
                queryHistory[cleanQ] = itemMap
                if queryHistory.count > 400 {
                    let topQueries = queryHistory.sorted { a, b in
                        let maxA = a.value.values.map(\.last_used).max() ?? 0
                        let maxB = b.value.values.map(\.last_used).max() ?? 0
                        return maxA > maxB
                    }.prefix(400)
                    queryHistory = Dictionary(uniqueKeysWithValues: topQueries.map { ($0.key, $0.value) })
                }
            }
        }

        persistHistoryAndPushSync()
    }

    func removeFromHistory(_ path: String) {
        history.removeValue(forKey: path)
        for qKey in Array(queryHistory.keys) {
            queryHistory[qKey]?.removeValue(forKey: path)
            if queryHistory[qKey]?.isEmpty == true {
                queryHistory.removeValue(forKey: qKey)
            }
        }
        persistHistoryAndPushSync()
    }

    func clearAllHistory() {
        history.removeAll()
        queryHistory.removeAll()
        try? FileManager.default.removeItem(atPath: historyPath)
        try? FileManager.default.removeItem(atPath: queryHistoryPath)
        if AppSettings.shared.enableSyncthingSync {
            SyncAndLatchingService.shared.pushPortableHistory([:])
        }
    }

    private func persistHistoryAndPushSync() {
        let snap = history
        let qSnap = queryHistory
        let hPath = historyPath
        let qPath = queryHistoryPath
        Task.detached(priority: .background) {
            Self.writeCodableAtomic(snap, to: hPath)
            Self.writeCodableAtomic(qSnap, to: qPath)
        }
        if AppSettings.shared.enableSyncthingSync {
            SyncAndLatchingService.shared.pushPortableHistory(exportPortableHistoryMap())
        }
    }

    // MARK: - Smart Keyword Prefix History & Frecency Latching

    func hasHistoryOrQueryLatch(forSystemCommand cmdID: String, queryNorm: String) -> Bool {
        let cleanQ = Self.cleanString(queryNorm)
        guard !cleanQ.isEmpty else { return false }
        let sysKey = "sys:\(cmdID)"

        for (storedQ, itemMap) in queryHistory where storedQ == cleanQ || storedQ.hasPrefix(cleanQ) {
            if let qRec = itemMap[sysKey], qRec.count > 0 {
                return true
            }
        }

        if let hRec = history[sysKey], hRec.count > 0,
           let def = InstantUtilityService.allSystemCommands.first(where: { $0.id == cmdID }) {
            if Self.cleanString(def.primaryKeyword).hasPrefix(cleanQ) {
                return true
            }
            if def.inlineExactKeywords.contains(where: { Self.cleanString($0).hasPrefix(cleanQ) }) {
                return true
            }
            if def.inlinePhrasePrefixes.contains(where: { Self.cleanString($0).hasPrefix(cleanQ) }) {
                return true
            }
        }
        return false
    }

    func systemCommandPriorityScore(for cmdID: String, queryNorm: String) -> Int {
        let cleanQ = Self.cleanString(queryNorm)
        let sysKey = "sys:\(cmdID)"
        var score = 0
        for (storedQ, itemMap) in queryHistory where storedQ == cleanQ || storedQ.hasPrefix(cleanQ) {
            if let qRec = itemMap[sysKey], qRec.count > 0 {
                let base = (storedQ == cleanQ) ? 5_000 : 3_500
                score = max(score, base + min(qRec.count * 250, 2_500))
            }
        }
        if let hRec = history[sysKey], hRec.count > 0 {
            score += 1_000 + min(hRec.count * 150, 1_500)
        }
        return score
    }

    func recallPreviouslyUsedItems(
        for rawQuery: String,
        isSharedMode: Bool,
        maxItems: Int = 6
    ) -> [SearchResultItem] {
        let cleanQ = Self.cleanString(rawQuery)
        guard !cleanQ.isEmpty else { return [] }
        let cleanTokens = rawQuery.split(separator: " ").map(String.init).map(Self.cleanString).filter { !$0.isEmpty }
        let now = Date().timeIntervalSince1970

        var candidateScores: [String: (score: Int, lastUsed: Double)] = [:]

        func updateCandidate(_ key: String, score: Int, lastUsed: Double) {
            if let existing = candidateScores[key] {
                if score > existing.score || (score == existing.score && lastUsed > existing.lastUsed) {
                    candidateScores[key] = (score, lastUsed)
                }
            } else {
                candidateScores[key] = (score, lastUsed)
            }
        }

        // 1. Direct & prefix query-to-item latch recall (`queryHistory`)
        for (storedQ, itemMap) in queryHistory where storedQ == cleanQ || storedQ.hasPrefix(cleanQ) {
            for (itemKey, qRec) in itemMap where qRec.count > 0 {
                let ageHours = max(0, (now - qRec.last_used) / 3600.0)
                let recencyBonus = ageHours < 24 ? 800 : (ageHours < 168 ? 400 : 100)
                let base = (storedQ == cleanQ) ? 12_000 : 8_500
                let lenDiff = max(0, storedQ.count - cleanQ.count)
                let proximityBonus = max(0, 300 - lenDiff * 30)
                let sc = base + min(qRec.count * 400, 4_000) + recencyBonus + proximityBonus
                updateCandidate(itemKey, score: sc, lastUsed: qRec.last_used)
            }
        }

        // 2. General opened history (`history`) whose leaf name / keyword starts with the typed query
        let sdPrefixes = activeAccounts.compactMap(\.sharedDrivesPath) + activeAccounts.compactMap(\.shortcutTargetsPath)

        for (itemKey, hRec) in history where hRec.count > 0 {
            let ageHours = max(0, (now - hRec.last_used) / 3600.0)
            let recencyBonus = ageHours < 24 ? 600 : (ageHours < 168 ? 300 : 80)

            if itemKey.hasPrefix("sys:") {
                let cmdID = String(itemKey.dropFirst(4))
                if AppSettings.shared.isSystemCommandEnabled(cmdID),
                   let def = InstantUtilityService.allSystemCommands.first(where: { $0.id == cmdID }) {
                    let matchesSys = Self.cleanString(def.primaryKeyword).hasPrefix(cleanQ) ||
                        def.inlineExactKeywords.contains { Self.cleanString($0).hasPrefix(cleanQ) } ||
                        def.inlinePhrasePrefixes.contains { Self.cleanString($0).hasPrefix(cleanQ) }
                    if matchesSys {
                        let sc = 6_000 + min(hRec.count * 250, 2_500) + recencyBonus
                        updateCandidate(itemKey, score: sc, lastUsed: hRec.last_used)
                    }
                }
            } else if itemKey.lowercased().hasSuffix(".app") {
                guard cleanQ.count >= 2 && AppSettings.shared.includeMacAppsInSearch else { continue }
                if let app = installedApps.first(where: { $0.path == itemKey }) {
                    let matchesApp = app.cleanFull.hasPrefix(cleanQ) ||
                        app.cleanFullVI.hasPrefix(cleanQ) ||
                        (!app.acronym.isEmpty && app.acronym.hasPrefix(cleanQ)) ||
                        (!app.acronymVI.isEmpty && app.acronymVI.hasPrefix(cleanQ)) ||
                        app.words.contains { $0.hasPrefix(cleanQ) }
                    if matchesApp {
                        let sc = 5_200 + min(hRec.count * 220, 2_200) + recencyBonus
                        updateCandidate(itemKey, score: sc, lastUsed: hRec.last_used)
                    }
                }
            } else {
                guard cleanQ.count >= 2 else { continue }
                let isSharedPath = sdPrefixes.contains { itemKey.hasPrefix($0) }
                if isSharedMode != isSharedPath { continue }

                let leafName = (itemKey as NSString).lastPathComponent
                let ext = (leafName as NSString).pathExtension
                let stem = ext.isEmpty ? leafName : (leafName as NSString).deletingPathExtension
                let (leafClean, leafAcr) = Self.extractSignatures(stem)
                guard !leafClean.isEmpty else { continue }

                let leafBytes = Array(leafClean.utf8)
                let stripIdx = Self.firstNonDigitIndex(leafBytes)
                let leafStripDigits = stripIdx > 0 ? String(decoding: leafBytes[stripIdx...], as: UTF8.self) : leafClean
                let leafWords = Self.extractAppWords(stem)

                let isDirectLeafPrefix = leafClean.hasPrefix(cleanQ) ||
                    leafStripDigits.hasPrefix(cleanQ) ||
                    (!leafAcr.isEmpty && leafAcr.hasPrefix(cleanQ))
                let isMultiWordLeafPrefix = !cleanTokens.isEmpty && cleanTokens.allSatisfy { tok in
                    tok.count >= 2 && leafWords.contains { $0.hasPrefix(tok) }
                }

                if isDirectLeafPrefix || isMultiWordLeafPrefix {
                    let exactBonus = (leafClean == cleanQ || leafStripDigits == cleanQ || leafAcr == cleanQ) ? 800 : 0
                    let sc = 4_800 + exactBonus + min(hRec.count * 200, 2_000) + recencyBonus
                    updateCandidate(itemKey, score: sc, lastUsed: hRec.last_used)
                }
            }
        }

        guard !candidateScores.isEmpty else { return [] }

        let sortedCandidates = candidateScores.sorted { a, b in
            if a.value.score != b.value.score { return a.value.score > b.value.score }
            if a.value.lastUsed != b.value.lastUsed { return a.value.lastUsed > b.value.lastUsed }
            return a.key < b.key
        }

        var items: [SearchResultItem] = []
        items.reserveCapacity(min(sortedCandidates.count, maxItems))

        for (itemKey, _) in sortedCandidates {
            if items.count >= maxItems { break }

            if itemKey.hasPrefix("sys:") {
                let cmdID = String(itemKey.dropFirst(4))
                guard AppSettings.shared.isSystemCommandEnabled(cmdID),
                      let def = InstantUtilityService.allSystemCommands.first(where: { $0.id == cmdID }) else {
                    continue
                }
                items.append(InstantUtilityService.makeResultItem(def, settings: AppSettings.shared))
            } else if itemKey.lowercased().hasSuffix(".app") {
                guard AppSettings.shared.includeMacAppsInSearch,
                      let app = installedApps.first(where: { $0.path == itemKey }) else {
                    continue
                }
                let hCount = max(1, history[itemKey]?.count ?? 1)
                items.append(Self.makeAppSearchResultItem(app: app, historyCount: hCount, isRunning: false))
            } else {
                let isSharedPath = sdPrefixes.contains { itemKey.hasPrefix($0) }
                if isSharedMode != isSharedPath { continue }

                let isKnownFolder = fastFolderIndex.containsPath(itemKey) ||
                    (fastSharedIndex.isDir(forPath: itemKey) == true) ||
                    (fastMacFolderIndex.isDir(forPath: itemKey) == true)
                let isKnownSharedFile = (fastSharedIndex.isDir(forPath: itemKey) == false) ||
                    (fastMacFolderIndex.isDir(forPath: itemKey) == false)
                let isKnownDriveFile = fastFileIndex.containsPath(itemKey)

                if !isKnownFolder && !isKnownSharedFile && !isKnownDriveFile {
                    if itemKey.contains("/Library/CloudStorage/") { continue }
                    if !FileManager.default.fileExists(atPath: itemKey) { continue }
                }

                let isDir = isKnownFolder || (!isKnownSharedFile && !isKnownDriveFile && isKnownDirectory(itemKey))
                let hCount = max(1, history[itemKey]?.count ?? 1)
                let sub = "\(L("Mở gần đây (\(hCount) lần)", "Recently opened (\(hCount) times)")) ‹ \(formatHierarchicalSubtitle(itemKey))"
                let ext = URL(fileURLWithPath: itemKey).pathExtension.uppercased()

                items.append(SearchResultItem(
                    id: "recalled:\(itemKey)",
                    title: (itemKey as NSString).lastPathComponent,
                    subtitle: sub,
                    path: itemKey,
                    isDirectory: isDir,
                    kind: isDir ? .driveFolder(path: itemKey) : .driveFile(path: itemKey),
                    badge: isSharedMode ? "Shared" : (isDir ? nil : (ext.isEmpty ? nil : ext)),
                    sfSymbolFallback: isDir ? "folder.fill" : "doc.fill"
                ))
            }
        }

        return items
    }

    /// Converts local `/Users/hunglx/Library/CloudStorage/GoogleDrive-email/My Drive/...`
    /// into portable `<email>::My Drive/...` so iMac (`hunglx`) and MacBook Pro (`hunglexuan`) sync seamlessly.
    private func exportPortableHistoryMap() -> [String: HistoryRecord] {
        var out: [String: HistoryRecord] = [:]
        for (absPath, rec) in history {
            if let acc = accountForPath(absPath), absPath.hasPrefix(acc.rootPath + "/") {
                let rel = String(absPath.dropFirst(acc.rootPath.count + 1))
                out["\(acc.email)::\(rel)"] = rec
            }
        }
        return out
    }

    func exportPortablePathList(_ paths: [String]) -> [String] {
        paths.map { absPath in
            if let acc = accountForPath(absPath), absPath.hasPrefix(acc.rootPath + "/") {
                let rel = String(absPath.dropFirst(acc.rootPath.count + 1))
                return "gdrive::\(acc.email)::\(rel)"
            }
            if absPath.hasPrefix(homePath + "/") {
                return "~/" + String(absPath.dropFirst(homePath.count + 1))
            }
            return absPath
        }
    }

    func resolvePortablePathList(_ portablePaths: [String]) -> [String] {
        portablePaths.compactMap { item in
            if item.hasPrefix("gdrive::") {
                let rest = String(item.dropFirst("gdrive::".count))
                if let sepRange = rest.range(of: "::") {
                    let email = String(rest[..<sepRange.lowerBound])
                    let rel = String(rest[sepRange.upperBound...])
                    if let acc = availableAccounts.first(where: { $0.email == email }) ?? availableAccounts.first {
                        return "\(acc.rootPath)/\(rel)"
                    }
                }
                return nil
            }
            if item.hasPrefix("~/") {
                return homePath + String(item.dropFirst(1))
            }
            return item
        }
    }

    func mergeWithPortableSyncFile(at remoteFilePath: String) -> Int {
        var remoteMap: [String: HistoryRecord] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: remoteFilePath)),
           let decoded = try? JSONDecoder().decode([String: HistoryRecord].self, from: data) {
            remoteMap = decoded
        }

        var localChanged = false
        for (portableKey, rRec) in remoteMap {
            let resolvedPath: String?
            if let sepRange = portableKey.range(of: "::") {
                let email = String(portableKey[..<sepRange.lowerBound])
                let rel = String(portableKey[sepRange.upperBound...])
                if let matchAcc = availableAccounts.first(where: { $0.email == email }) ?? availableAccounts.first {
                    resolvedPath = "\(matchAcc.rootPath)/\(rel)"
                } else {
                    resolvedPath = nil
                }
            } else if let primary = accountRoot {
                resolvedPath = "\(primary)/\(portableKey)"
            } else {
                resolvedPath = nil
            }

            guard let absPath = resolvedPath else { continue }
            if let lRec = history[absPath] {
                if rRec.count > lRec.count || rRec.last_used > lRec.last_used {
                    history[absPath] = HistoryRecord(
                        count: max(lRec.count, rRec.count),
                        last_used: max(lRec.last_used, rRec.last_used)
                    )
                    localChanged = true
                }
            } else {
                history[absPath] = rRec
                localChanged = true
            }
        }

        if localChanged {
            let snap = history
            let hPath = historyPath
            Task.detached(priority: .utility) {
                Self.writeCodableAtomic(snap, to: hPath)
            }
            if LauncherPanelController.shared.isVisible {
                LauncherViewModel.shared.refreshSearchResults()
            }
        }

        let combinedPortable = exportPortableHistoryMap()
        if combinedPortable.count > remoteMap.count {
            SyncAndLatchingService.shared.pushPortableHistory(combinedPortable)
        }
        return combinedPortable.count
    }

    // MARK: - Reversed Breadcrumb Subtitle

    func formatHierarchicalSubtitle(_ path: String, maxLevels: Int? = nil) -> String {
        let multiAccount = activeAccounts.count > 1
        guard let acc = accountForPath(path) else {
            let parent = (path as NSString).deletingLastPathComponent
            let prettyParent = parent.replacingOccurrences(of: homePath, with: "~")
            guard let maxLevels, maxLevels > 0 else {
                return prettyParent
            }
            let parts = prettyParent.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.count <= maxLevels {
                return prettyParent
            }
            let tail = parts.suffix(maxLevels).reversed().joined(separator: " ‹ ")
            return prettyParent.hasPrefix("~") ? "\(tail) ‹ ~" : tail
        }

        var baseLabel = ""
        var rel = ""

        if let md = acc.myDrivePath, path.hasPrefix(md + "/") {
            rel = String(path.dropFirst(md.count + 1))
            baseLabel = multiAccount ? "My Drive (\(acc.email))" : "My Drive"
        } else if let sd = acc.sharedDrivesPath, path.hasPrefix(sd + "/") {
            rel = String(path.dropFirst(sd.count + 1))
            let sharedTitle = L("Bộ nhớ dùng chung", "Shared Drives")
            baseLabel = multiAccount ? "\(sharedTitle) (\(acc.email))" : sharedTitle
        } else if let st = acc.shortcutTargetsPath, path.hasPrefix(st + "/") {
            let relSt = String(path.dropFirst(st.count + 1))
            let parts = relSt.split(separator: "/").map(String.init)
            rel = parts.count > 1 ? parts.dropFirst().joined(separator: "/") : (parts.first ?? "")
            let sharedWithMeTitle = L("Được chia sẻ", "Shared With Me")
            baseLabel = multiAccount ? "\(sharedWithMeTitle) (\(acc.email))" : sharedWithMeTitle
        } else if path.hasPrefix(acc.rootPath + "/") {
            rel = String(path.dropFirst(acc.rootPath.count + 1))
            baseLabel = multiAccount ? "Google Drive (\(acc.email))" : "Google Drive"
        } else {
            return (path as NSString).deletingLastPathComponent.replacingOccurrences(of: homePath, with: "~")
        }

        let parts = rel.split(separator: "/").map(String.init)
        let ancestors = parts.dropLast()
        if ancestors.isEmpty {
            return baseLabel.isEmpty ? L("Thư mục gốc", "Root Folder") : baseLabel
        }

        var reversed = Array(ancestors.reversed())
        if let maxLevels, reversed.count > maxLevels {
            reversed = Array(reversed.prefix(maxLevels))
        } else if !baseLabel.isEmpty {
            reversed.append(baseLabel)
        }
        return reversed.joined(separator: " ‹ ")
    }

    // MARK: - Zero-Syscall RAM Directory & Recent Lookups

    func isKnownDirectory(_ path: String, hasDirectoryHint: Bool = false) -> Bool {
        if hasDirectoryHint { return true }
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if fastFolderIndex.containsPath(trimmed) { return true }
        if let shDir = fastSharedIndex.isDir(forPath: trimmed) { return shDir }
        if let mfDir = fastMacFolderIndex.isDir(forPath: trimmed) { return mfDir }
        if availableAccounts.contains(where: {
            trimmed == $0.rootPath || trimmed == $0.myDrivePath || trimmed == $0.sharedDrivesPath || trimmed == $0.shortcutTargetsPath
        }) {
            return true
        }
        if !trimmed.contains("/Library/CloudStorage/") {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir) && isDir.boolValue
        }
        let ext = (trimmed as NSString).pathExtension
        return ext.isEmpty || ext.contains(" ")
    }

    func pinnedSearchResultItems() -> [SearchResultItem] {
        let pinned = AppSettings.shared.pinnedPaths
        guard !pinned.isEmpty else { return [] }
        var out: [SearchResultItem] = []
        let pinnedBadge = L("Đã ghim", "Pinned")
        let unpinHint = L("Đã ghim (⌘D bỏ ghim)", "Pinned (⌘D to unpin)")
        for p in pinned {
            let lower = p.lowercased()
            if lower.hasSuffix(".app") {
                let appLoc = AppLocalization.localizedBundleNames(forAppAt: p)
                let appTitle = AppLocalization.isVietnamese ? appLoc.vi : appLoc.en
                out.append(SearchResultItem(
                    id: "pin:app:\(p)",
                    title: appTitle,
                    subtitle: "\(unpinHint) • \(p)",
                    path: p,
                    isDirectory: false,
                    kind: .localApp(path: p),
                    badge: pinnedBadge,
                    sfSymbolFallback: "app.fill"
                ))
            } else {
                let isDir = isKnownDirectory(p)
                out.append(SearchResultItem(
                    id: "pin:\(p)",
                    title: (p as NSString).lastPathComponent,
                    subtitle: "\(unpinHint) ‹ \(formatHierarchicalSubtitle(p))",
                    path: p,
                    isDirectory: isDir,
                    kind: isDir ? .driveFolder(path: p) : .driveFile(path: p),
                    badge: pinnedBadge,
                    sfSymbolFallback: isDir ? "folder.fill" : "doc.fill"
                ))
            }
        }
        return out
    }

    func recentMyDriveFolders(limit: Int = 9) -> [SearchResultItem] {
        let pinnedItems = pinnedSearchResultItems()
        let pinnedPathSet = Set(pinnedItems.compactMap(\.path))

        let validMyDrivePrefixes = activeAccounts.compactMap(\.myDrivePath)
        let sorted = history.sorted {
            if $0.value.last_used != $1.value.last_used {
                return $0.value.last_used > $1.value.last_used
            }
            return $0.value.count > $1.value.count
        }

        var items: [SearchResultItem] = pinnedItems
        let targetLimit = max(limit, pinnedItems.count + 5)

        for (hPath, rec) in sorted {
            if pinnedPathSet.contains(hPath) { continue }
            if !validMyDrivePrefixes.isEmpty, !validMyDrivePrefixes.contains(where: { hPath.hasPrefix($0) }) {
                continue
            }
            if !fastFolderIndex.isEmpty && !fastFolderIndex.containsPath(hPath) {
                continue
            }
            let sub = "\(L("Mở gần đây (\(rec.count) lần)", "Recently opened (\(rec.count) times)")) ‹ \(formatHierarchicalSubtitle(hPath))"
            items.append(SearchResultItem(
                id: "recent:\(hPath)",
                title: (hPath as NSString).lastPathComponent,
                subtitle: sub,
                path: hPath,
                isDirectory: true,
                kind: .driveFolder(path: hPath),
                badge: nil,
                sfSymbolFallback: "folder.fill"
            ))
            if items.count >= targetLimit { break }
        }

        if items.count == pinnedItems.count {
            let roots = fastFolderIndex.rootFolderPaths(excluding: pinnedPathSet, limit: max(1, targetLimit - items.count))
            for rootPath in roots {
                items.append(SearchResultItem(
                    id: "root:\(rootPath)",
                    title: (rootPath as NSString).lastPathComponent,
                    subtitle: formatHierarchicalSubtitle(rootPath),
                    path: rootPath,
                    isDirectory: true,
                    kind: .driveFolder(path: rootPath),
                    badge: nil,
                    sfSymbolFallback: "folder.fill"
                ))
                if items.count >= targetLimit { break }
            }
        }
        return items
    }

    func recentSharedItems(limit: Int = 9) -> [SearchResultItem] {
        let sdPrefixes = activeAccounts.compactMap(\.sharedDrivesPath)
        let stPrefixes = activeAccounts.compactMap(\.shortcutTargetsPath)
        let sorted = history.sorted { $0.value.last_used > $1.value.last_used }
        var items: [SearchResultItem] = []

        for (hPath, rec) in sorted {
            let inSD = sdPrefixes.contains { hPath.hasPrefix($0) }
            let inST = stPrefixes.contains { hPath.hasPrefix($0) }
            guard inSD || inST else { continue }
            let isDir = fastSharedIndex.isDir(forPath: hPath) ?? true

            let sub = "\(L("Mở gần đây (\(rec.count) lần)", "Recently opened (\(rec.count) times)")) ‹ \(formatHierarchicalSubtitle(hPath))"
            items.append(SearchResultItem(
                id: "srecent:\(hPath)",
                title: (hPath as NSString).lastPathComponent,
                subtitle: sub,
                path: hPath,
                isDirectory: isDir,
                kind: isDir ? .driveFolder(path: hPath) : .driveFile(path: hPath),
                badge: "Shared",
                sfSymbolFallback: isDir ? "folder.fill.badge.person.crop" : "doc.fill"
            ))
            if items.count >= limit { break }
        }

        if items.isEmpty {
            for entry in fastSharedIndex.prefixEntries(limit: limit) {
                items.append(SearchResultItem(
                    id: "sd:\(entry.path)",
                    title: (entry.path as NSString).lastPathComponent,
                    subtitle: entry.displaySub,
                    path: entry.path,
                    isDirectory: entry.isDir,
                    kind: entry.isDir ? .driveFolder(path: entry.path) : .driveFile(path: entry.path),
                    badge: "Shared",
                    sfSymbolFallback: entry.isDir ? "externaldrive.fill.badge.person.crop" : "doc.fill"
                ))
            }
        }
        return items
    }

    // MARK: - Ultra-Fast Zero-Allocation Pointer Slice Search (< 2ms on 200k records, §4.4, §5.2)

    @inline(__always)
    private nonisolated static func firstNonDigitIndex(_ bytes: [UInt8]) -> Int {
        var idx = 0
        let count = bytes.count
        while idx < count && bytes[idx] >= 48 && bytes[idx] <= 57 {
            idx += 1
        }
        return idx
    }

    @inline(__always)
    private nonisolated static func asciiContainsSlice(
        _ base: UnsafePointer<UInt8>,
        _ offset: Int,
        _ len: Int,
        _ needle: [UInt8]
    ) -> Bool {
        let nLen = needle.count
        if nLen == 0 { return true }
        if nLen > len { return false }
        let first = needle[0]
        let maxStart = len &- nLen
        var i = 0
        while i <= maxStart {
            if base[offset &+ i] == first {
                var j = 1
                while j < nLen && base[offset &+ i &+ j] == needle[j] {
                    j &+= 1
                }
                if j == nLen { return true }
            }
            i &+= 1
        }
        return false
    }

    @inline(__always)
    private nonisolated static func asciiHasPrefixSlice(
        _ base: UnsafePointer<UInt8>,
        _ offset: Int,
        _ len: Int,
        from startIdx: Int,
        _ needle: [UInt8]
    ) -> Bool {
        let nLen = needle.count
        if startIdx &+ nLen > len { return false }
        var j = 0
        while j < nLen {
            if base[offset &+ startIdx &+ j] != needle[j] { return false }
            j &+= 1
        }
        return true
    }

    @inline(__always)
    private nonisolated static func asciiEqualsSlice(
        _ base: UnsafePointer<UInt8>,
        _ offset: Int,
        _ len: Int,
        from startIdx: Int,
        _ needle: [UInt8]
    ) -> Bool {
        let rem = len &- startIdx
        if rem != needle.count { return false }
        return asciiHasPrefixSlice(base, offset, len, from: startIdx, needle)
    }

    @inline(__always)
    private nonisolated static func firstNonDigitOffset(
        _ base: UnsafePointer<UInt8>,
        _ offset: Int,
        _ len: Int
    ) -> Int {
        var idx = 0
        while idx < len {
            let b = base[offset &+ idx]
            if b < 48 || b > 57 { break }
            idx &+= 1
        }
        return idx
    }

    /// Bounded top-K buffer helper: keeps only the highest-ranked `maxResults` hits without sorting all 90k items (§4.4).
    private nonisolated static func insertBoundedTopK<Element>(
        _ candidate: Element,
        into topK: inout [Element],
        limit: Int,
        isBetter: (Element, Element) -> Bool
    ) {
        guard limit > 0 else { return }
        if topK.count < limit {
            topK.append(candidate)
            if topK.count == limit {
                topK.sort(by: isBetter)
            }
            return
        }
        guard let worst = topK.last, isBetter(candidate, worst) else { return }
        var low = 0
        var high = topK.count - 1
        while low < high {
            let mid = (low + high) >> 1
            if isBetter(candidate, topK[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        topK.removeLast()
        topK.insert(candidate, at: low)
    }

    nonisolated static func evaluateMyDriveSearchHits(
        tokens: [String],
        fastIndex: FastFolderIndex,
        historySnapshot: [String: HistoryRecord],
        maxResults: Int
    ) -> [(path: String, historyCount: Int)] {
        let cleanTokens = tokens.map(cleanString).filter { !$0.isEmpty }
        guard !cleanTokens.isEmpty && !fastIndex.isEmpty else { return [] }
        let tokenBytes = cleanTokens.map { Array($0.utf8) }
        let queryKey = cleanTokens.joined(separator: " ")
        let totalRecs = fastIndex.count

        let numTokens = tokenBytes.count
        let lastTokIdx = numTokens - 1
        let hasHistory = !historySnapshot.isEmpty

        struct ScoredHit {
            let totalScore: Int
            let hasHistory: Bool
            let negDepth: Int
            let negLen: Int
            let recIdx: Int
            let historyCount: Int
        }

        let isBetter: (ScoredHit, ScoredHit) -> Bool = { a, b in
            if a.totalScore != b.totalScore { return a.totalScore > b.totalScore }
            if a.hasHistory != b.hasHistory { return a.hasHistory && !b.hasHistory }
            if a.negDepth != b.negDepth { return a.negDepth > b.negDepth }
            return a.negLen > b.negLen
        }

        let cachedSubIndices: [Int]? = folderRefineLock.withLock { cached in
            guard let cached,
                  cached.indexIdentityCount == totalRecs,
                  queryKey.count > cached.queryKey.count,
                  queryKey.hasPrefix(cached.queryKey),
                  cached.candidateIndices.count <= 5_000 else {
                return nil
            }
            return cached.candidateIndices
        }

        var topHits: [ScoredHit] = []
        topHits.reserveCapacity(min(maxResults, 64))
        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(512)

        fastIndex.blob.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            func evaluateRecord(at recIdx: Int) {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ recIdx &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let pStart = recOff &+ 2
                var pos = pStart &+ pLen
                let numSegs = Int(base[pos])
                pos &+= 1
                if numSegs == 0 { return }

                let leafIdx = numSegs &- 1
                var curS = 0
                var matchedAll = true
                var matchScore = 0
                var leafMatched = false

                for tokIdx in 0..<numTokens {
                    let tok = tokenBytes[tokIdx]
                    var foundS = -1
                    let isLastTok = (tokIdx == lastTokIdx)

                    for sIdx in curS..<numSegs {
                        let cLen = Int(base[pos])
                        let cOff = pos &+ 1
                        pos = cOff &+ cLen
                        let aLen = Int(base[pos])
                        let aOff = pos &+ 1
                        pos = aOff &+ aLen

                        let segMatch = asciiContainsSlice(base, cOff, cLen, tok)
                        let acrMatch = aLen > 0 && asciiHasPrefixSlice(base, aOff, aLen, from: 0, tok)

                        if segMatch || acrMatch {
                            foundS = sIdx
                            if isLastTok && sIdx == leafIdx {
                                leafMatched = true
                            }
                            let stripIdx = firstNonDigitOffset(base, cOff, cLen)
                            let sc: Int
                            if asciiEqualsSlice(base, cOff, cLen, from: stripIdx, tok)
                                || asciiEqualsSlice(base, cOff, cLen, from: 0, tok)
                                || (aLen > 0 && asciiEqualsSlice(base, aOff, aLen, from: 0, tok)) {
                                sc = 100
                            } else if asciiHasPrefixSlice(base, cOff, cLen, from: stripIdx, tok)
                                || asciiHasPrefixSlice(base, cOff, cLen, from: 0, tok)
                                || acrMatch {
                                sc = 80
                            } else {
                                sc = 50
                            }
                            matchScore &+= sc
                            break
                        }
                    }

                    if foundS != -1 {
                        // Next token can match the SAME segment (`foundS`), so rewind `pos` to the start of `foundS` if there are more tokens
                        if tokIdx < lastTokIdx {
                            pos = pStart &+ pLen &+ 1
                            for _ in 0..<foundS {
                                let cL = Int(base[pos])
                                pos &+= 1 &+ cL
                                let aL = Int(base[pos])
                                pos &+= 1 &+ aL
                            }
                        }
                        curS = foundS
                    } else {
                        matchedAll = false
                        break
                    }
                }

                if matchedAll {
                    if matchedIndices.count <= 5_000 {
                        matchedIndices.append(recIdx)
                    }
                    if leafMatched { matchScore &+= 1000 }
                    var hCount = 0
                    var histBoost = 0
                    if hasHistory {
                        let pStr = BinaryIndexCodec.decodeUTF8(base, pStart, pLen)
                        if let hRec = historySnapshot[pStr] {
                            hCount = hRec.count
                            histBoost = min(150 + hCount * 15, 300)
                        }
                    }
                    let hit = ScoredHit(
                        totalScore: matchScore &+ histBoost,
                        hasHistory: histBoost > 0,
                        negDepth: -numSegs,
                        negLen: -pLen,
                        recIdx: recIdx,
                        historyCount: hCount
                    )
                    insertBoundedTopK(hit, into: &topHits, limit: maxResults, isBetter: isBetter)
                }
            }

            if let sub = cachedSubIndices {
                for idx in sub where idx < totalRecs {
                    evaluateRecord(at: idx)
                }
            } else {
                for idx in 0..<totalRecs {
                    evaluateRecord(at: idx)
                }
            }
        }

        if matchedIndices.count <= 5_000 {
            let captured = matchedIndices
            folderRefineLock.withLock { state in
                state = FolderPrefixRefineCache(
                    queryKey: queryKey,
                    indexIdentityCount: totalRecs,
                    candidateIndices: captured
                )
            }
        }

        if topHits.count < maxResults {
            topHits.sort(by: isBetter)
        }
        return topHits.map { (fastIndex.path(at: $0.recIdx), $0.historyCount) }
    }

    nonisolated static func evaluateSharedSearchHits(
        tokens: [String],
        fastIndex: FastSharedIndex,
        historySnapshot: [String: HistoryRecord],
        maxResults: Int
    ) -> [(entry: SharedDriveEntry, historyCount: Int)] {
        let cleanTokens = tokens.map(cleanString).filter { !$0.isEmpty }
        guard !cleanTokens.isEmpty && !fastIndex.isEmpty else { return [] }
        let tokenBytes = cleanTokens.map { Array($0.utf8) }
        let queryKey = cleanTokens.joined(separator: " ")
        let totalRecs = fastIndex.count

        let numTokens = tokenBytes.count
        let lastTokIdx = numTokens - 1
        let hasHistory = !historySnapshot.isEmpty

        struct ScoredShared {
            let totalScore: Int
            let hasHistory: Bool
            let negDepth: Int
            let negLen: Int
            let recIdx: Int
            let historyCount: Int
        }

        let isBetter: (ScoredShared, ScoredShared) -> Bool = { a, b in
            if a.totalScore != b.totalScore { return a.totalScore > b.totalScore }
            if a.hasHistory != b.hasHistory { return a.hasHistory && !b.hasHistory }
            if a.negDepth != b.negDepth { return a.negDepth > b.negDepth }
            return a.negLen > b.negLen
        }

        let cachedSubIndices: [Int]? = sharedRefineLock.withLock { cached in
            guard let cached,
                  cached.indexIdentityCount == totalRecs,
                  queryKey.count > cached.queryKey.count,
                  queryKey.hasPrefix(cached.queryKey),
                  cached.candidateIndices.count <= 5_000 else {
                return nil
            }
            return cached.candidateIndices
        }

        var topHits: [ScoredShared] = []
        topHits.reserveCapacity(min(maxResults, 64))
        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(512)

        fastIndex.blob.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            func evaluateRecord(at recIdx: Int) {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ recIdx &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let pStart = recOff &+ 2
                var pos = pStart &+ pLen &+ 1 // skip isDir
                let dLen = BinaryIndexCodec.readU16LE(base, pos)
                pos &+= 2 &+ dLen
                let segTablePos = pos
                let numSegs = Int(base[pos])
                pos &+= 1
                if numSegs == 0 { return }

                let leafIdx = numSegs &- 1
                var curS = 0
                var matchedAll = true
                var matchScore = 0
                var leafMatched = false

                for tokIdx in 0..<numTokens {
                    let tok = tokenBytes[tokIdx]
                    var foundS = -1
                    let isLastTok = (tokIdx == lastTokIdx)

                    for sIdx in curS..<numSegs {
                        let cLen = Int(base[pos])
                        let cOff = pos &+ 1
                        pos = cOff &+ cLen
                        let aLen = Int(base[pos])
                        let aOff = pos &+ 1
                        pos = aOff &+ aLen

                        let segMatch = asciiContainsSlice(base, cOff, cLen, tok)
                        let acrMatch = aLen > 0 && asciiHasPrefixSlice(base, aOff, aLen, from: 0, tok)

                        if segMatch || acrMatch {
                            foundS = sIdx
                            if isLastTok && sIdx == leafIdx { leafMatched = true }
                            let stripIdx = firstNonDigitOffset(base, cOff, cLen)
                            if asciiEqualsSlice(base, cOff, cLen, from: stripIdx, tok)
                                || asciiEqualsSlice(base, cOff, cLen, from: 0, tok)
                                || (aLen > 0 && asciiEqualsSlice(base, aOff, aLen, from: 0, tok)) {
                                matchScore &+= 100
                            } else if asciiHasPrefixSlice(base, cOff, cLen, from: stripIdx, tok)
                                || asciiHasPrefixSlice(base, cOff, cLen, from: 0, tok)
                                || acrMatch {
                                matchScore &+= 80
                            } else {
                                matchScore &+= 50
                            }
                            break
                        }
                    }
                    if foundS != -1 {
                        if tokIdx < lastTokIdx {
                            pos = segTablePos &+ 1
                            for _ in 0..<foundS {
                                let cL = Int(base[pos])
                                pos &+= 1 &+ cL
                                let aL = Int(base[pos])
                                pos &+= 1 &+ aL
                            }
                        }
                        curS = foundS
                    } else {
                        matchedAll = false
                        break
                    }
                }

                if matchedAll {
                    if matchedIndices.count <= 5_000 {
                        matchedIndices.append(recIdx)
                    }
                    if leafMatched { matchScore &+= 1000 }
                    var hCount = 0
                    var histBoost = 0
                    if hasHistory {
                        let pStr = BinaryIndexCodec.decodeUTF8(base, pStart, pLen)
                        if let hRec = historySnapshot[pStr] {
                            hCount = hRec.count
                            histBoost = min(150 + hCount * 15, 300)
                        }
                    }
                    let hit = ScoredShared(
                        totalScore: matchScore &+ histBoost,
                        hasHistory: histBoost > 0,
                        negDepth: -numSegs,
                        negLen: -pLen,
                        recIdx: recIdx,
                        historyCount: hCount
                    )
                    insertBoundedTopK(hit, into: &topHits, limit: maxResults, isBetter: isBetter)
                }
            }

            if let sub = cachedSubIndices {
                for idx in sub where idx < totalRecs {
                    evaluateRecord(at: idx)
                }
            } else {
                for idx in 0..<totalRecs {
                    evaluateRecord(at: idx)
                }
            }
        }

        if matchedIndices.count <= 5_000 {
            let captured = matchedIndices
            sharedRefineLock.withLock { state in
                state = FolderPrefixRefineCache(
                    queryKey: queryKey,
                    indexIdentityCount: totalRecs,
                    candidateIndices: captured
                )
            }
        }

        if topHits.count < maxResults {
            topHits.sort(by: isBetter)
        }
        return topHits.map { (fastIndex.entry(at: $0.recIdx), $0.historyCount) }
    }

    func defaultInstalledAppResultItems(limit: Int = 80) -> [SearchResultItem] {
        let runningPaths = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleURL?.resolvingSymlinksInPath().path.lowercased() }
        )
        let sorted = installedApps.sorted { a, b in
            let hA = history[a.path]?.count ?? 0
            let hB = history[b.path]?.count ?? 0
            if hA != hB { return hA > hB }

            let runA = runningPaths.contains(URL(fileURLWithPath: a.path).resolvingSymlinksInPath().path.lowercased())
            let runB = runningPaths.contains(URL(fileURLWithPath: b.path).resolvingSymlinksInPath().path.lowercased())
            if runA != runB { return runA && !runB }

            if a.isNestedHelper != b.isNestedHelper { return !a.isNestedHelper && b.isNestedHelper }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return sorted.prefix(limit).map { app in
            Self.makeAppSearchResultItem(
                app: app,
                historyCount: history[app.path]?.count ?? 0,
                isRunning: runningPaths.contains(URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path.lowercased())
            )
        }
    }

    nonisolated static func searchInstalledApps(
        queryTokens: [String],
        apps: [InstalledAppEntry],
        historySnapshot: [String: HistoryRecord],
        isAppOnlyMode: Bool,
        maxResults: Int
    ) -> [SearchResultItem] {
        let cleanTokens = queryTokens.map(cleanString).filter { !$0.isEmpty }
        guard !cleanTokens.isEmpty else { return [] }
        let joinedQ = cleanTokens.joined()

        var hits: [(score: Int, app: InstalledAppEntry, historyCount: Int)] = []
        hits.reserveCapacity(16)

        for app in apps {
            let hCount = historySnapshot[app.path]?.count ?? 0
            guard let rawScore = scoreInstalledApp(
                app: app,
                cleanTokens: cleanTokens,
                joinedQuery: joinedQ,
                isAppOnlyMode: isAppOnlyMode,
                historyCount: hCount
            ) else {
                continue
            }
            let historyBoost = hCount > 0 ? (450 + min(400, hCount * 45)) : 0
            let helperPenalty = app.isNestedHelper ? 220 : 0
            let lengthPenalty = min(60, app.name.count)
            let total = rawScore + historyBoost - helperPenalty - lengthPenalty
            hits.append((total, app, hCount))
        }

        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.historyCount != b.historyCount { return a.historyCount > b.historyCount }
            return a.app.name.localizedCaseInsensitiveCompare(b.app.name) == .orderedAscending
        }

        return hits.prefix(maxResults).map { hit in
            makeAppSearchResultItem(app: hit.app, historyCount: hit.historyCount, isRunning: false)
        }
    }

    private nonisolated static func makeAppSearchResultItem(
        app: InstalledAppEntry,
        historyCount: Int,
        isRunning: Bool
    ) -> SearchResultItem {
        var subParts: [String] = []
        if historyCount > 0 {
            subParts.append("\(L("Mở gần đây (\(historyCount) lần)", "Recently opened (\(historyCount) times)"))")
        } else if isRunning {
            subParts.append(L("Đang chạy", "Running"))
        } else {
            subParts.append(L("Ứng dụng macOS", "macOS Application"))
        }
        subParts.append(app.path)
        return SearchResultItem(
            id: "app:\(app.path)",
            title: app.name,
            subtitle: subParts.joined(separator: " • "),
            path: app.path,
            isDirectory: false,
            kind: .localApp(path: app.path),
            badge: isRunning ? L("Đang chạy", "Running") : "App",
            sfSymbolFallback: "app.fill"
        )
    }

    private nonisolated static func scoreInstalledApp(
        app: InstalledAppEntry,
        cleanTokens: [String],
        joinedQuery: String,
        isAppOnlyMode: Bool,
        historyCount: Int = 0
    ) -> Int? {
        if !isAppOnlyMode && historyCount == 0 && joinedQuery.count <= 2 && app.path.hasPrefix("/System/Library/CoreServices/Applications/") {
            let firstWordMatches = app.words.first?.hasPrefix(joinedQuery) == true
            if !firstWordMatches && !app.cleanFull.hasPrefix(joinedQuery) && !app.cleanFullVI.hasPrefix(joinedQuery) {
                return nil
            }
        }

        // 1. Direct joined query match against full clean name or acronym in EN or VI (e.g. "lich", "calendar", "microsoftedge", "am", "me", "spss")
        if app.cleanFull == joinedQuery || app.cleanFullVI == joinedQuery {
            return 2_600
        }
        if (!app.acronym.isEmpty && app.acronym == joinedQuery) || (!app.acronymVI.isEmpty && app.acronymVI == joinedQuery) {
            return 2_450
        }
        if app.cleanFull.hasPrefix(joinedQuery) || app.cleanFullVI.hasPrefix(joinedQuery) {
            return 2_250
        }
        if ((!app.acronym.isEmpty && app.acronym.hasPrefix(joinedQuery)) || (!app.acronymVI.isEmpty && app.acronymVI.hasPrefix(joinedQuery))) && joinedQuery.count >= 2 {
            return 2_050
        }

        // 2. Per-token evaluation across words, aliases, substrings & near-prefixes
        // Handles "moni" -> Activity Monitor, "active monitor" -> Activity Monitor, "edg" -> Microsoft Edge!
        var totalTokenScore = 0
        var matchedWordIndices = Set<Int>()

        for token in cleanTokens {
            var bestForToken: Int?

            // Check primary & bundle words first
            for (wIdx, word) in app.words.enumerated() {
                let firstWordBonus = (wIdx == 0) ? 70 : 0
                if word == token {
                    let candidate = 2_200 + firstWordBonus - (matchedWordIndices.contains(wIdx) ? 60 : 0)
                    if candidate > (bestForToken ?? 0) {
                        bestForToken = candidate
                        matchedWordIndices.insert(wIdx)
                    }
                } else if word.hasPrefix(token) {
                    let candidate = 1_980 + firstWordBonus - (matchedWordIndices.contains(wIdx) ? 60 : 0)
                    if candidate > (bestForToken ?? 0) {
                        bestForToken = candidate
                        matchedWordIndices.insert(wIdx)
                    }
                } else if token.count >= 4 && sharesNearPrefix(queryToken: token, targetWord: word) {
                    // e.g. "active" vs "activity" shares 5-char prefix "activ"!
                    let candidate = 1_680 + firstWordBonus
                    if candidate > (bestForToken ?? 0) {
                        bestForToken = candidate
                    }
                } else if (token.count >= 3 || (isAppOnlyMode && token.count >= 2)) && word.contains(token) {
                    let candidate = 1_520
                    if candidate > (bestForToken ?? 0) {
                        bestForToken = candidate
                    }
                }
            }

            // Check built-in synonyms / Vietnamese & English aliases (e.g. "active" -> Activity Monitor, "ppt" -> PowerPoint)
            if bestForToken == nil {
                for alias in app.aliasWords {
                    if alias == token {
                        bestForToken = max(bestForToken ?? 0, 1_780)
                    } else if alias.hasPrefix(token) && (token.count >= 3 || isAppOnlyMode || historyCount > 0) {
                        bestForToken = max(bestForToken ?? 0, 1_660)
                    }
                }
            }

            // Check cross-word substring inside cleanFull or cleanFullVI (e.g. "note" inside "endnote", "studio" inside "rstudio")
            if bestForToken == nil && (token.count >= 3 || (isAppOnlyMode && token.count >= 2)) && (app.cleanFull.contains(token) || app.cleanFullVI.contains(token)) {
                bestForToken = 1_480
            }

            // In `a <keyword>` App-Only Mode, also allow ordered subsequence matching (e.g. "actmon", "msedg", "stse")
            if bestForToken == nil && isAppOnlyMode && token.count >= 2 && (isOrderedSubsequence(token, in: app.cleanFull) || isOrderedSubsequence(token, in: app.cleanFullVI)) {
                bestForToken = 1_220
            }

            guard let matchedScore = bestForToken else {
                return nil
            }
            totalTokenScore += matchedScore
        }

        return totalTokenScore / cleanTokens.count + (cleanTokens.count > 1 ? 120 : 0)
    }

    private nonisolated static func sharesNearPrefix(queryToken: String, targetWord: String) -> Bool {
        let qBytes = Array(queryToken.utf8)
        let tBytes = Array(targetWord.utf8)
        let minRequired = max(3, qBytes.count - 1)
        guard tBytes.count >= minRequired else { return false }
        var shared = 0
        let limit = min(qBytes.count, tBytes.count)
        while shared < limit && qBytes[shared] == tBytes[shared] {
            shared += 1
        }
        return shared >= minRequired
    }

    private nonisolated static func isOrderedSubsequence(_ needle: String, in haystack: String) -> Bool {
        var hIter = haystack.utf8.makeIterator()
        for b in needle.utf8 {
            var found = false
            while let hb = hIter.next() {
                if hb == b {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    func searchMyDriveFolders(tokens: [String], includeApps: Bool, maxResults: Int = 45) -> [SearchResultItem] {
        let cleanTokens = tokens.map(Self.cleanString).filter { !$0.isEmpty }
        guard !cleanTokens.isEmpty else { return recentMyDriveFolders() }

        let topHits = Self.evaluateMyDriveSearchHits(
            tokens: tokens,
            fastIndex: fastFolderIndex,
            historySnapshot: history,
            maxResults: maxResults
        )
        return buildMyDriveSearchResultItems(from: topHits, cleanTokens: cleanTokens, includeApps: includeApps, maxResults: maxResults)
    }

    func buildMyDriveSearchResultItems(
        from topHits: [(path: String, historyCount: Int)],
        cleanTokens: [String],
        includeApps: Bool,
        maxResults: Int = 45
    ) -> [SearchResultItem] {
        var results: [SearchResultItem] = []
        results.reserveCapacity(min(topHits.count + 6, maxResults))

        if includeApps && !cleanTokens.isEmpty {
            let appItems = Self.searchInstalledApps(
                queryTokens: cleanTokens,
                apps: installedApps,
                historySnapshot: history,
                isAppOnlyMode: false,
                maxResults: 5
            )
            results.append(contentsOf: appItems)
        }

        for hit in topHits {
            if results.count >= maxResults { break }
            let sub: String
            if hit.historyCount > 0 {
                sub = "\(L("Mở gần đây (\(hit.historyCount) lần)", "Recently opened (\(hit.historyCount) times)")) ‹ \(formatHierarchicalSubtitle(hit.path))"
            } else {
                sub = formatHierarchicalSubtitle(hit.path)
            }
            results.append(SearchResultItem(
                id: "gd:\(hit.path)",
                title: (hit.path as NSString).lastPathComponent,
                subtitle: sub,
                path: hit.path,
                isDirectory: true,
                kind: .driveFolder(path: hit.path),
                badge: nil,
                sfSymbolFallback: "folder.fill"
            ))
        }
        return results
    }

    func buildSharedSearchResultItems(
        from topHits: [(entry: SharedDriveEntry, historyCount: Int)],
        maxResults: Int = 45
    ) -> [SearchResultItem] {
        var results: [SearchResultItem] = []
        results.reserveCapacity(min(topHits.count, maxResults))
        for hit in topHits.prefix(maxResults) {
            let sub = hit.historyCount > 0
                ? "\(L("Mở gần đây (\(hit.historyCount) lần)", "Recently opened (\(hit.historyCount) times)")) ‹ \(formatHierarchicalSubtitle(hit.entry.path))"
                : formatHierarchicalSubtitle(hit.entry.path)
            results.append(SearchResultItem(
                id: "sh:\(hit.entry.path)",
                title: (hit.entry.path as NSString).lastPathComponent,
                subtitle: sub,
                path: hit.entry.path,
                isDirectory: hit.entry.isDir,
                kind: hit.entry.isDir ? .driveFolder(path: hit.entry.path) : .driveFile(path: hit.entry.path),
                badge: "Shared",
                sfSymbolFallback: hit.entry.isDir ? "folder.fill.badge.person.crop" : "doc.fill"
            ))
        }
        return results
    }

    // MARK: - Zero-Hang Browse Mode (0ms RAM Folders + Background POSIX readdir)

    /// Returns cached child folders/items from RAM in < 0.05ms with ZERO disk/cloud syscalls.
    func cachedChildrenInMemory(parentPath: String, queryWords: [String]) -> [(path: String, isDir: Bool)] {
        let cleanParent = parentPath.hasSuffix("/") && parentPath.count > 1 ? String(parentPath.dropLast()) : parentPath
        let tokens = queryWords.map(Self.cleanString).filter { !$0.isEmpty }

        var combined: [(path: String, isDir: Bool)] = []
        var seen = Set<String>()

        for p in fastFolderIndex.children(ofParent: cleanParent) where seen.insert(p).inserted {
            combined.append((p, true))
        }
        for item in fastSharedIndex.children(ofParent: cleanParent) where seen.insert(item.path).inserted {
            combined.append(item)
        }
        for item in fastMacFolderIndex.children(ofParent: cleanParent) where seen.insert(item.path).inserted {
            combined.append(item)
        }

        if !tokens.isEmpty {
            combined = combined.filter { item in
                let name = (item.path as NSString).lastPathComponent
                let nameClean = Self.cleanString(name)
                let nameNorm = Self.removeAccents(name.lowercased())
                return tokens.allSatisfy { nameClean.contains($0) || nameNorm.contains($0) }
            }
        }

        combined.sort { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            return (a.path as NSString).lastPathComponent.localizedStandardCompare((b.path as NSString).lastPathComponent) == .orderedAscending
        }
        return combined
    }

    /// Reads directory entries on a background thread using POSIX `opendir`/`readdir` (`d_type`),
    /// avoiding `FileManager.fileExists` RPC storms on CloudStorage mounts.
    nonisolated static func listDirectoryFastPOSIX(parentPath: String, queryWords: [String]) -> [(path: String, isDir: Bool)] {
        let cleanParent = parentPath.hasSuffix("/") && parentPath.count > 1 ? String(parentPath.dropLast()) : parentPath
        guard let dirPtr = Darwin.opendir(cleanParent) else { return [] }
        defer { Darwin.closedir(dirPtr) }

        let tokens = queryWords.map(cleanString).filter { !$0.isEmpty }
        var results: [(path: String, isDir: Bool)] = []

        while let entryPtr = Darwin.readdir(dirPtr) {
            let dType = entryPtr.pointee.d_type
            let nameLen = Int(entryPtr.pointee.d_namlen)
            guard nameLen > 0 else { continue }

            let name: String = withUnsafePointer(to: entryPtr.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { utf8Ptr in
                    String(decoding: UnsafeBufferPointer(start: utf8Ptr, count: nameLen), as: UTF8.self)
                }
            }
            if name.isEmpty || name.hasPrefix(".") { continue }

            let full = cleanParent == "/" ? "/\(name)" : "\(cleanParent)/\(name)"
            let isDir: Bool
            if dType == DT_DIR {
                isDir = true
            } else if dType == DT_UNKNOWN {
                var st = Darwin.stat()
                isDir = (Darwin.lstat(full, &st) == 0) && ((st.st_mode & S_IFMT) == S_IFDIR)
            } else {
                isDir = false
            }

            if !tokens.isEmpty {
                let nameClean = cleanString(name)
                let nameNorm = removeAccents(name.lowercased())
                let matches = tokens.allSatisfy { nameClean.contains($0) || nameNorm.contains($0) }
                if !matches { continue }
            }
            results.append((full, isDir))
        }

        results.sort { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            return (a.path as NSString).lastPathComponent.localizedStandardCompare((b.path as NSString).lastPathComponent) == .orderedAscending
        }
        return results
    }

    // MARK: - Native Google Drive Item ID & Web URLs (Zero-subprocess getxattr!)

    nonisolated static func extractGoogleDriveItemID(at path: String) -> String? {
        let attrName = "com.google.drivefs.item-id#S"
        let size = getxattr(path, attrName, nil, 0, 0, 0)
        if size > 0 {
            var buffer = [UInt8](repeating: 0, count: size)
            let readSize = getxattr(path, attrName, &buffer, size, 0, 0)
            if readSize > 0, let str = String(bytes: buffer.prefix(readSize), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                return str
            }
        }

        let ext = (path as NSString).pathExtension.lowercased()
        if ["gdoc", "gsheet", "gslides", "gdraw", "gform", "gtable"].contains(ext),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let docID = json["doc_id"] as? String, !docID.isEmpty {
                return docID
            }
            if let urlStr = json["url"] as? String {
                if let range = urlStr.range(of: "/d/") {
                    let after = urlStr[range.upperBound...]
                    let idPart = after.split(separator: "/").first.map(String.init)
                    if let idPart, !idPart.isEmpty { return idPart }
                }
                let trimmed = urlStr.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return trimmed.components(separatedBy: "/").last
            }
        }
        return nil
    }

    nonisolated static func googleDriveURLs(for path: String, isDirectoryHint: Bool? = nil) -> (webURL: URL, shareURL: URL)? {
        let effectivePath = LocalFolderDriveSyncService.mappedDrivePath(forLocalPath: path) ?? path
        guard let itemID = extractGoogleDriveItemID(at: effectivePath) else { return nil }
        let isDir: Bool
        if let isDirectoryHint {
            isDir = isDirectoryHint
        } else {
            var st = Darwin.stat()
            isDir = (Darwin.lstat(effectivePath, &st) == 0) && ((st.st_mode & S_IFMT) == S_IFDIR)
        }

        let ext = (path as NSString).pathExtension.lowercased()
        let webStr: String
        let shareStr: String

        if isDir {
            webStr = "https://drive.google.com/drive/folders/\(itemID)"
            shareStr = "https://drive.google.com/drive/folders/\(itemID)?usp=sharing"
        } else if ext == "gdoc" {
            webStr = "https://docs.google.com/document/d/\(itemID)/edit"
            shareStr = "https://docs.google.com/document/d/\(itemID)/edit?usp=sharing"
        } else if ext == "gsheet" {
            webStr = "https://docs.google.com/spreadsheets/d/\(itemID)/edit"
            shareStr = "https://docs.google.com/spreadsheets/d/\(itemID)/edit?usp=sharing"
        } else if ext == "gslides" {
            webStr = "https://docs.google.com/presentation/d/\(itemID)/edit"
            shareStr = "https://docs.google.com/presentation/d/\(itemID)/edit?usp=sharing"
        } else {
            webStr = "https://drive.google.com/file/d/\(itemID)/view"
            shareStr = "https://drive.google.com/file/d/\(itemID)/view?usp=sharing"
        }

        guard let w = URL(string: webStr), let s = URL(string: shareStr) else { return nil }
        return (w, s)
    }

    nonisolated static func triggerOfflineDownload(for urls: [URL]) -> Int {
        let fm = FileManager.default
        var count = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if let fh = try? FileHandle(forReadingFrom: url) {
                    _ = try? fh.read(upToCount: 1)
                    try? fh.close()
                    count += 1
                }
            } else if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    if let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), vals.isRegularFile == true {
                        if let fh = try? FileHandle(forReadingFrom: fileURL) {
                            _ = try? fh.read(upToCount: 1)
                            try? fh.close()
                            count += 1
                        }
                    }
                }
            }
        }
        return count
    }

    // MARK: - Direct Fast File Search (`ff` / `ff + từ khóa` & Extension-Aware Search)

    nonisolated static let knownSearchableExtensions: Set<String> = [
        "pdf", "docx", "doc", "xlsx", "xls", "csv", "tsv", "pptx", "ppt",
        "md", "markdown", "txt", "rtf", "gdoc", "gsheet", "gslides",
        "sav", "zsav", "spv", "sps", "dta", "do", "r", "rmd", "qmd", "ipynb", "py",
        "json", "yaml", "yml", "xml", "html", "tex", "bib", "ris", "enl",
        "zip", "rar", "7z", "tar", "gz", "dmg",
        "png", "jpg", "jpeg", "heic", "webp", "svg", "mp4", "mp3", "m4a", "wav"
    ]

    nonisolated static func hasExplicitFileExtensionToken(_ rawTokens: [String]) -> Bool {
        for raw in rawTokens {
            let trimmed = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if knownSearchableExtensions.contains(trimmed) {
                return true
            }
            let pathExt = (raw as NSString).pathExtension.lowercased()
            if !pathExt.isEmpty && knownSearchableExtensions.contains(pathExt) {
                return true
            }
        }
        return false
    }

    func defaultFileModeResultItems(limit: Int = 35) -> [SearchResultItem] {
        var results: [SearchResultItem] = []
        var seen = Set<String>()

        // 1. Pinned files first
        for p in AppSettings.shared.pinnedPaths where !p.lowercased().hasSuffix(".app") && !isKnownDirectory(p) {
            guard seen.insert(p).inserted else { continue }
            let ext = (p as NSString).pathExtension.uppercased()
            let pinnedText = L("Đã ghim", "Pinned")
            results.append(SearchResultItem(
                id: "ffile:pin:\(p)",
                title: (p as NSString).lastPathComponent,
                subtitle: "\(pinnedText) ‹ \(formatHierarchicalSubtitle(p))",
                path: p,
                isDirectory: false,
                kind: .driveFile(path: p),
                badge: ext.isEmpty ? pinnedText : "\(pinnedText) • \(ext)",
                sfSymbolFallback: "doc.fill"
            ))
        }

        // 2. Recently opened files from history
        let sortedHist = history.sorted { $0.value.last_used > $1.value.last_used }
        for (hPath, rec) in sortedHist {
            let ext = (hPath as NSString).pathExtension
            guard !ext.isEmpty, !hPath.lowercased().hasSuffix(".app"), !isKnownDirectory(hPath) else { continue }
            guard seen.insert(hPath).inserted else { continue }
            results.append(SearchResultItem(
                id: "ffile:hist:\(hPath)",
                title: (hPath as NSString).lastPathComponent,
                subtitle: "\(L("Mở gần đây (\(rec.count) lần)", "Recently opened (\(rec.count) times)")) ‹ \(formatHierarchicalSubtitle(hPath))",
                path: hPath,
                isDirectory: false,
                kind: .driveFile(path: hPath),
                badge: ext.uppercased(),
                sfSymbolFallback: "doc.fill"
            ))
            if results.count >= limit { return results }
        }

        // 3. Fill with indexed files
        for f in fastFileIndex.prefixEntries(limit: limit) where seen.insert(f.path).inserted {
            results.append(SearchResultItem(
                id: "ffile:idx:\(f.path)",
                title: (f.path as NSString).lastPathComponent,
                subtitle: formatHierarchicalSubtitle(f.path),
                path: f.path,
                isDirectory: false,
                kind: .driveFile(path: f.path),
                badge: f.ext.isEmpty ? L("Tệp", "File") : f.ext.uppercased(),
                sfSymbolFallback: "doc.fill"
            ))
            if results.count >= limit { break }
        }

        if results.isEmpty {
            results.append(SearchResultItem(
                id: "ffile:empty",
                title: isRebuildingFiles
                    ? L("Đang lập chỉ mục tệp tin Google Drive & máy cục bộ ở nền...", "Indexing Google Drive & local files in background...")
                    : L("Gõ từ khóa sau 'ff ' để tìm trực tiếp tệp tin (.docx, .pdf, .xlsx, .sav...)", "Type keywords after 'ff ' to directly search files (.docx, .pdf, .xlsx, .sav...)"),
                subtitle: L("Hỗ trợ Google Drive, ~/Desktop, ~/Downloads, ~/Documents • Nhấn ⇧ xem Quick Look, ⇥ Convert .MD", "Supports Google Drive, ~/Desktop, ~/Downloads, ~/Documents • ⇧ Quick Look, ⇥ Convert .MD"),
                path: nil,
                isDirectory: false,
                kind: .infoBanner,
                badge: L("Tệp tin", "Files"),
                sfSymbolFallback: "doc.text.magnifyingglass"
            ))
        }
        return results
    }

    nonisolated static func evaluateFileSearchHits(
        tokens: [String],
        fastIndex: FastFileIndex,
        historySnapshot: [String: HistoryRecord],
        pinnedSet: Set<String>,
        maxResults: Int
    ) -> [(entry: DriveFileEntry, historyCount: Int, isPinned: Bool)] {
        let cleanedTokens = tokens.map { raw -> String in
            let strippedDot = raw.hasPrefix(".") ? String(raw.dropFirst()) : raw
            return cleanString(strippedDot)
        }.filter { !$0.isEmpty }
        guard !cleanedTokens.isEmpty && !fastIndex.isEmpty else { return [] }

        let tokenBytes = cleanedTokens.map { Array($0.utf8) }
        let queryKey = cleanedTokens.joined(separator: " ")
        let totalRecs = fastIndex.count
        let hasPinnedOrHistory = !pinnedSet.isEmpty || !historySnapshot.isEmpty

        struct ScoredFileHit {
            let score: Int
            let negLen: Int
            let recIdx: Int
            let historyCount: Int
            let isPinned: Bool
        }

        let isBetter: (ScoredFileHit, ScoredFileHit) -> Bool = { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.negLen > b.negLen
        }

        let cachedSubIndices: [Int]? = fileRefineLock.withLock { cached in
            guard let cached,
                  cached.indexIdentityCount == totalRecs,
                  queryKey.count > cached.queryKey.count,
                  queryKey.hasPrefix(cached.queryKey),
                  cached.candidateIndices.count <= 5_000 else {
                return nil
            }
            return cached.candidateIndices
        }

        var topHits: [ScoredFileHit] = []
        topHits.reserveCapacity(min(maxResults, 64))
        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(512)

        fastIndex.blob.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            func evaluateRecord(at recIdx: Int) {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ recIdx &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let pStart = recOff &+ 2
                var pos = pStart &+ pLen

                let extLen = Int(base[pos])
                let extOff = pos &+ 1
                pos = extOff &+ extLen

                let cLen = Int(base[pos])
                let cOff = pos &+ 1
                pos = cOff &+ cLen

                let aLen = Int(base[pos])
                let aOff = pos &+ 1
                pos = aOff &+ aLen

                let parLen = Int(base[pos])
                let parOff = pos &+ 1

                var totalScore = 0
                var nameMatchCount = 0
                var allMatched = true

                for tok in tokenBytes {
                    if extLen > 0 && asciiEqualsSlice(base, extOff, extLen, from: 0, tok) {
                        totalScore &+= 950
                        nameMatchCount &+= 1
                    } else if asciiEqualsSlice(base, cOff, cLen, from: 0, tok)
                        || (aLen > 0 && asciiEqualsSlice(base, aOff, aLen, from: 0, tok)) {
                        totalScore &+= 1_300
                        nameMatchCount &+= 1
                    } else if asciiHasPrefixSlice(base, cOff, cLen, from: 0, tok)
                        || (aLen > 0 && asciiHasPrefixSlice(base, aOff, aLen, from: 0, tok)) {
                        totalScore &+= 1_050
                        nameMatchCount &+= 1
                    } else if asciiContainsSlice(base, cOff, cLen, tok) {
                        totalScore &+= 820
                        nameMatchCount &+= 1
                    } else if parLen > 0 && asciiContainsSlice(base, parOff, parLen, tok) {
                        totalScore &+= 320
                    } else {
                        allMatched = false
                        break
                    }
                }

                guard allMatched && nameMatchCount > 0 else { return }

                if matchedIndices.count <= 5_000 {
                    matchedIndices.append(recIdx)
                }
                var isPin = false
                var hCount = 0
                var boost = 0
                if hasPinnedOrHistory {
                    let pStr = BinaryIndexCodec.decodeUTF8(base, pStart, pLen)
                    isPin = pinnedSet.contains(pStr)
                    hCount = historySnapshot[pStr]?.count ?? 0
                    boost = (isPin ? 900 : 0) + min(320, hCount * 40)
                }
                let hit = ScoredFileHit(
                    score: totalScore &+ boost,
                    negLen: -cLen,
                    recIdx: recIdx,
                    historyCount: hCount,
                    isPinned: isPin
                )
                insertBoundedTopK(hit, into: &topHits, limit: maxResults, isBetter: isBetter)
            }

            if let sub = cachedSubIndices {
                for idx in sub where idx < totalRecs {
                    evaluateRecord(at: idx)
                }
            } else {
                for idx in 0..<totalRecs {
                    evaluateRecord(at: idx)
                }
            }
        }

        if matchedIndices.count <= 5_000 {
            let captured = matchedIndices
            fileRefineLock.withLock { state in
                state = FilePrefixRefineCache(
                    queryKey: queryKey,
                    indexIdentityCount: totalRecs,
                    candidateIndices: captured
                )
            }
        }

        if topHits.count < maxResults {
            topHits.sort(by: isBetter)
        }
        return topHits.map { (fastIndex.entry(at: $0.recIdx), $0.historyCount, $0.isPinned) }
    }

    func buildFileSearchResultItems(
        from hits: [(entry: DriveFileEntry, historyCount: Int, isPinned: Bool)],
        maxResults: Int = 45
    ) -> [SearchResultItem] {
        hits.prefix(maxResults).map { hit in
            let extUpper = hit.entry.ext.uppercased()
            let pinnedText = L("Đã ghim", "Pinned")
            let badge: String? = hit.isPinned
                ? (extUpper.isEmpty ? pinnedText : "\(pinnedText) • \(extUpper)")
                : (extUpper.isEmpty ? L("Tệp", "File") : extUpper)
            let subPrefix: String
            if hit.isPinned {
                subPrefix = "\(pinnedText) ‹ "
            } else if hit.historyCount > 0 {
                subPrefix = "\(L("Mở gần đây (\(hit.historyCount) lần)", "Recently opened (\(hit.historyCount) times)")) ‹ "
            } else {
                subPrefix = ""
            }
            return SearchResultItem(
                id: "ffile:\(hit.entry.path)",
                title: (hit.entry.path as NSString).lastPathComponent,
                subtitle: subPrefix + formatHierarchicalSubtitle(hit.entry.path, maxLevels: 3),
                path: hit.entry.path,
                isDirectory: false,
                kind: .driveFile(path: hit.entry.path),
                badge: badge,
                sfSymbolFallback: "doc.fill"
            )
        }
    }

    /// Spotlight (`mdfind -name`) fallback when searching in `ff <từ khóa>` mode for uncached local files.
    nonisolated static func spotlightFallbackFilePaths(query: String, scopeDirs: [String], limit: Int = 25) -> [String] {
        let tokens = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard let primary = tokens.first else { return [] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        var args: [String] = []
        for dir in scopeDirs {
            args.append(contentsOf: ["-onlyin", dir])
        }
        args.append(contentsOf: ["-name", primary])
        proc.arguments = args

        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let str = String(data: data, encoding: .utf8) else { return [] }

        let cleanTokens = tokens.map { cleanString($0.hasPrefix(".") ? String($0.dropFirst()) : $0) }.filter { !$0.isEmpty }
        var matched: [String] = []
        for line in str.components(separatedBy: .newlines) {
            let p = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            let ext = (p as NSString).pathExtension.lowercased()
            guard !ext.isEmpty && !skipExtensions.contains(ext) else { continue }
            let cleanName = cleanString((p as NSString).lastPathComponent)
            if cleanTokens.allSatisfy({ cleanName.contains($0) }) {
                matched.append(p)
                if matched.count >= limit { break }
            }
        }
        return matched
    }

    // MARK: - Ultra-Fast Custom Mac Folders Search (`m` / `m <từ khóa>`)

    func defaultCustomMacFolderResultItems(validDirs: [String], limit: Int = 25) -> [SearchResultItem] {
        let addPromptItem = SearchResultItem(
            id: "mac_folder:add_prompt",
            title: L("Thêm thư mục trên Mac vào danh sách tìm kiếm...", "Add Mac folder to search list..."),
            subtitle: L("Bấm ↩ để chọn thêm thư mục từ máy Mac (tìm nhanh qua tiền tố 'm <từ khóa>')", "Press ↩ to choose a folder from Mac (quick search via prefix 'm <keyword>')"),
            path: nil,
            isDirectory: true,
            kind: .addCustomMacFolder,
            badge: L("+ Thêm", "+ Add"),
            sfSymbolFallback: "folder.badge.plus"
        )

        if validDirs.isEmpty {
            return [
                addPromptItem,
                SearchResultItem(
                    id: "mac_folder:empty_hint",
                    title: L("Chưa có thư mục nào trên Mac được thêm", "No Mac folders added yet"),
                    subtitle: L("Nhấn ↩ vào mục trên để chọn thư mục đầu tiên (hoặc vào Cài đặt > Cài đặt chung)", "Press ↩ on the item above to choose first folder (or go to Settings > General)"),
                    path: nil,
                    isDirectory: false,
                    kind: .infoBanner,
                    badge: L("Hướng dẫn", "Guide"),
                    sfSymbolFallback: "info.circle"
                )
            ]
        }

        var items: [SearchResultItem] = []
        var seenPaths = Set<String>()
        let pinnedSet = Set(AppSettings.shared.pinnedPaths)
        let pinnedText = L("Đã ghim", "Pinned")

        // 1. Pinned items located inside configured Mac folders
        for p in AppSettings.shared.pinnedPaths {
            guard validDirs.contains(where: { p == $0 || p.hasPrefix($0 + "/") }),
                  seenPaths.insert(p).inserted else { continue }
            let isDir = isKnownDirectory(p)
            let ext = (p as NSString).pathExtension.uppercased()
            items.append(SearchResultItem(
                id: "mac_pin:\(p)",
                title: (p as NSString).lastPathComponent,
                subtitle: "\(L("Đã ghim (⌘D bỏ ghim)", "Pinned (⌘D to unpin)")) ‹ \(formatHierarchicalSubtitle(p, maxLevels: 3))",
                path: p,
                isDirectory: isDir,
                kind: isDir ? .driveFolder(path: p) : .driveFile(path: p),
                badge: isDir ? pinnedText : (ext.isEmpty ? pinnedText : "\(pinnedText) • \(ext)"),
                sfSymbolFallback: isDir ? "folder.fill" : "doc.fill"
            ))
        }

        // 2. Configured Mac root folders
        for dir in validDirs where seenPaths.insert(dir).inserted {
            let folderName = (dir as NSString).lastPathComponent
            let prettyPath = dir.replacingOccurrences(of: homePath, with: "~")
            items.append(SearchResultItem(
                id: "mac_folder:\(dir)",
                title: folderName,
                subtitle: "\(prettyPath)  •  \(L("↩ Duyệt thư mục • ⌘↩ Xem trong Finder • ⇥ Actions", "↩ Browse folder • ⌘↩ Reveal in Finder • ⇥ Actions"))",
                path: dir,
                isDirectory: true,
                kind: .driveFolder(path: dir),
                badge: pinnedSet.contains(dir) ? pinnedText : L("Thư mục Mac", "Mac Folder"),
                sfSymbolFallback: "folder.fill"
            ))
        }

        // 3. Recently opened subfolders/files inside configured Mac folders
        let sortedHist = history.sorted {
            if $0.value.last_used != $1.value.last_used { return $0.value.last_used > $1.value.last_used }
            return $0.value.count > $1.value.count
        }
        for (hPath, rec) in sortedHist {
            guard items.count < limit else { break }
            guard validDirs.contains(where: { hPath.hasPrefix($0 + "/") }),
                  seenPaths.insert(hPath).inserted else { continue }
            let isDir = isKnownDirectory(hPath)
            guard FileManager.default.fileExists(atPath: hPath) else { continue }
            let ext = (hPath as NSString).pathExtension.uppercased()
            let recentBadge = L("Gần đây", "Recent")
            items.append(SearchResultItem(
                id: "mac_recent:\(hPath)",
                title: (hPath as NSString).lastPathComponent,
                subtitle: "\(L("Mở gần đây (\(rec.count) lần)", "Recently opened (\(rec.count) times)")) ‹ \(formatHierarchicalSubtitle(hPath, maxLevels: 3))",
                path: hPath,
                isDirectory: isDir,
                kind: isDir ? .driveFolder(path: hPath) : .driveFile(path: hPath),
                badge: isDir ? recentBadge : (ext.isEmpty ? recentBadge : ext),
                sfSymbolFallback: isDir ? "folder.fill" : "doc.fill"
            ))
        }

        items.append(addPromptItem)
        return items
    }

    nonisolated static func evaluateMacFolderSearchHits(
        tokens: [String],
        fastIndex: FastSharedIndex,
        historySnapshot: [String: HistoryRecord],
        pinnedSet: Set<String>,
        maxResults: Int
    ) -> [(entry: SharedDriveEntry, historyCount: Int, isPinned: Bool)] {
        let cleanedTokens = tokens.map { raw -> String in
            let strippedDot = raw.hasPrefix(".") ? String(raw.dropFirst()) : raw
            return cleanString(strippedDot)
        }.filter { !$0.isEmpty }
        guard !cleanedTokens.isEmpty && !fastIndex.isEmpty else { return [] }

        let tokenBytes = cleanedTokens.map { Array($0.utf8) }
        let numTokens = tokenBytes.count
        let lastTokIdx = numTokens - 1
        let totalRecs = fastIndex.count

        struct ScoredMacHit {
            let totalScore: Int
            let isDir: Bool
            let hasHistory: Bool
            let negDepth: Int
            let negLen: Int
            let recIdx: Int
            let historyCount: Int
            let isPinned: Bool
        }

        var hits: [ScoredMacHit] = []
        hits.reserveCapacity(128)

        fastIndex.blob.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            for recIdx in 0..<totalRecs {
                let recOff = BinaryIndexCodec.readU32LE(base, 4 &+ recIdx &* 4)
                let pLen = BinaryIndexCodec.readU16LE(base, recOff)
                let pStart = recOff &+ 2
                let isDir = base[pStart &+ pLen] != 0
                var pos = pStart &+ pLen &+ 1
                let dLen = BinaryIndexCodec.readU16LE(base, pos)
                pos &+= 2 &+ dLen
                let numSegs = Int(base[pos])
                pos &+= 1
                if numSegs == 0 { continue }

                var cOffsets = [Int](repeating: 0, count: numSegs)
                var cLens = [Int](repeating: 0, count: numSegs)
                var aOffsets = [Int](repeating: 0, count: numSegs)
                var aLens = [Int](repeating: 0, count: numSegs)
                for s in 0..<numSegs {
                    let cL = Int(base[pos])
                    cOffsets[s] = pos &+ 1
                    cLens[s] = cL
                    pos &+= 1 &+ cL
                    let aL = Int(base[pos])
                    aOffsets[s] = pos &+ 1
                    aLens[s] = aL
                    pos &+= 1 &+ aL
                }

                let leafIdx = numSegs &- 1

                // Pass 1: Ordered hierarchical matching
                var curS = 0
                var orderedMatchedAll = true
                var matchScore = 0
                var leafMatched = false

                for tokIdx in 0..<numTokens {
                    let tok = tokenBytes[tokIdx]
                    var foundS = -1
                    let isLastTok = (tokIdx == lastTokIdx)

                    for sIdx in curS..<numSegs {
                        let cOff = cOffsets[sIdx]
                        let cLen = cLens[sIdx]
                        let aOff = aOffsets[sIdx]
                        let aLen = aLens[sIdx]
                        let segMatch = asciiContainsSlice(base, cOff, cLen, tok)
                        let acrMatch = aLen > 0 && asciiHasPrefixSlice(base, aOff, aLen, from: 0, tok)

                        if segMatch || acrMatch {
                            foundS = sIdx
                            if sIdx == leafIdx { leafMatched = true }
                            let stripIdx = firstNonDigitOffset(base, cOff, cLen)
                            if asciiEqualsSlice(base, cOff, cLen, from: stripIdx, tok)
                                || asciiEqualsSlice(base, cOff, cLen, from: 0, tok)
                                || (aLen > 0 && asciiEqualsSlice(base, aOff, aLen, from: 0, tok)) {
                                matchScore &+= (isLastTok && sIdx == leafIdx) ? 140 : 100
                            } else if asciiHasPrefixSlice(base, cOff, cLen, from: stripIdx, tok)
                                || asciiHasPrefixSlice(base, cOff, cLen, from: 0, tok)
                                || acrMatch {
                                matchScore &+= 85
                            } else {
                                matchScore &+= 55
                            }
                            break
                        }
                    }
                    if foundS != -1 {
                        curS = foundS
                    } else {
                        orderedMatchedAll = false
                        break
                    }
                }

                if orderedMatchedAll {
                    matchScore &+= 140
                } else if numTokens > 1 {
                    var unorderedScore = 0
                    var unorderedLeaf = false
                    var allFound = true

                    for tok in tokenBytes {
                        var bestSegScore = 0
                        for sIdx in stride(from: leafIdx, through: 0, by: -1) {
                            let cOff = cOffsets[sIdx]
                            let cLen = cLens[sIdx]
                            let aOff = aOffsets[sIdx]
                            let aLen = aLens[sIdx]
                            let segMatch = asciiContainsSlice(base, cOff, cLen, tok)
                            let acrMatch = aLen > 0 && asciiHasPrefixSlice(base, aOff, aLen, from: 0, tok)
                            if segMatch || acrMatch {
                                if sIdx == leafIdx { unorderedLeaf = true }
                                let stripIdx = firstNonDigitOffset(base, cOff, cLen)
                                if asciiEqualsSlice(base, cOff, cLen, from: stripIdx, tok)
                                    || asciiEqualsSlice(base, cOff, cLen, from: 0, tok)
                                    || (aLen > 0 && asciiEqualsSlice(base, aOff, aLen, from: 0, tok)) {
                                    bestSegScore = 95
                                } else if asciiHasPrefixSlice(base, cOff, cLen, from: stripIdx, tok)
                                    || asciiHasPrefixSlice(base, cOff, cLen, from: 0, tok)
                                    || acrMatch {
                                    bestSegScore = 75
                                } else {
                                    bestSegScore = 45
                                }
                                break
                            }
                        }
                        if bestSegScore > 0 {
                            unorderedScore &+= bestSegScore
                        } else {
                            allFound = false
                            break
                        }
                    }

                    if allFound && unorderedLeaf {
                        orderedMatchedAll = true
                        matchScore = unorderedScore
                        leafMatched = true
                    }
                }

                guard orderedMatchedAll else { continue }
                if leafMatched { matchScore &+= 1_100 }
                if isDir { matchScore &+= 35 }

                let path = BinaryIndexCodec.decodeUTF8(base, pStart, pLen)
                let isPin = pinnedSet.contains(path)
                let hRec = historySnapshot[path]
                let histBoost = (isPin ? 850 : 0) + (hRec.map { min(150 + $0.count * 20, 320) } ?? 0)

                hits.append(ScoredMacHit(
                    totalScore: matchScore &+ histBoost,
                    isDir: isDir,
                    hasHistory: histBoost > 0,
                    negDepth: -numSegs,
                    negLen: -pLen,
                    recIdx: recIdx,
                    historyCount: hRec?.count ?? 0,
                    isPinned: isPin
                ))
            }
        }

        hits.sort {
            if $0.totalScore != $1.totalScore { return $0.totalScore > $1.totalScore }
            if $0.hasHistory != $1.hasHistory { return $0.hasHistory && !$1.hasHistory }
            if $0.isDir != $1.isDir { return $0.isDir && !$1.isDir }
            if $0.negDepth != $1.negDepth { return $0.negDepth > $1.negDepth }
            return $0.negLen > $1.negLen
        }

        return hits.prefix(maxResults).map { (fastIndex.entry(at: $0.recIdx), $0.historyCount, $0.isPinned) }
    }

    func buildCustomMacSearchResultItems(
        from hits: [(entry: SharedDriveEntry, historyCount: Int, isPinned: Bool)],
        maxResults: Int = 50
    ) -> [SearchResultItem] {
        var results: [SearchResultItem] = []
        results.reserveCapacity(min(hits.count, maxResults))

        for hit in hits.prefix(maxResults) {
            let p = hit.entry.path
            let isDir = hit.entry.isDir
            let ext = (p as NSString).pathExtension.uppercased()
            let pinnedText = L("Đã ghim", "Pinned")
            let badge: String
            if hit.isPinned {
                badge = isDir ? pinnedText : (ext.isEmpty ? pinnedText : "\(pinnedText) • \(ext)")
            } else if isDir {
                badge = L("Thư mục", "Folder")
            } else {
                badge = ext.isEmpty ? L("Tệp Mac", "Mac File") : ext
            }

            let subPrefix: String
            if hit.isPinned {
                subPrefix = "\(pinnedText) ‹ "
            } else if hit.historyCount > 0 {
                subPrefix = "\(L("Mở gần đây (\(hit.historyCount) lần)", "Recently opened (\(hit.historyCount) times)")) ‹ "
            } else {
                subPrefix = ""
            }

            results.append(SearchResultItem(
                id: "mac_hit:\(p)",
                title: (p as NSString).lastPathComponent,
                subtitle: subPrefix + formatHierarchicalSubtitle(p, maxLevels: 3),
                path: p,
                isDirectory: isDir,
                kind: isDir ? .driveFolder(path: p) : .driveFile(path: p),
                badge: badge,
                sfSymbolFallback: isDir ? "folder.fill" : "doc.fill"
            ))
        }
        return results
    }

    // MARK: - CLI Benchmark Entry (--bench-index, §4.2, §4.4, §6)

    static func currentPhysicalMemoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0.0 }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }

    static func runIndexBenchmarkCLI() async {
        print("=== DriveBar Index Benchmark (--bench-index) ===")
        let service = await MainActor.run { GoogleDriveIndexService.shared }
        let cacheDir = await MainActor.run { service.cacheDir }
        let fm = FileManager.default

        let bCache = "\(cacheDir)/drivebar_index_v1.bin"
        let folderPath = "\(cacheDir)/folder_cache.json"
        let sharedPath = "\(cacheDir)/shared_cache.json"
        let filePath = "\(cacheDir)/file_cache.json"
        let macPath = "\(cacheDir)/mac_folders_cache.json"

        // Ensure `drivebar_index_v1.bin` is populated if this is the first run after migration
        if !fm.fileExists(atPath: bCache) {
            let loadedFolders = Self.readFolderCacheDisk(at: folderPath)?.0 ?? []
            let loadedShared = Self.readSharedCacheDisk(at: sharedPath)?.0 ?? []
            let loadedFiles = Self.readFileCacheDisk(at: filePath)?.0 ?? []
            let loadedMac = Self.readMacFoldersCacheDisk(at: macPath)?.items ?? []
            let ff = FastFolderIndex.build(from: loadedFolders)
            let fs = FastSharedIndex.build(from: loadedShared)
            let fi = FastFileIndex.build(from: loadedFiles)
            let fmIdx = FastSharedIndex.build(from: loadedMac)
            Self.saveBinaryIndexToDisk(
                to: bCache,
                timestamp: Date().timeIntervalSince1970,
                macRoots: [],
                folderIndex: ff,
                sharedIndex: fs,
                fileIndex: fi,
                macIndex: fmIdx
            )
        }

        // 1. Cold binary cache load timing (`alwaysMapped`, §5.2)
        let memBefore = currentPhysicalMemoryFootprintMB()
        let loadStart = ProcessInfo.processInfo.systemUptime
        let loadedSnap = Self.loadBinaryIndexFromDisk(at: bCache)
        let fastFolder = loadedSnap?.folderIndex ?? .empty
        let fastShared = loadedSnap?.sharedIndex ?? .empty
        let fastFile = loadedSnap?.fileIndex ?? .empty
        let fastMac = loadedSnap?.macIndex ?? .empty
        let coldLoadMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000.0
        let memAfterLoad = currentPhysicalMemoryFootprintMB()

        print(String(format: "Cold Binary Index Load (drivebar_index_v1.bin) : %.2f ms", coldLoadMs))
        print("  Folders : \(fastFolder.count) (\(fastFolder.blob.count / 1024) KB)")
        print("  Shared  : \(fastShared.count) (\(fastShared.blob.count / 1024) KB)")
        print("  Files   : \(fastFile.count) (\(fastFile.blob.count / 1024) KB)")
        print("  Mac     : \(fastMac.count) (\(fastMac.blob.count / 1024) KB)")
        print(String(format: "  Memory  : %.1f MB (delta +%.1f MB)", memAfterLoad, max(0, memAfterLoad - memBefore)))

        // 2. Single-pass parallel index rebuild timing
        let (mdRoots, sdRoots, customMac) = await MainActor.run {
            service.refreshAccountPaths()
            let md = service.activeAccounts.compactMap(\.myDrivePath)
            let sd = service.activeAccounts.compactMap(\.sharedDrivesPath)
            return (md, sd, AppSettings.shared.customMacFolders)
        }
        let homePath = fm.homeDirectoryForCurrentUser.path

        let rebuildStart = ProcessInfo.processInfo.systemUptime
        let (rebuiltFolders, rebuiltFiles) = await performParallelUnifiedScan(
            myDriveRoots: mdRoots,
            sharedDriveRoots: sdRoots,
            homePath: homePath,
            customMacFolders: customMac,
            reportProgress: false
        )
        let rebuiltFastFolder = FastFolderIndex.build(from: rebuiltFolders)
        let rebuiltFastFile = FastFileIndex.build(from: rebuiltFiles)
        Self.saveBinaryIndexToDisk(
            to: bCache,
            timestamp: Date().timeIntervalSince1970,
            macRoots: customMac,
            folderIndex: rebuiltFastFolder.isEmpty ? fastFolder : rebuiltFastFolder,
            sharedIndex: fastShared,
            fileIndex: rebuiltFastFile.isEmpty ? fastFile : rebuiltFastFile,
            macIndex: fastMac
        )
        let rebuildSec = ProcessInfo.processInfo.systemUptime - rebuildStart
        let memAfterRebuild = currentPhysicalMemoryFootprintMB()

        print(String(format: "Single-Pass Parallel Rebuild + Binary Persist  : %.2f s (%d folders, %d files)", rebuildSec, rebuiltFastFolder.count, rebuiltFastFile.count))
        print(String(format: "  Memory after rebuild                         : %.1f MB", memAfterRebuild))

        let activeFastFolder = rebuiltFastFolder.isEmpty ? fastFolder : rebuiltFastFolder
        let activeFastFile = rebuiltFastFile.isEmpty ? fastFile : rebuiltFastFile

        // 3. 20 sample queries benchmark
        let sampleQueries = [
            "sdh", "baocao", "2026", "nghiencuu", "thongke",
            "lich", "hop", "tailieu", "duan", "hmu",
            "spmph", "deoh", "antoan", "taichinh", "kehoach",
            "daotao", "luong", "hopdong", "bienban", "tonghop"
        ]

        var queryLatenciesMs: [Double] = []
        for q in sampleQueries {
            let tokens = [Self.extractSignatures(q).0]
            let qStart = ProcessInfo.processInfo.systemUptime
            let _ = Self.evaluateMyDriveSearchHits(
                tokens: tokens,
                fastIndex: activeFastFolder,
                historySnapshot: [:],
                maxResults: 45
            )
            let _ = Self.evaluateSharedSearchHits(
                tokens: tokens,
                fastIndex: fastShared,
                historySnapshot: [:],
                maxResults: 45
            )
            let _ = Self.evaluateFileSearchHits(
                tokens: tokens,
                fastIndex: activeFastFile,
                historySnapshot: [:],
                pinnedSet: [],
                maxResults: 45
            )
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - qStart) * 1000.0
            queryLatenciesMs.append(elapsedMs)
        }

        let sortedLat = queryLatenciesMs.sorted()
        let minLat = sortedLat.first ?? 0.0
        let medianLat = sortedLat[sortedLat.count / 2]
        let p95Lat = sortedLat[min(sortedLat.count - 1, Int(Double(sortedLat.count) * 0.95))]
        let maxLat = sortedLat.last ?? 0.0

        print(String(format: "20 Sample Queries (Folder+Shared+File)         : min=%.2f ms, median=%.2f ms, p95=%.2f ms, max=%.2f ms", minLat, medianLat, p95Lat, maxLat))
        print("================================================")
    }
}
