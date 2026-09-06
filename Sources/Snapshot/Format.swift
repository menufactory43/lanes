import Foundation

/// Constantes du format. Toute modification de layout incrémente `version` :
/// un snapshot d'une autre version est simplement reconstruit.
public enum Format {
    public static let magic: [UInt8] = Array("LANESNAP".utf8)
    public static let version: UInt32 = 2
    public static let headerSize = 24
    public static let tocEntrySize = 24
    public static let alignment = 8
}

/// Identifiant de section. Les valeurs sont stables : ne jamais renuméroter.
public enum SectionKind: UInt32, Sendable, CaseIterable {
    case meta = 1
    case strings = 2
    case commits = 3
    case parents = 4
    case edgeIndex = 5
    case edges = 6
    case authors = 7
    case refs = 8
    case files = 9
    case changes = 10
    case health = 11
    case status = 12
}

/// Layouts des records : offsets en octets et taille (stride).
/// Tous les entiers sont little-endian, lus avec `loadUnaligned`.
public enum Layout {
    public enum Meta {
        public static let stride = 48
        public static let repoPathOff = 0, repoPathLen = 4        // u32, u16
        public static let repoNameOff = 8, repoNameLen = 12       // u32, u16
        public static let headOff = 16, headLen = 20              // u32, u16
        public static let fingerprintOff = 24, fingerprintLen = 28// u32, u16
        public static let builtAt = 32                            // i64
        public static let headCommit = 40                         // u32 (index, 0xFFFFFFFF si aucun)
        public static let flags = 44                              // u32
    }
    public enum Commit {
        public static let stride = 48
        public static let timestamp = 0     // i64
        public static let oid = 8           // 20 octets
        public static let author = 28       // u32
        public static let messageOff = 32   // u32
        public static let messageLen = 36   // u16
        public static let parentCount = 38  // u8
        public static let lane = 39         // u8
        public static let parentStart = 40  // u32
        public static let flags = 44        // u32
    }
    public enum Author {
        public static let stride = 32
        public static let nameOff = 0, nameLen = 4    // u32, u16
        public static let emailOff = 8, emailLen = 12 // u32, u16
        public static let commits = 16                // u32
        public static let firstTs = 20                // i64 (non aligné, volontaire)
        public static let lastTs = 28                 // i32 delta ? non : voir ci-dessous
        // lastTs est stocké sur 4 octets en secondes depuis firstTs (u32).
    }
    public enum Ref {
        public static let stride = 12
        public static let nameOff = 0, nameLen = 4  // u32, u16
        public static let kind = 6                  // u8
        public static let flags = 7                 // u8
        public static let commit = 8                // u32
    }
    public enum File {
        public static let stride = 32
        public static let pathOff = 0, pathLen = 4  // u32, u16
        public static let changes = 8               // u32
        public static let topAuthor = 12            // u32
        public static let lastTs = 16               // i64
        public static let size = 24                 // u64
    }
    public enum Change {
        public static let stride = 20
        public static let file = 0     // u32
        public static let author = 4   // u32
        public static let timestamp = 8 // i64
        public static let commit = 16  // u32
    }
    public enum Health {
        public static let stride = 64
        public static let sizeBytes = 0        // u64
        public static let looseObjects = 8     // u32
        public static let packs = 12           // u32
        public static let staleBranches = 16   // u32
        public static let trackedFiles = 20    // u32
        public static let modified = 24        // u32
        public static let staged = 28          // u32
        public static let untracked = 32       // u32
        public static let localBranches = 36   // u32
        public static let remoteBranches = 40  // u32
        public static let tags = 44            // u32
        public static let ahead = 48           // u32 (0xFFFFFFFF = pas d'upstream)
        public static let behind = 52          // u32
        public static let stashes = 56         // u32
    }
    public enum Status {
        public static let stride = 8
        public static let pathOff = 0, pathLen = 4 // u32, u16
        public static let code = 6                 // u8 (caractère porcelain : M A D R ? …)
        public static let staged = 7               // u8 (1 = index, 0 = arbre de travail)
    }
    public enum Edge {
        public static let stride = 3
        public static let from = 0, to = 1, kind = 2 // u8 chacun
    }
}

public enum RefKind: UInt8, Sendable {
    case localBranch = 0, remoteBranch = 1, tag = 2, other = 3
}

public enum RefFlags {
    public static let isHead: UInt8 = 1 << 0
    public static let stale: UInt8 = 1 << 1      // pas de commit depuis 180 jours
    public static let unmerged: UInt8 = 1 << 2   // non fusionnée dans HEAD
}

public enum CommitFlags {
    public static let merge: UInt32 = 1 << 0
    public static let truncatedParents: UInt32 = 1 << 1
}

/// Nature d'une arête entre la ligne `i` et la ligne `i+1` du graphe.
public enum EdgeKind: UInt8, Sendable {
    /// Voie qui traverse la ligne sans s'arrêter.
    case pass = 0
    /// Part du commit de la ligne vers un parent (même voie ou changement de voie).
    case toParent = 1
}

public let noIndex: UInt32 = 0xFFFF_FFFF
