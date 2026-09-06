import Foundation

public struct GitError: Error, CustomStringConvertible, Sendable {
    public let args: [String]
    public let status: Int32
    public let stderr: String
    public var description: String { "git \(args.joined(separator: " ")) → \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

/// Exécute `git` dans un dépôt et rend sa sortie brute.
///
/// Utilise `posix_spawn` directement plutôt que `Foundation.Process` : mesuré à
/// 3 ms par appel contre 80 ms (voir docs/DECISIONS.md, ADR-8). Les deux tubes
/// sont lus avec `poll` pour ne jamais bloquer sur un tube plein.
public struct GitRunner: Sendable {
    public let repoPath: String
    public let gitPath: String

    public init(repoPath: String, gitPath: String = GitRunner.resolvedGitPath) {
        self.repoPath = repoPath
        self.gitPath = gitPath
    }

    /// Le vrai binaire, pas le shim `/usr/bin/git` qui relance `xcode-select` à chaque appel.
    public static let resolvedGitPath: String = {
        let candidates = [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        if let dev = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            let p = dev + "/usr/bin/git"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "/usr/bin/git"
    }()

    private static let baseEnvironment: [String] = {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["GIT_OPTIONAL_LOCKS"] = "0"   // lecture seule : jamais de verrou sur l'index
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env.removeValue(forKey: "GIT_DIR")
        env.removeValue(forKey: "GIT_WORK_TREE")
        return env.map { "\($0.key)=\($0.value)" }
    }()

    @discardableResult
    public func run(_ args: [String], allowFailure: Bool = false) throws -> Data {
        let fullArgs = ["-C", repoPath, "--no-pager", "-c", "core.quotepath=false", "-c", "color.ui=never"] + args
        let (out, err, status) = try Self.spawn(gitPath, fullArgs, environment: Self.baseEnvironment)
        if status != 0 && !allowFailure {
            throw GitError(args: args, status: status, stderr: String(decoding: err, as: UTF8.self))
        }
        return out
    }

    public func string(_ args: [String], allowFailure: Bool = false) throws -> String {
        String(decoding: try run(args, allowFailure: allowFailure), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: posix_spawn

    static func spawn(_ path: String, _ args: [String], environment: [String]) throws -> (stdout: Data, stderr: Data, status: Int32) {
        var outFds: [Int32] = [0, 0], errFds: [Int32] = [0, 0]
        guard pipe(&outFds) == 0, pipe(&errFds) == 0 else { throw GitError(args: args, status: -1, stderr: "pipe") }

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK))
        var noSignals = sigset_t(); sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFds[1], 2)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        close(outFds[1]); close(errFds[1])
        guard rc == 0 else {
            close(outFds[0]); close(errFds[0])
            throw GitError(args: args, status: rc, stderr: "posix_spawn: \(String(cString: strerror(rc)))")
        }

        var out = Data(), err = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        var fds = [pollfd(fd: outFds[0], events: Int16(POLLIN), revents: 0), pollfd(fd: errFds[0], events: Int16(POLLIN), revents: 0)]
        var open = 2
        while open > 0 {
            let n = poll(&fds, 2, -1)
            if n < 0 { if errno == EINTR { continue } else { break } }
            for i in 0..<2 where fds[i].fd >= 0 && fds[i].revents != 0 {
                let r = read(fds[i].fd, &buf, buf.count)
                if r > 0 {
                    if i == 0 { out.append(buf, count: r) } else { err.append(buf, count: r) }
                } else if r == 0 || (r < 0 && errno != EINTR && errno != EAGAIN) {
                    close(fds[i].fd); fds[i].fd = -1; open -= 1
                }
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return (out, err, code)
    }
}

/// Informations de base sur un dépôt, résolues depuis n'importe quel chemin à l'intérieur.
public struct RepoInfo: Sendable, Equatable {
    public let topLevel: String
    public let gitDir: String
    public let name: String

    public static func locate(_ path: String) throws -> RepoInfo {
        let runner = GitRunner(repoPath: path)
        let top = try runner.string(["rev-parse", "--show-toplevel"])
        let gitDir = try runner.string(["rev-parse", "--absolute-git-dir"])
        return RepoInfo(topLevel: top, gitDir: gitDir, name: URL(fileURLWithPath: top).lastPathComponent)
    }
}
