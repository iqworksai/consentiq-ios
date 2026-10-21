import Foundation

public struct TcfSettings: Decodable, Sendable {
    public static let minimumCmpId = 2

    public var enabled: Bool
    public var gdprApplies: Bool?
    public var cmpId: Int?
    public var cmpVersion: Int?

    enum CodingKeys: String, CodingKey {
        case enabled, gdprApplies, cmpId, cmpVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        gdprApplies = try? container.decodeIfPresent(Bool.self, forKey: .gdprApplies)
        cmpId = try? container.decodeIfPresent(Int.self, forKey: .cmpId)
        cmpVersion = try? container.decodeIfPresent(Int.self, forKey: .cmpVersion)
    }

    /// In-app TCF runs only once IAB has issued a CMP ID; the server sends 0 until then.
    public var isInAppEnabled: Bool {
        enabled && (cmpId ?? 0) >= Self.minimumCmpId
    }
}
