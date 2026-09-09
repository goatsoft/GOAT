import Foundation
import zlib

/// A bounded, memory-only ZIP reader. No archive path is ever extracted to the filesystem.
enum PackageArchive {
    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumFileBytes = 1_024 * 1_024

    static func files(in data: Data) throws -> [String: Data] {
        guard data.count >= 22, data.count <= maximumBytes else { throw PackageError.invalidArchive }
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ width: Int) throws -> Int {
            guard offset >= 0, offset + width <= bytes.count else { throw PackageError.invalidArchive }
            return (0..<width).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
        }
        let end = (max(0, bytes.count - 65_557)...(bytes.count - 22)).reversed().first {
            (try? number($0, 4)) == 0x06054b50 && (try? number($0 + 20, 2)) == bytes.count - $0 - 22
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else {
            throw PackageError.invalidArchive
        }
        let count = try number(end + 10, 2)
        let central = try number(end + 16, 4)
        guard count > 0, count <= 256, try number(end + 8, 2) == count,
            central + (try number(end + 12, 4)) == end
        else { throw PackageError.invalidArchive }
        var cursor = central
        var total = 0
        var files: [String: Data] = [:]
        var names = Set<String>()
        var ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x02014b50 else { throw PackageError.invalidArchive }
            let flags = try number(cursor + 8, 2)
            let method = try number(cursor + 10, 2)
            let checksum = try number(cursor + 16, 4)
            let compressed = try number(cursor + 20, 4)
            let size = try number(cursor + 24, 4)
            let nameLength = try number(cursor + 28, 2)
            let extraLength = try number(cursor + 30, 2)
            let commentLength = try number(cursor + 32, 2)
            let attributes = try number(cursor + 38, 4)
            let local = try number(cursor + 42, 4)
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= end, nameLength > 0, nameLength <= 240,
                flags & ~0x080e == 0, method == 0 || method == 8,
                try number(cursor + 34, 2) == 0,
                size <= maximumFileBytes, compressed <= maximumBytes,
                let path = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8)
            else { throw PackageError.invalidArchive }
            let directory = path.hasSuffix("/")
            let canonical = directory ? String(path.dropLast()) : path
            guard validPath(canonical), names.insert(canonical.lowercased()).inserted else {
                throw PackageError.unsafePath
            }
            let mode = attributes >> 16
            let type = mode & 0xf000
            guard type == 0 || type == (directory ? 0x4000 : 0x8000),
                directory || mode & 0o111 == 0, !directory || size == 0
            else { throw PackageError.unsafePath }
            guard local < central, try number(local, 4) == 0x04034b50,
                try number(local + 6, 2) == flags, try number(local + 8, 2) == method,
                try number(local + 26, 2) == nameLength
            else { throw PackageError.invalidArchive }
            let start = local + 30 + nameLength + (try number(local + 28, 2))
            guard start <= central, start + compressed <= central,
                bytes[(local + 30)..<(local + 30 + nameLength)] == bytes[(cursor + 46)..<(cursor + 46 + nameLength)]
            else { throw PackageError.invalidArchive }
            if flags & 8 == 0 {
                guard try number(local + 14, 4) == checksum,
                    try number(local + 18, 4) == compressed, try number(local + 22, 4) == size
                else { throw PackageError.invalidArchive }
            }
            let range = local..<(start + compressed)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw PackageError.invalidArchive }
            ranges.append(range)
            total += size
            guard total <= maximumBytes else { throw PackageError.invalidArchive }
            let payload = Data(bytes[start..<(start + compressed)])
            let decoded = try method == 0 ? payload : inflate(payload, size: size)
            guard decoded.count == size else { throw PackageError.invalidArchive }
            let actual = decoded.withUnsafeBytes {
                crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(decoded.count))
            }
            guard actual == checksum else { throw PackageError.invalidArchive }
            if !directory { files[path] = decoded }
            cursor = next
        }
        guard cursor == end else { throw PackageError.invalidArchive }
        // Reject a regular file that is also used as a parent directory.
        for path in files.keys {
            let parts = path.split(separator: "/")
            for depth in 1..<parts.count {
                guard
                    files.keys.allSatisfy({ $0.lowercased() != parts.prefix(depth).joined(separator: "/").lowercased() }
                    )
                else {
                    throw PackageError.unsafePath
                }
            }
        }
        return files
    }

    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.utf8.count <= 240 && parts.count <= 12
            && parts.allSatisfy { part in
                !part.isEmpty && !part.hasPrefix(".")
                    && part.utf8.allSatisfy {
                        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                            || [45, 46, 95].contains($0)
                    }
            }
    }

    private static func inflate(_ data: Data, size: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PackageError.invalidArchive
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: size + 1)
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(size + 1)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.total_in == data.count else {
            throw PackageError.invalidArchive
        }
        output.count = size
        return output
    }
}

public enum PackageError: LocalizedError, Sendable {
    case invalidArchive, unsafePath, invalidManifest, unsupportedVersion, invalidContents
    public var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "The GOATed package is not a supported ZIP archive, is damaged, or exceeds its size limits."
        case .unsafePath: "The package contains an unsafe path, duplicate entry, executable file or link."
        case .invalidManifest: "extension.json has invalid, missing or unsupported fields."
        case .unsupportedVersion: "This package requires an unsupported GOATed format or API version."
        case .invalidContents:
            "The package contains missing, invalid or unsupported content. Only declared skills, prompts and text resources are supported."
        }
    }
}
