/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
@testable import Storage
@testable import Sync
import XCTest

extension Dictionary {
    init<S: SequenceType where S.Generator.Element == Element>(seq: S) {
        self.init()
        for (k, v) in seq {
            self[k] = v
        }
    }
}

class TestBookmarkTreeMerging: XCTestCase {
    func localTree() -> BookmarkTree {
        let roots = BookmarkRoots.RootChildren.map { BookmarkTreeNode.Folder(guid: $0, children: []) }
        let places = BookmarkTreeNode.Folder(guid: BookmarkRoots.RootGUID, children: roots)

        var lookup: [GUID: BookmarkTreeNode] = [:]
        var parents: [GUID: GUID] = [:]

        for n in roots {
            lookup[n.recordGUID] = n
            parents[n.recordGUID] = BookmarkRoots.RootGUID
        }
        lookup[BookmarkRoots.RootGUID] = places

        return BookmarkTree(subtrees: [places], lookup: lookup, parents: parents, orphans: Set(), deleted: Set())
    }

    // This scenario can never happen in the wild: we'll always have roots.
    func testMergingEmpty() {
        let r = BookmarkTree.emptyTree()
        let m = BookmarkTree.emptyTree()
        let l = BookmarkTree.emptyTree()

        let merger = ThreeWayTreeMerger(local: l, mirror: m, remote: r)
        guard let result = merger.merge().value.successValue else {
            XCTFail("Couldn't merge.")
            return
        }
        //XCTAssertEqual(result, BookmarksMergeResult.NoOp)
    }

    func testMergingOnlyLocalRoots() {
        let r = BookmarkTree.emptyTree()
        let m = BookmarkTree.emptyTree()
        let l = self.localTree()

        let merger = ThreeWayTreeMerger(local: l, mirror: m, remote: r)
        guard let result = merger.merge().value.successValue else {
            XCTFail("Couldn't merge.")
            return
        }
        //XCTAssertEqual(result, BookmarksMergeResult.NoOp) // NOT EVENTUALLY
    }
}
