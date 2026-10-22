import Foundation

/// 複数の再生画面の要求をまとめ、別画面の解除で視聴を妨げない。
public struct PlaybackIdlePolicy: Sendable {
    private var owners: Set<UUID> = []

    public init() {}
    public var requestCount: Int { owners.count }

    public mutating func setNeedsContinuousDisplay(_ needed: Bool, for owner: UUID) {
        if needed { owners.insert(owner) }
        else { owners.remove(owner) }
    }

    public func preventsSleep(applicationIsActive: Bool) -> Bool {
        applicationIsActive && !owners.isEmpty
    }
}
