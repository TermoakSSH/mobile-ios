import TermoakKit
import Foundation

extension HostSettings {
    /// These settings with `over`'s on top (the engine's `overlay`: each
    /// value set in `over` wins; the environment is merged).
    func overlay(_ over: HostSettings) -> HostSettings {
        var s = self
        s.env.merge(over.env) { _, new in new }
        s.port = over.port ?? port
        s.username = over.username ?? username
        s.identityId = over.identityId ?? identityId
        s.keyId = over.keyId ?? keyId
        s.jumpHostIds = over.jumpHostIds ?? jumpHostIds
        s.startupSnippetId = over.startupSnippetId ?? startupSnippetId
        s.keepaliveSecs = over.keepaliveSecs ?? keepaliveSecs
        s.agentForwarding = over.agentForwarding ?? agentForwarding
        s.term = over.term ?? term
        s.theme = over.theme ?? theme
        s.recordSessions = over.recordSessions ?? recordSessions
        s.proxy = over.proxy ?? proxy
        return s
    }

    /// The defaults a host in `groupId` gets from that group and the ones
    /// above it (`groups`: those of the host's account and vault).
    static func inherited(groupId: String?, groups: [HostGroup]) -> HostSettings {
        let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let chain = GroupChain.ids(from: groupId) { id in byId[id].map { $0.parentId } }
        // The top group first, the nearest one last (it wins).
        return chain.reversed().compactMap { byId[$0]?.settings }.reduce(HostSettings()) { $0.overlay($1) }
    }
}
