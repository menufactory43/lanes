import Testing
@testable import GraphLayout

@Suite struct GraphLayoutTests {
    func run(_ parents: [[Int?]]) -> GraphLayout.Result {
        GraphLayout.layout(count: parents.count) { parents[$0] }
    }

    @Test func linearHistoryStaysOnLaneZero() {
        let r = run([[1], [2], [3], []])
        #expect(r.lanes == [0, 0, 0, 0])
        #expect(r.maxLane == 0)
        #expect(r.rowEdges[0] == [.init(from: 0, to: 0, toParent: true)])
        #expect(r.rowEdges[3].isEmpty)
    }

    @Test func mergeOpensSecondLaneAndClosesIt() {
        // 0 = merge(1, 2) ; 1 → 3 ; 2 → 3 ; 3 racine
        let r = run([[1, 2], [3], [3], []])
        #expect(r.lanes == [0, 0, 1, 0])
        #expect(r.maxLane == 1)
        // Ligne 0 : vers parent 1 sur voie 0, vers parent 2 sur voie 1.
        #expect(r.rowEdges[0].contains(.init(from: 0, to: 0, toParent: true)))
        #expect(r.rowEdges[0].contains(.init(from: 0, to: 1, toParent: true)))
        // Ligne 1 : voie 1 traverse, commit 1 → 3 reste voie 0.
        #expect(r.rowEdges[1].contains(.init(from: 1, to: 1, toParent: false)))
        // Ligne 2 : commit 2 rejoint la voie 0 qui attend déjà 3.
        #expect(r.rowEdges[2].contains(.init(from: 1, to: 0, toParent: true)))
    }

    @Test func freedLanesAreReused() {
        // Deux branches successives qui ne se chevauchent pas doivent partager la voie 1.
        let r = run([[1, 2], [3], [3], [4, 5], [6], [6], []])
        #expect(r.lanes[2] == 1)
        #expect(r.lanes[5] == 1)
        #expect(r.maxLane == 1)
    }

    @Test func parentOutsideSnapshotEndsLane() {
        let r = run([[nil], [nil]])
        #expect(r.lanes == [0, 0])
        #expect(r.rowEdges[0].isEmpty)
    }

    @Test func unrelatedRootsTakeSeparateLanesWhenOverlapping() {
        // 0 → 2 ; 1 racine (autre historique) ; 2 racine
        let r = run([[2], [], []])
        #expect(r.lanes[0] == 0)
        #expect(r.lanes[1] == 1)
        #expect(r.lanes[2] == 0)
    }

    @Test func largeLinearIsFast() {
        let n = 200_000
        let r = GraphLayout.layout(count: n) { $0 + 1 < n ? [$0 + 1] : [] }
        #expect(r.maxLane == 0)
        #expect(r.rowEdges.count == n)
    }
}
