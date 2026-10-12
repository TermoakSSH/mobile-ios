import Foundation
import TermoakKit

// The made-up world of the demo (DemoMode.swift): two accounts, their
// vaults, hosts, groups, snippets and keys, AI tasks and server sessions.
// Only example.com addresses and 10.0.x.x hosts.

enum DemoData {
    static let work = "acct-work"
    static let personal = "acct-personal"
    /// Vaults: the Work account's own and shared one, the Personal account's.
    static let workVault = "work"
    static let opsVault = "ops"
    static let homeVault = "home"

    /// The names given to the accounts on this device (Settings).
    static var aliases: [String: String] {
        [work: demoText("Work", "Trabajo"), personal: demoText("Personal", "Personal")]
    }

    /// Now, in milliseconds (as the engine dates things).
    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static func ago(minutes: Double) -> Int64 { now - Int64(minutes * 60_000) }

    // MARK: Accounts and vaults

    static var accounts: [AccountInfo] {
        [
            AccountInfo(id: work, serverUrl: "https://ssh.example.com", serverName: "ssh.example.com", official: false,
                        insecure: false, email: "alex@example.com", name: "Alex Rivera", userId: "u-alex",
                        status: .active, color: "#3b82f6", isCurrent: true, vaultsSupported: true,
                        lastSyncAt: ago(minutes: 1)),
            AccountInfo(id: personal, serverUrl: "https://termoak.com", serverName: "termoak.com", official: true,
                        insecure: false, email: "alex.rivera@example.com", name: "Alex Rivera", userId: "u-alex2",
                        status: .active, color: "#10b981", isCurrent: false, vaultsSupported: true,
                        lastSyncAt: ago(minutes: 3)),
        ]
    }

    static var vaults: [VaultInfo] {
        [
            VaultInfo(id: workVault, accountId: work, name: "Personal", description: "", kind: .personal, role: .manager,
                      teamId: nil, teamName: nil, ownerName: "Alex Rivera", color: nil, icon: nil,
                      memberCount: 1, hostCount: 1, strict: false, teamMemberRole: nil),
            VaultInfo(id: opsVault, accountId: work, name: "Ops",
                      description: demoText("Production and staging servers of the web shop.",
                                            "Servidores de producción y staging de la tienda web."),
                      kind: .shared, role: .manager, teamId: nil, teamName: nil, ownerName: "Alex Rivera",
                      color: "#f59e0b", icon: "server", memberCount: 5, hostCount: 11, strict: false, teamMemberRole: nil),
            VaultInfo(id: homeVault, accountId: personal, name: "Personal", description: "", kind: .personal, role: .manager,
                      teamId: nil, teamName: nil, ownerName: "Alex Rivera", color: nil, icon: nil,
                      memberCount: 1, hostCount: 1, strict: false, teamMemberRole: nil),
        ]
    }

    /// Members of the shared vault (`Ops`).
    static var opsMembers: [VaultMember] {
        [
            VaultMember(id: "m-alex", kind: .user, userId: "u-alex", email: "alex@example.com", name: "Alex Rivera",
                        teamId: nil, role: .manager, implicit: true, addedAt: ago(minutes: 60 * 24 * 90)),
            VaultMember(id: "m-sam", kind: .user, userId: "u-sam", email: "sam@example.com", name: "Sam Lee",
                        teamId: nil, role: .editor, implicit: false, addedAt: ago(minutes: 60 * 24 * 60)),
            VaultMember(id: "m-maria", kind: .user, userId: "u-maria", email: "maria@example.com", name: "María García",
                        teamId: nil, role: .editor, implicit: false, addedAt: ago(minutes: 60 * 24 * 30)),
            VaultMember(id: "m-jordan", kind: .user, userId: "u-jordan", email: "jordan@example.com", name: "Jordan Park",
                        teamId: nil, role: .useOnly, implicit: false, addedAt: ago(minutes: 60 * 24 * 12)),
            VaultMember(id: "m-oncall", kind: .team, userId: nil, email: nil, name: demoText("On-call", "Guardias"),
                        teamId: "team-oncall", role: .useOnly, implicit: false, addedAt: ago(minutes: 60 * 24 * 7)),
        ]
    }

    static var teams: [Team] {
        [Team(id: "team-oncall", name: demoText("On-call", "Guardias"), role: .owner, memberCount: 6, createdAt: ago(minutes: 60 * 24 * 200))]
    }

    // MARK: Hosts

    static let production = "group-production"
    static let staging = "group-staging"

    static var groups: [HostGroup] {
        [
            HostGroup(id: production, name: demoText("Production", "Producción"), color: "#ef4444",
                      settings: HostSettings(username: "deploy"), syncMode: .synced, updatedAt: ago(minutes: 600),
                      accountId: work, vaultId: opsVault, access: .manager),
            HostGroup(id: staging, name: "Staging", color: "#8b5cf6",
                      settings: HostSettings(username: "deploy"), syncMode: .synced, updatedAt: ago(minutes: 600),
                      accountId: work, vaultId: opsVault, access: .manager),
        ]
    }

    private static func host(_ id: String, _ label: String, _ address: String, user: String, os: String, version: String,
                             tags: [String], group: String? = nil, favorite: Bool = false, key: String? = nil,
                             account: String = work, vault: String = opsVault, notes: String = "") -> SshHost {
        var settings = HostSettings(username: user)
        settings.keyId = key
        return SshHost(id: id, label: label, address: address, groupId: group, tags: tags, settings: settings,
                       notes: notes, os: os, osVersion: version, favorite: favorite, syncMode: .synced,
                       updatedAt: ago(minutes: 120), accountId: account, vaultId: vault, access: .manager)
    }

    static var hosts: [SshHost] {
        [
            host("h-web-1", "web-1", "10.0.1.11", user: "deploy", os: "ubuntu", version: "24.04",
                 tags: ["web", "nginx"], favorite: true, key: "k-deploy",
                 notes: demoText("Behind the load balancer.", "Detrás del balanceador.")),
            host("h-web-2", "web-2", "10.0.1.12", user: "deploy", os: "ubuntu", version: "24.04",
                 tags: ["web", "nginx"], key: "k-deploy"),
            host("h-db-primary", "db-primary", "10.0.2.10", user: "postgres", os: "debian", version: "12",
                 tags: ["db", "postgres"], key: "k-deploy"),
            host("h-staging-web", "staging-web", "10.0.3.21", user: "deploy", os: "rocky", version: "9.4",
                 tags: ["web", "staging"], key: "k-deploy"),
            host("h-monitoring", "monitoring", "10.0.4.5", user: "ops", os: "alpine", version: "3.20",
                 tags: ["grafana", "prometheus"], vault: workVault),
            host("h-backup", "backup", "10.0.9.20", user: "backup", os: "debian", version: "12",
                 tags: ["backup", "nas"], account: personal, vault: homeVault),
            // Inside the groups.
            host("h-k8s-1", "k8s-node-1", "10.0.5.11", user: "deploy", os: "ubuntu", version: "22.04",
                 tags: ["k8s"], group: production, key: "k-deploy"),
            host("h-k8s-2", "k8s-node-2", "10.0.5.12", user: "deploy", os: "ubuntu", version: "22.04",
                 tags: ["k8s"], group: production, key: "k-deploy"),
            host("h-k8s-3", "k8s-node-3", "10.0.5.13", user: "deploy", os: "ubuntu", version: "22.04",
                 tags: ["k8s"], group: production, key: "k-deploy"),
            host("h-db-replica", "db-replica", "10.0.2.11", user: "postgres", os: "debian", version: "12",
                 tags: ["db", "postgres"], group: production, key: "k-deploy"),
            host("h-cache-1", "cache-1", "10.0.2.20", user: "ops", os: "alpine", version: "3.20",
                 tags: ["redis"], group: production, key: "k-deploy"),
            host("h-staging-db", "staging-db", "10.0.3.22", user: "postgres", os: "rocky", version: "9.4",
                 tags: ["db", "staging"], group: staging, key: "k-deploy"),
            host("h-staging-worker", "staging-worker", "10.0.3.23", user: "deploy", os: "rocky", version: "9.4",
                 tags: ["worker", "staging"], group: staging, key: "k-deploy"),
        ]
    }

    /// Round trip of each host (the status dots and the terminal's bar);
    /// `nil`: it does not answer.
    static func latency(_ hostId: String) -> UInt32? {
        switch hostId {
        case "h-web-1": return 23
        case "h-web-2": return 27
        case "h-db-primary": return 31
        case "h-staging-web": return 48
        case "h-monitoring": return 18
        case "h-backup": return 64
        case "h-staging-worker": return nil
        default: return 20 + UInt32(hostId.utf8.reduce(0) { ($0 + Int($1)) % 20 })
        }
    }

    // MARK: Snippets and keys

    static var snippets: [Snippet] {
        func snippet(_ id: String, _ name: String, _ script: String, _ description: String, _ tags: [String]) -> Snippet {
            Snippet(id: id, name: name, script: script, description: description, tags: tags, syncMode: .synced,
                    updatedAt: ago(minutes: 300), accountId: work, vaultId: opsVault, access: .manager)
        }
        return [
            snippet("s-reload", demoText("Reload nginx", "Recargar nginx"), "sudo nginx -t && sudo systemctl reload nginx",
                    demoText("Checks the configuration first.", "Comprueba antes la configuración."), ["nginx"]),
            snippet("s-disk", demoText("Disk usage", "Uso del disco"), "df -h -x tmpfs -x devtmpfs", "", ["ops"]),
            snippet("s-logs", demoText("Follow app logs", "Seguir los logs de la app"), "journalctl -u app -f -n 100", "", ["logs"]),
            snippet("s-deploy", demoText("Deploy release", "Desplegar versión"), "cd ~/app && ./deploy.sh {{version}}",
                    demoText("Asks for the version.", "Pide la versión."), ["deploy"]),
            snippet("s-vacuum", "VACUUM ANALYZE", "psql -c 'VACUUM (VERBOSE, ANALYZE);'", "", ["postgres"]),
        ]
    }

    static var keys: [SshKey] {
        [
            SshKey(id: "k-deploy", label: "deploy", algorithm: "ssh-ed25519",
                   publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoKeyOnlyForScreenshotsXq9w deploy@example.com",
                   fingerprint: "SHA256:Zq3vY0rM1oVq9pD7m2Xc8bN4hT6kL1sE5wA0uJ7fR2g", comment: "deploy@example.com",
                   syncMode: .synced, hasPrivateKey: true, updatedAt: ago(minutes: 60 * 24 * 40),
                   accountId: work, vaultId: opsVault, access: .manager),
            SshKey(id: "k-laptop", label: "alex@laptop", algorithm: "ssh-ed25519",
                   publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoLaptopKeyForScreenshotsP4k alex@laptop",
                   fingerprint: "SHA256:b7Hk2mQ9sV4xR1nT8cY3wL6pZ0aE5gJ2uD9fK1oM4iA", comment: "alex@laptop",
                   syncMode: .synced, hasPrivateKey: true, updatedAt: ago(minutes: 60 * 24 * 100),
                   accountId: work, vaultId: workVault, access: .manager),
        ]
    }

    // MARK: Server sessions

    static var serverSessions: ServerSessionList {
        func session(_ id: String, _ host: String?, _ title: String, minutes: Double, recording: Bool) -> ServerSession {
            ServerSession(id: id, ownerId: "u-alex", hostId: host, title: title, kind: "server", state: .running,
                          createdAt: ago(minutes: minutes), cols: 120, rows: 36, recording: recording, access: .owner,
                          viewers: [], participants: [], driver: nil, ownerName: "Alex Rivera")
        }
        let shared = ServerSession(id: "srv-shared", ownerId: "u-sam", hostId: "h-staging-web",
                                   title: demoText("Load test", "Prueba de carga"), kind: "server", state: .running,
                                   createdAt: ago(minutes: 25), cols: 120, rows: 36, recording: false, access: .control,
                                   viewers: [], participants: [], driver: nil, ownerName: "Sam Lee")
        return ServerSessionList(
            active: [
                session("srv-deploy", "h-web-1", demoText("deploy v2.4.1", "despliegue v2.4.1"), minutes: 42, recording: true),
                session("srv-migrate", "h-db-primary", demoText("migration", "migración"), minutes: 130, recording: false),
            ],
            shared: [shared],
            recent: [])
    }

    // MARK: Files

    static let home = "/home/deploy"

    /// What a folder holds: the home's, a few folders and files right under
    /// it, only files further down (so walking a folder ends).
    static func files(in path: String) -> [RemoteFile] {
        func entry(_ name: String, dir: Bool = false, size: UInt64 = 4096, minutes: Double, mode: String? = nil) -> RemoteFile {
            let full = path == "/" ? "/\(name)" : "\(path)/\(name)"
            let modeString = mode ?? (dir ? "drwxr-xr-x" : "-rw-r--r--")
            return RemoteFile(name: name, path: full, kind: dir ? .dir : .file, size: size,
                              mode: dir ? 0o40755 : 0o100644, modeString: modeString,
                              modified: (now - Int64(minutes * 60_000)) / 1000, owner: "deploy", group: "deploy")
        }
        if path == home {
            return [
                entry(".ssh", dir: true, minutes: 60 * 24 * 90, mode: "drwx------"),
                entry(".bashrc", size: 3_771, minutes: 60 * 24 * 90),
                entry("app", dir: true, minutes: 14),
                entry("backups", dir: true, minutes: 60 * 9),
                entry("logs", dir: true, minutes: 3),
                entry("nginx", dir: true, minutes: 60 * 26),
                entry("deploy.sh", size: 2_412, minutes: 60 * 24 * 3, mode: "-rwxr-xr-x"),
                entry("README.md", size: 5_830, minutes: 60 * 24 * 10),
                entry("release-2.4.1.tar.gz", size: 48_318_771, minutes: 42),
                entry("db-dump-2026-10-11.sql.gz", size: 1_284_501_337, minutes: 60 * 15),
                entry("traffic-report.pdf", size: 812_664, minutes: 60 * 30),
                entry("screenshot-dashboard.png", size: 1_946_112, minutes: 60 * 50),
            ]
        }
        let files = [
            entry("config.yml", size: 1_204, minutes: 60 * 5),
            entry("server.log", size: 7_340_032, minutes: 2),
        ]
        guard path.split(separator: "/").count <= 3 else { return files }
        return [entry("current", dir: true, minutes: 14), entry("shared", dir: true, minutes: 60 * 24)] + files
    }

    // MARK: AI

    static let diskTask = "t-disk"
    static let copilotTask = "t-copilot"

    /// A conversation as the server keeps it (`AiTask.rawJson`).
    static func conversation(_ messages: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["messages": messages])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func user(_ text: String) -> [String: Any] {
        ["role": "user", "content": [["type": "text", "text": text]]]
    }

    static func assistant(_ text: String, tool: (id: String, command: String)? = nil) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let tool {
            content.append(["type": "tool_call", "id": tool.id, "name": "run_command", "input": ["command": tool.command]])
        }
        return ["role": "assistant", "content": content]
    }

    static func result(_ id: String, _ output: String) -> [String: Any] {
        ["role": "user", "content": [["type": "tool_result", "id": id, "content": output]]]
    }

    static func approval(_ id: String, task: String, command: String?, host: String, risk: AiRiskLevel,
                         reasons: [AiRiskReason], explanation: String, path: String? = nil, diff: String? = nil,
                         added: UInt32? = nil, removed: UInt32? = nil) -> AiApproval {
        let file = path != nil
        let input: [String: Any] = file ? ["path": path ?? "", "host": host] : ["command": command ?? "", "host": host]
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(), as: UTF8.self)
        let preview = AiApprovalPreview(kind: file ? "file" : "command", command: command, host: host, risk: risk,
                                        reasons: reasons, explanation: explanation, path: path, diff: diff,
                                        added: added, removed: removed, newFile: false, truncated: false,
                                        diffError: nil, plan: nil, editable: !file)
        return AiApproval(id: id, taskId: task, tool: file ? "write_file" : "run_command", inputJson: json,
                          summary: file ? (path ?? "") : (command ?? ""), status: "pending", decidedBy: nil,
                          createdAt: ago(minutes: 1), decidedAt: nil, preview: preview)
    }

    /// The tasks of the Work account, newest first.
    static var tasks: [AiTask] {
        let prompt = demoText("db-primary is almost out of disk space. Find out why and free some up.",
                              "A db-primary casi no le queda disco. Averigua por qué y libera espacio.")
        let messages: [[String: Any]] = [
            user(prompt),
            assistant(demoText("I'll check what is using the disk on db-primary.",
                               "Voy a ver qué está ocupando el disco en db-primary."),
                      tool: ("c1", "df -h / /var && sudo du -xh /var --max-depth=2 | sort -rh | head -5")),
            result("c1", """
                Filesystem      Size  Used Avail Use% Mounted on
                /dev/vda1        80G   76G  4.1G  95% /
                41G   /var
                24G   /var/log
                22G   /var/log/postgresql
                12G   /var/lib/postgresql
                1.6G  /var/cache/apt
                """),
            assistant(demoText("""
                The PostgreSQL logs take **22 GB**: `log_min_duration_statement = 0` logs every query and \
                logrotate only rotates them weekly. I propose two changes:
                1. Keep the logs for 7 days, rotated daily and compressed.
                2. Remove the rotated logs older than a week.
                """, """
                Los logs de PostgreSQL ocupan **22 GB**: `log_min_duration_statement = 0` registra todas las \
                consultas y logrotate solo los rota cada semana. Propongo dos cambios:
                1. Guardar los logs 7 días, rotados a diario y comprimidos.
                2. Borrar los logs rotados de hace más de una semana.
                """)),
        ]
        let diff = """
            @@ -1,8 +1,9 @@
             /var/log/postgresql/*.log {
            -       weekly
            -       rotate 10
            +       daily
            +       rotate 7
            +       compress
            +       delaycompress
                    copytruncate
                    missingok
                    notifempty
            -       compress
             }
            """
        let approvals = [
            approval("a-logrotate", task: diskTask, command: nil, host: "db-primary", risk: .low,
                     reasons: [AiRiskReason(code: "changes", text: "Changes a file")],
                     explanation: demoText("Rotates the PostgreSQL logs every day and keeps a week.",
                                           "Rota los logs de PostgreSQL cada día y guarda una semana."),
                     path: "/etc/logrotate.d/postgresql-common", diff: diff, added: 4, removed: 3),
            approval("a-cleanup", task: diskTask,
                     command: "sudo find /var/log/postgresql -name '*.log.*' -mtime +7 -delete", host: "db-primary",
                     risk: .medium,
                     reasons: [AiRiskReason(code: "sudo", text: "Runs as root"),
                               AiRiskReason(code: "delete", text: "Deletes files")],
                     explanation: demoText("Frees about 19 GB. Only rotated logs older than 7 days are deleted.",
                                           "Libera unos 19 GB. Solo borra logs rotados de hace más de 7 días.")),
        ]
        let disk = AiTask(id: diskTask, title: demoText("Free disk space on db-primary", "Liberar disco en db-primary"),
                          prompt: prompt, status: .waitingApproval, mode: .ask, provider: "anthropic",
                          usedProvider: "Claude", hostIds: ["h-db-primary"], createdAt: ago(minutes: 4),
                          updatedAt: ago(minutes: 1), finishedAt: nil, result: nil, error: nil, costMicros: 41_000,
                          pendingApprovals: approvals, rawJson: conversation(messages))
        func done(_ id: String, _ title: String, _ result: String, hosts: [String], minutes: Double) -> AiTask {
            AiTask(id: id, title: title, prompt: title, status: .completed, mode: .ask, provider: "anthropic",
                   usedProvider: "Claude", hostIds: hosts, createdAt: ago(minutes: minutes + 3),
                   updatedAt: ago(minutes: minutes), finishedAt: ago(minutes: minutes), result: result, error: nil,
                   costMicros: 23_000, pendingApprovals: [], rawJson: conversation([user(title), assistant(result)]))
        }
        return [
            disk,
            done("t-tls", demoText("Renew the TLS certificates of the web servers", "Renovar los certificados TLS de los servidores web"),
                 demoText("Renewed on web-1 and web-2; they expire on 10 January.", "Renovados en web-1 y web-2; caducan el 10 de enero."),
                 hosts: ["h-web-1", "h-web-2"], minutes: 60 * 3),
            done("t-502", demoText("Why does web-2 return 502 errors?", "¿Por qué web-2 devuelve errores 502?"),
                 demoText("The app ran out of memory at 03:12; it was restarted with a 2 GB limit.",
                          "La app se quedó sin memoria a las 03:12; se reinició con un límite de 2 GB."),
                 hosts: ["h-web-2"], minutes: 60 * 26),
            done("t-upgrade", demoText("Upgrade packages on staging", "Actualizar paquetes en staging"),
                 demoText("37 packages upgraded on staging-web; no reboot needed.",
                          "37 paquetes actualizados en staging-web; no hace falta reiniciar."),
                 hosts: ["h-staging-web"], minutes: 60 * 50),
        ]
    }

    /// What the copilot asks in its scene.
    static var copilotPrompt: String {
        demoText("The site returns 502 errors. What's wrong?", "La web devuelve errores 502. ¿Qué pasa?")
    }

    /// The copilot's conversation about web-1 (created when it is asked).
    static var copilot: AiTask {
        let messages: [[String: Any]] = [
            user(copilotPrompt),
            assistant(demoText("Let me look at the nginx error log.", "Voy a mirar el log de errores de nginx."),
                      tool: ("k1", "sudo tail -n 3 /var/log/nginx/error.log")),
            result("k1", "connect() failed (111: Connection refused) while connecting to upstream, upstream: \"http://127.0.0.1:3000/\""),
            assistant(demoText("nginx can't reach the app on port 3000. Checking the service:",
                               "nginx no llega a la app en el puerto 3000. Miro el servicio:"),
                      tool: ("k2", "systemctl is-active app; journalctl -u app -n 2 --no-pager")),
            result("k2", "failed\napp.service: Main process exited, code=killed, status=9/KILL\napp.service: Failed with result 'oom-kill'."),
            assistant(demoText("The **app** service was killed for running out of memory. Restarting it brings the site back.",
                               "El servicio **app** se cerró por falta de memoria. Al reiniciarlo vuelve la web.")),
        ]
        let restart = approval("a-restart", task: copilotTask, command: "sudo systemctl restart app", host: "web-1", risk: .medium,
                               reasons: [AiRiskReason(code: "sudo", text: "Runs as root"),
                                         AiRiskReason(code: "service", text: "Restarts a service")],
                               explanation: demoText("Restarts the app; requests wait about 2 seconds.",
                                                     "Reinicia la app; las peticiones esperan unos 2 segundos."))
        return AiTask(id: copilotTask, title: demoText("502 errors on web-1", "Errores 502 en web-1"), prompt: copilotPrompt,
                      status: .waitingApproval, mode: .ask, provider: "anthropic", usedProvider: "Claude",
                      hostIds: ["h-web-1"], createdAt: ago(minutes: 0.5), updatedAt: ago(minutes: 0.2), finishedAt: nil,
                      result: nil, error: nil, costMicros: 12_000, pendingApprovals: [restart], rawJson: conversation(messages))
    }

    static var providers: AiProviders {
        AiProviders(defaultProvider: "anthropic", fallback: [], defaultMode: .ask, providers: [
            AiProvider(key: "anthropic", label: "Claude", driver: "anthropic", available: true, hidden: false,
                       defaultModel: "claude-sonnet", models: ["claude-sonnet"], subscription: false, reason: nil,
                       reasonCode: nil, acceptsOwnKey: true, usesOwnKey: false),
        ])
    }
}
