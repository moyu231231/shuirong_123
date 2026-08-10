import Foundation

/// 对齐 PC `Port65010UplinkFilter`：局内丢弃上行 4013 整帧。
public final class Port65010UplinkFilter {
    private var leftover: [UInt8] = []
    private var dropping4013 = false

    public init() {}

    public static func is4013At(_ d: [UInt8], _ i: Int) -> Bool {
        i >= 0 && i + 8 <= d.count
            && d[i] == 0x33 && d[i + 1] == 0x66
            && d[i + 2] == 0x00 && d[i + 3] == 0x0B
            && d[i + 4] == 0x00 && d[i + 5] == 0x0C
            && d[i + 6] == 0x40 && d[i + 7] == 0x13
    }

    public static func isFrameAt(_ d: [UInt8], _ i: Int) -> Bool {
        i >= 0 && i + 8 <= d.count
            && d[i] == 0x33 && d[i + 1] == 0x66
            && d[i + 2] == 0x00 && d[i + 3] == 0x0B
            && d[i + 4] == 0x00 && d[i + 5] == 0x0C
    }

    public static func contains4013(_ data: Data) -> Bool {
        let d = [UInt8](data)
        guard d.count >= 8 else { return false }
        for i in 0...(d.count - 8) where is4013At(d, i) { return true }
        return false
    }

    public func filter(_ chunk: Data) -> (Data, Int) {
        var dropped = 0
        if chunk.isEmpty { return (chunk, 0) }
        var data = leftover + [UInt8](chunk)
        leftover = []
        var i = 0
        if dropping4013 {
            let next = indexOfFrame(data, 0)
            if next < 0 {
                dropped = data.count
                keepTail(data, data.count)
                return (Data(), dropped)
            }
            dropped += next
            i = next
            dropping4013 = false
        }
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        while i < data.count {
            if i + 8 > data.count {
                leftover = Array(data[i..<data.count])
                break
            }
            if !Self.isFrameAt(data, i) {
                if data[i] == 0x33 && i + 1 == data.count {
                    leftover = [data[i]]
                    break
                }
                out.append(data[i])
                i += 1
                continue
            }
            let next = indexOfFrame(data, i + 8)
            let frameEnd = next >= 0 ? next : data.count
            if next < 0 && data.count - i < 16 {
                leftover = Array(data[i..<data.count])
                break
            }
            let flen = frameEnd - i
            if Self.is4013At(data, i) {
                dropped += flen
                if next < 0 {
                    dropping4013 = true
                    keepTail(data, data.count)
                    break
                }
                i = frameEnd
                continue
            }
            out.append(contentsOf: data[i..<frameEnd])
            i = frameEnd
        }
        return (Data(out), dropped)
    }

    private func keepTail(_ data: [UInt8], _ end: Int) {
        let keep = min(7, end)
        leftover = keep > 0 ? Array(data[(end - keep)..<end]) : []
    }

    private func indexOfFrame(_ data: [UInt8], _ start: Int) -> Int {
        guard start <= data.count - 8 else { return -1 }
        for i in start...(data.count - 8) where Self.isFrameAt(data, i) { return i }
        return -1
    }
}

/// 对齐 PC `Port65010DownlinkFilter`：丢弃下行检测文件帧。
public final class Port65010DownlinkFilter {
    private var leftover: [UInt8] = []
    private var dropping = false

    public init() {}

    public static func isDetectionFileTlv(_ tt: UInt8) -> Bool {
        switch tt {
        case 0x06, 0x07, 0x09, 0x0A, 0x0F, 0x11, 0x12,
             0x16, 0x17, 0x18, 0x1B, 0x1D, 0x44, 0x66:
            return true
        default:
            return false
        }
    }

    public func filter(_ chunk: Data) -> (Data, Int) {
        var dropped = 0
        if chunk.isEmpty { return (chunk, 0) }
        var data = leftover + [UInt8](chunk)
        leftover = []
        var i = 0
        if dropping {
            let next = indexOfFrame(data, 0)
            if next < 0 {
                dropped = data.count
                keepTail(data, data.count)
                return (Data(), dropped)
            }
            dropped += next
            i = next
            dropping = false
        }
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        while i < data.count {
            if i + 8 > data.count {
                leftover = Array(data[i..<data.count])
                break
            }
            if !Port65010UplinkFilter.isFrameAt(data, i) {
                if data[i] == 0x33 && i + 1 == data.count {
                    leftover = [data[i]]
                    break
                }
                out.append(data[i])
                i += 1
                continue
            }
            let next = indexOfFrame(data, i + 8)
            let frameEnd = next >= 0 ? next : data.count
            if Port65010UplinkFilter.is4013At(data, i) && next < 0 && data.count - i < 20 {
                leftover = Array(data[i..<data.count])
                break
            }
            var drop = false
            if Port65010UplinkFilter.is4013At(data, i) && i + 20 <= data.count
                && data[i + 16] == 0x19 && data[i + 17] == 0x00 && data[i + 18] == 0x00
                && Self.isDetectionFileTlv(data[i + 19]) {
                drop = true
            } else if Port65010UplinkFilter.is4013At(data, i) && frameEnd - i >= 1500 {
                drop = true
            }
            if drop {
                dropped += frameEnd - i
                if next < 0 {
                    dropping = true
                    keepTail(data, data.count)
                    break
                }
                i = frameEnd
                continue
            }
            out.append(contentsOf: data[i..<frameEnd])
            i = frameEnd
        }
        return (Data(out), dropped)
    }

    private func keepTail(_ data: [UInt8], _ end: Int) {
        let keep = min(7, end)
        leftover = keep > 0 ? Array(data[(end - keep)..<end]) : []
    }

    private func indexOfFrame(_ data: [UInt8], _ start: Int) -> Int {
        guard start <= data.count - 8 else { return -1 }
        for i in start...(data.count - 8) where Port65010UplinkFilter.isFrameAt(data, i) { return i }
        return -1
    }
}
