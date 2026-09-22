import Foundation

/// Un fichier touché par un commit, avec ses lignes ajoutées et supprimées.
public struct CommitFileChange: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let added: Int      // -1 = binaire
    public let deleted: Int
    public let status: Character  // A M D R C
    public var isBinary: Bool { added < 0 }
}

/// Lecture à la demande des fichiers d'un commit. Un seul appel `git show`,
/// numstat + name-status, quelques millisecondes.
public enum CommitInspector {
    public static func files(repoPath: String, hash: String, limit: Int = 400) throws -> [CommitFileChange] {
        let git = GitRunner(repoPath: repoPath)
        let numstat = try git.run(["show", "--first-parent", "--format=", "--numstat", "-M", "--no-color", hash])
        let status = try git.run(["show", "--first-parent", "--format=", "--name-status", "-M", "--no-color", hash], allowFailure: true)
        var statusByPath: [String: Character] = [:]
        for line in String(decoding: status, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 2, let c = f[0].first else { continue }
            statusByPath[String(f.last!)] = c
        }
        var out: [CommitFileChange] = []
        for line in String(decoding: numstat, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 3 else { continue }
            var path = String(f[2])
            if f.count > 3 { path = String(f[f.count - 1]) } // renommage : "old\tnew"
            if let arrow = path.range(of: " => ") { path = String(path[arrow.upperBound...]).replacingOccurrences(of: "}", with: "") }
            let a = Int(f[0]) ?? -1, d = Int(f[1]) ?? -1
            out.append(CommitFileChange(path: path, added: a, deleted: d, status: statusByPath[path] ?? "M"))
            if out.count >= limit { break }
        }
        return out
    }
}

/// Clonage d'un dépôt avec progression, en lecture de stderr en flux.
public enum Cloner {
    public struct Progress: Sendable { public let line: String }

    public static func clone(url: String, into directory: URL, progress: @escaping @Sendable (String) -> Void) throws -> String {
        let name = Self.repoName(from: url)
        let dest = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw GitError(args: ["clone"], status: 1, stderr: String(localized: "folder \(dest.path) already exists"))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let args = ["-C", directory.path, "clone", "--progress", url, dest.path]
        let status = try GitRunner.spawnStreaming(GitRunner.resolvedGitPath, args, onStderrChunk: progress)
        guard status == 0 else { throw GitError(args: ["clone", url], status: status, stderr: String(localized: "clone failed (exit code \(status))")) }
        return dest.path
    }

    public static func repoName(from url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let last = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? "depot"
        return last.isEmpty ? "depot" : last
    }

    /// Normalise ce que l'utilisateur tape : URL complète, `owner/repo`, ou URL sans schéma.
    public static func normalize(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("git@") || s.hasPrefix("ssh://") || s.hasPrefix("file://") || s.hasPrefix("/") { return s }
        if s.hasPrefix("github.com/") || s.hasPrefix("gitlab.com/") || s.hasPrefix("origin.cursor.com/") { return "https://" + s }
        let parts = s.split(separator: "/")
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { return "https://github.com/\(s)" }
        return nil
    }
}

extension GitRunner {
    /// Variante en flux : stderr est livré par morceaux (progression de `git clone`).
    static func spawnStreaming(_ path: String, _ args: [String], onStderrChunk: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var errFds: [Int32] = [0, 0]
        guard pipe(&errFds) == 0 else { throw GitError(args: args, status: -1, stderr: "pipe") }
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, errFds[1], 2)
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"; env["LC_ALL"] = "C"
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr)
        close(errFds[1])
        guard rc == 0 else { close(errFds[0]); throw GitError(args: args, status: rc, stderr: String(cString: strerror(rc))) }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let r = read(errFds[0], &buf, buf.count)
            if r > 0 { onStderrChunk(String(decoding: buf[0..<r], as: UTF8.self)) }
            else if r == 0 || errno != EINTR { break }
        }
        close(errFds[0])
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}
