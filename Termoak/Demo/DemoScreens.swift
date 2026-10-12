import Foundation

// What the demo's terminals show (DemoMode.swift): a made-up session per
// host, in color (ANSI), drawn again for each size of the terminal so it
// never wraps. web-1 has the shell with `ls --color`, `git log` and
// `systemctl`; web-2 runs htop; db-primary psql; monitoring docker.

enum DemoScreens {
    /// Text with its SGR attributes ("1;32"; empty: plain).
    struct Span {
        let sgr: String
        let text: String
        init(_ sgr: String, _ text: String) {
            self.sgr = sgr
            self.text = text
        }
    }

    typealias Line = [Span]

    private static let esc = "\u{1b}["

    /// The whole screen of `host` (its label, `os` its system) for `user`,
    /// `cols` × `rows`. `broadcast`: it ends with the `uptime` typed in every
    /// pane at once.
    static func screen(host: String, os: String?, user: String, cols: Int, rows: Int, broadcast: Bool) -> Data {
        let cols = max(cols, 20)
        let rows = max(rows, 5)
        if host == "web-2" { return Data(htop(cols: cols, rows: rows).utf8) }
        var lines: [Line]
        switch host {
        case "web-1": lines = web(user: user, host: host, cols: cols)
        case "db-primary": lines = database(user: user, host: host, cols: cols)
        case "monitoring": lines = containers(user: user, host: host)
        default: lines = motd(host: host, os: os, cols: cols)
        }
        let path = host == "web-1" ? "~/app" : "~"
        if broadcast || !["web-1", "db-primary", "monitoring"].contains(host) {
            lines.append(command(user, host, path, "uptime"))
            lines.append([Span("", uptime(host))])
        }
        lines.append(prompt(user, host, path))
        let text = lines.map { render($0, cols: cols) }.joined(separator: "\r\n")
        // Out of a full-screen program, the cursor shown, a clean screen.
        return Data("\(esc)?1049l\(esc)?25h\(esc)0m\(esc)H\(esc)2J\(esc)3J\(text)".utf8)
    }

    /// The line as the terminal gets it, cut at `cols` characters.
    static func render(_ line: Line, cols: Int) -> String {
        var out = ""
        var left = cols
        for span in line where left > 0 {
            let piece = String(span.text.prefix(left))
            left -= piece.count
            out += span.sgr.isEmpty ? piece : "\(esc)\(span.sgr)m\(piece)\(esc)0m"
        }
        return out
    }

    // MARK: Shell

    static func prompt(_ user: String, _ host: String, _ path: String) -> Line {
        [Span("1;32", "\(user)@\(host)"), Span("", ":"), Span("1;34", path), Span("", "$ ")]
    }

    static func command(_ user: String, _ host: String, _ path: String, _ text: String) -> Line {
        prompt(user, host, path) + [Span("", text)]
    }

    private static func uptime(_ host: String) -> String {
        let load: String
        switch host {
        case "web-1": load = "0.42, 0.38, 0.31"
        case "db-primary": load = "1.87, 1.64, 1.52"
        case "monitoring": load = "0.21, 0.24, 0.22"
        default: load = "0.08, 0.11, 0.09"
        }
        return " 09:41:07 up 41 days,  6:12,  1 user,  load average: \(load)"
    }

    /// What the host says at login: Ubuntu's summary, Debian's kernel line,
    /// or only the last login.
    private static func motd(host: String, os: String?, cols: Int) -> [Line] {
        let last: Line = [Span("", "Last login: Mon Oct 12 09:38:02 2026 from 10.0.0.25")]
        switch os {
        case "ubuntu":
            var lines: [Line] = [[Span("", "Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-45-generic x86_64)")], []]
            if cols >= 66 {
                lines += [
                    [Span("", "  System load:  0.42              Processes:             187")],
                    [Span("", "  Usage of /:   38.6% of 77.36GB  Users logged in:       1")],
                    [Span("", "  Memory usage: 31%               Swap usage:            0%")],
                ]
            } else {
                lines += [
                    [Span("", "  System load:  0.42")],
                    [Span("", "  Usage of /:   38.6% of 77.36GB")],
                    [Span("", "  Memory usage: 31%")],
                ]
            }
            return lines + [[], last]
        case "debian":
            return [[Span("", "Linux \(host) 6.1.0-25-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.106-3 x86_64")], [], last]
        default:
            return [last]
        }
    }

    /// web-1: the files, the history of the app and nginx running.
    private static func web(user: String, host: String, cols: Int) -> [Line] {
        var lines = motd(host: host, os: "ubuntu", cols: cols)
        lines.append(command(user, host, "~", "ls --color"))
        let files: [(String, String)] = [
            ("app", "1;34"), ("backups", "1;34"), ("deploy.sh", "1;32"), ("logs", "1;34"), ("nginx", "1;34"),
            ("README.md", ""), ("release-2.4.1.tar.gz", "1;31"), ("dashboard.png", "1;35"),
        ]
        lines += columns(files, cols: cols)
        lines.append(command(user, host, "~", "cd app && git log --oneline --graph -7"))
        let y = "33", head = "1;36", branch = "1;32", remote = "1;31", tag = "1;33"
        lines += [
            [Span("", "* "), Span(y, "3f9c2a1 ("), Span(head, "HEAD -> "), Span(branch, "main"), Span(y, ", "),
             Span(remote, "origin/main"), Span(y, ")"), Span("", " Add health check endpoint")],
            [Span("", "* "), Span(y, "8b41e07"), Span("", " Cache static assets for 7 days")],
            [Span("", "*   "), Span(y, "c7d02f9"), Span("", " Merge branch 'rate-limit'")],
            [Span("31", "|"), Span("32", "\\")],
            [Span("31", "| "), Span("", "* "), Span(y, "5e1a9b3"), Span("", " Rate limit the login API")],
            [Span("", "* "), Span("32", "| "), Span(y, "9a7c3d4"), Span("", " Upgrade to Node 22")],
            [Span("32", "|/")],
            [Span("", "* "), Span(y, "2d6f0e8 ("), Span(tag, "tag: v2.4.1"), Span(y, ")"), Span("", " Release 2.4.1")],
        ]
        lines.append(command(user, host, "~/app", "systemctl status nginx -n0"))
        lines += [
            [Span("1;32", "●"), Span("", " nginx.service - A high performance web server")],
            [Span("", "     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled)")],
            [Span("", "     Active: "), Span("1;32", "active (running)"), Span("", " since Mon 2026-10-12 07:12:44 UTC; 2h 28min ago")],
            [Span("", "   Main PID: 1042 (nginx)")],
            [Span("", "     Memory: 12.4M (peak: 14.1M)")],
        ]
        return lines
    }

    /// Names in columns, like `ls` in a terminal of `cols` columns.
    static func columns(_ names: [(String, String)], cols: Int) -> [Line] {
        guard !names.isEmpty else { return [] }
        for count in stride(from: names.count, through: 1, by: -1) {
            let height = (names.count + count - 1) / count
            var widths: [Int] = []
            for c in 0..<count {
                let column = names[min(c * height, names.count)..<min((c + 1) * height, names.count)]
                if column.isEmpty { break }
                widths.append(column.map(\.0.count).max() ?? 0)
            }
            let total = widths.reduce(0, +) + 2 * (widths.count - 1)
            guard total <= cols || count == 1 else { continue }
            return (0..<height).map { row in
                var line: Line = []
                for (c, width) in widths.enumerated() {
                    let i = c * height + row
                    guard i < names.count else { break }
                    let (name, sgr) = names[i]
                    line.append(Span(sgr, name))
                    let last = c == widths.count - 1 || (c + 1) * height + row >= names.count
                    if !last { line.append(Span("", String(repeating: " ", count: width - name.count + 2))) }
                }
                return line
            }
        }
        return []
    }

    /// db-primary: the size of the databases and the cluster.
    private static func database(user: String, host: String, cols: Int) -> [Line] {
        var lines = motd(host: host, os: "debian", cols: cols)
        lines.append(command(user, host, "~", "psql -c '\\l+' | cut -c1-40"))
        lines += [
            [Span("", "  datname  |  owner   |  size   ")],
            [Span("", "-----------+----------+---------")],
            [Span("", " shop      | shop     | "), Span("1", "18 GB")],
            [Span("", " analytics | metabase | 6402 MB")],
            [Span("", " postgres  | postgres | 7901 kB")],
            [Span("", "(3 rows)")],
            [],
        ]
        lines.append(command(user, host, "~", "pg_lsclusters"))
        lines += [
            [Span("", "Ver Cluster Port Status Owner    Data directory")],
            [Span("", "16  main    5432 "), Span("32", "online"), Span("", " postgres /var/lib/postgresql/16/main")],
        ]
        return lines
    }

    /// monitoring: its containers.
    private static func containers(user: String, host: String) -> [Line] {
        let healthy = Span("32", "(healthy)")
        var lines: [Line] = [command(user, host, "~", "docker ps --format '{{.Names}}\\t{{.Status}}'")]
        lines += [
            [Span("1", "NAMES           STATUS")],
            [Span("", "grafana         Up 12 days "), healthy],
            [Span("", "prometheus      Up 12 days "), healthy],
            [Span("", "node-exporter   Up 12 days")],
            [Span("", "alertmanager    Up 12 days")],
            [Span("", "loki            Up 3 days "), healthy],
        ]
        lines.append(command(user, host, "~", "curl -s localhost:9090/-/healthy"))
        lines.append([Span("", "Prometheus Server is Healthy.")])
        return lines
    }

    // MARK: htop

    /// htop on a full screen of `cols` × `rows`.
    static func htop(cols: Int, rows: Int) -> String {
        let wide = cols >= 70
        let meter = wide ? cols / 2 : cols
        let cpus: [(user: Double, kernel: Double)] = [(31.2, 7.0), (18.4, 6.3), (52.9, 8.1), (9.6, 2.8)]
        var left: [Line] = cpus.enumerated().map { i, c in
            bar(String(format: "%3d", i), [(c.user, "32"), (c.kernel, "31")],
                String(format: "%.1f%%", c.user + c.kernel), width: meter)
        }
        left.append(bar("Mem", [(24.0, "32"), (4.0, "34"), (17.0, "33")], "2.41G/7.75G", width: meter))
        left.append(bar("Swp", [], "0K/2.00G", width: meter))
        let info: [Line] = [
            [Span("36", "Tasks: "), Span("1", "87"), Span("36", ", "), Span("1", "214"), Span("36", " thr; "),
             Span("1;32", "2"), Span("36", " running")],
            [Span("36", "Load average: "), Span("1", "0.42 "), Span("36", "0.38 0.31")],
            [Span("36", "Uptime: "), Span("1", "41 days, 06:12:09")],
        ]
        var header: [Line] = []
        if wide {
            for i in 0..<left.count {
                let right: Line = i < info.count ? [Span("", "  ")] + info[i] : []
                header.append(left[i] + right)
            }
        } else {
            header = left + info.map { [Span("", " ")] + $0 }
        }
        header.append([])
        func lp(_ t: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - t.count)) + t }
        func rp(_ t: String, _ n: Int) -> String { t + String(repeating: " ", count: max(0, n - t.count)) }
        let titles = lp("PID", 7) + " " + rp("USER", 9) + " " + lp("PRI", 3) + " " + lp("NI", 3) + " " + lp("VIRT", 5)
            + " " + lp("RES", 5) + " " + lp("SHR", 5) + " S " + lp("CPU%", 5) + " " + lp("MEM%", 4) + " " + lp("TIME+", 8) + "  Command"
        header.append([Span("30;42", pad(titles, cols))])
        let processes: [(pid: String, user: String, virt: String, res: String, shr: String, state: String,
                         cpu: String, mem: String, time: String, command: String)] = [
            ("1042", "www-data", "412M", "86.1M", "12.3M", "S", "12.3", "1.1", "4:12.07", "nginx: worker process"),
            ("913", "deploy", "1.20G", "498M", "41.2M", "R", "8.7", "6.4", "51:02.33", "node /srv/app/server.js"),
            ("1043", "www-data", "412M", "84.9M", "12.1M", "S", "6.1", "1.1", "3:58.41", "nginx: worker process"),
            ("1650", "deploy", "1.18G", "471M", "40.8M", "S", "1.9", "6.0", "12:40.71", "node /srv/app/worker.js"),
            ("622", "root", "216M", "28.4M", "25.1M", "S", "1.2", "0.4", "9:11.08", "/usr/bin/containerd"),
            ("2211", "deploy", "10.2M", "5.6M", "3.4M", "R", "0.7", "0.1", "0:00.42", "htop"),
            ("480", "root", "47.1M", "12.0M", "9.1M", "S", "0.6", "0.2", "1:02.11", "/usr/lib/systemd/systemd-journald"),
            ("811", "root", "15.4M", "9.2M", "7.8M", "S", "0.0", "0.1", "0:00.19", "sshd: deploy [priv]"),
            ("1", "root", "167M", "13.1M", "8.4M", "S", "0.0", "0.2", "0:41.55", "/sbin/init"),
            ("702", "syslog", "217M", "6.2M", "4.6M", "S", "0.0", "0.1", "0:12.30", "/usr/sbin/rsyslogd -n"),
            ("730", "root", "1.71G", "38.2M", "21.0M", "S", "0.0", "0.5", "6:31.02", "/usr/bin/dockerd"),
            ("741", "root", "82.8M", "3.8M", "3.3M", "S", "0.0", "0.0", "0:03.17", "/usr/sbin/irqbalance"),
            ("755", "root", "16.9M", "7.9M", "6.9M", "S", "0.0", "0.1", "0:01.09", "/lib/systemd/systemd-logind"),
            ("803", "root", "6.8M", "2.9M", "2.6M", "S", "0.0", "0.0", "0:00.48", "/usr/sbin/cron -f"),
            ("977", "deploy", "17.1M", "10.1M", "8.3M", "S", "0.0", "0.1", "0:00.21", "/lib/systemd/systemd --user"),
        ]
        let room = max(0, rows - header.count - 1)
        var table: [Line] = []
        for i in 0..<room {
            let p = processes[i % processes.count]
            let before = lp(p.pid, 7) + " " + rp(p.user, 9) + " " + lp("20", 3) + " " + lp("0", 3) + " " + lp(p.virt, 5)
                + " " + lp(p.res, 5) + " " + lp(p.shr, 5) + " "
            let after = " " + lp(p.cpu, 5) + " " + lp(p.mem, 4) + " " + lp(p.time, 8) + "  "
            if i == 0 {
                // The selected process.
                table.append([Span("30;46", pad(before + p.state + after + p.command, cols))])
            } else {
                table.append([Span("", before), Span(p.state == "R" ? "1;32" : "", p.state), Span("", after),
                              Span(p.command.hasPrefix("/") ? "" : "1", p.command)])
            }
        }
        var footer: Line = []
        for (key, label) in [("F1", "Help  "), ("F2", "Setup "), ("F3", "Search"), ("F4", "Filter"), ("F5", "Tree  "),
                             ("F6", "SortBy"), ("F7", "Nice -"), ("F8", "Nice +"), ("F9", "Kill  "), ("F10", "Quit")] {
            footer += [Span("", key), Span("30;46", label)]
        }
        let used = footer.reduce(0) { $0 + $1.text.count }
        if used < cols { footer.append(Span("30;46", String(repeating: " ", count: cols - used))) }
        let screen = Array((header + table).prefix(rows - 1)) + [footer]
        var out = "\(esc)?1049h\(esc)?25l\(esc)0m\(esc)H\(esc)2J"
        for (i, line) in screen.enumerated() {
            out += "\(esc)\(i + 1);1H" + render(line, cols: cols)
        }
        return out
    }

    /// A meter of htop: `  0[|||||||       38.2%]`.
    private static func bar(_ label: String, _ parts: [(Double, String)], _ value: String, width: Int) -> Line {
        let inner = max(4, width - label.count - 3)
        var line: Line = [Span("36", label), Span("1", "[")]
        var used = 0
        let room = max(0, inner - value.count - 1)
        for (percent, sgr) in parts {
            let n = min(room - used, Int((percent / 100 * Double(inner)).rounded()))
            guard n > 0 else { continue }
            line.append(Span(sgr, String(repeating: "|", count: n)))
            used += n
        }
        line.append(Span("", String(repeating: " ", count: max(0, inner - used - value.count))))
        line.append(Span("2", value))
        line.append(Span("1", "]"))
        line.append(Span("", " "))
        return line
    }

    private static func pad(_ text: String, _ cols: Int) -> String {
        text.count >= cols ? String(text.prefix(cols)) : text + String(repeating: " ", count: cols - text.count)
    }
}
