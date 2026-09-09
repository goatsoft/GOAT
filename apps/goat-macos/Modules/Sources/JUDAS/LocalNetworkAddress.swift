import Darwin
import Foundation

/// Literal local addresses only. DNS aliases do not acquire local-network authority by name.
public enum LocalNetworkAddress {
    public static func contains(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return contains(host: host)
    }

    public static func contains(host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" { return true }
        if let octets = ipv4(host) { return isLocal(octets) }
        var literal = host
        if literal.hasPrefix("["), literal.hasSuffix("]") {
            literal = String(literal.dropFirst().dropLast())
        }
        // An IPv6 interface scope changes routing, not whether the destination is local.
        let scoped = literal.split(separator: "%", omittingEmptySubsequences: false)
        guard scoped.count <= 2 else { return false }
        if scoped.count == 2 {
            guard !scoped[1].isEmpty, scoped[1].utf8.count <= 64,
                scoped[1].utf8.allSatisfy({
                    ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 45
                })
            else { return false }
            literal = String(scoped[0])
        }
        var address = in6_addr()
        guard inet_pton(AF_INET6, literal, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return true }
        if bytes[0] & 0xfe == 0xfc { return true }  // IPv6 unique local, fc00::/7
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return true }  // link-local, fe80::/10
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isLocal(Array(bytes.suffix(4)))
        }
        return false
    }

    private static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count == 1 || part.first != "0",
                part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let value = UInt8(part)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isLocal(_ octets: [UInt8]) -> Bool {
        octets[0] == 127 || octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
    }
}
