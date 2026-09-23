import Foundation

/// Builds a ZIP archive in memory with uncompressed (stored) entries.
/// Enough for small OOXML packages like .docx, without external tools.
public struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    public init() {}

    public mutating func add(path: String, contents: Data) {
        let name = Data(path.utf8)
        let crc = Self.crc32(contents)
        let size = UInt32(contents.count)
        let offset = UInt32(data.count)
        let (time, date) = (UInt16(0), UInt16((2020 - 1980) << 9 | 1 << 5 | 1))

        var local = Data()
        local.le32(0x0403_4B50)
        local.le16(20)            // version needed
        local.le16(0x0800)        // UTF-8 names
        local.le16(0)             // stored
        local.le16(time); local.le16(date)
        local.le32(crc); local.le32(size); local.le32(size)
        local.le16(UInt16(name.count)); local.le16(0)
        local.append(name)
        data.append(local)
        data.append(contents)

        central.le32(0x0201_4B50)
        central.le16(20); central.le16(20)
        central.le16(0x0800); central.le16(0)
        central.le16(time); central.le16(date)
        central.le32(crc); central.le32(size); central.le32(size)
        central.le16(UInt16(name.count)); central.le16(0); central.le16(0)
        central.le16(0); central.le16(0); central.le32(0)
        central.le32(offset)
        central.append(name)
        count += 1
    }

    public func finalized() -> Data {
        var out = data
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x0605_4B50)
        out.le16(0); out.le16(0)
        out.le16(count); out.le16(count)
        out.le32(UInt32(central.count)); out.le32(centralOffset)
        out.le16(0)
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func le32(_ v: UInt32) { (0..<4).forEach { append(UInt8((v >> (8 * $0)) & 0xFF)) } }
}
