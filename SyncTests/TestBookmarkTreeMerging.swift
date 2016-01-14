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

// Thieved mercilessly from TestSQLiteBookmarks.
private func getBrowserDB(filename: String, files: FileAccessor) -> BrowserDB? {
    let db = BrowserDB(filename: filename, files: files)

    // BrowserTable exists only to perform create/update etc. operations -- it's not
    // a queryable thing that needs to stick around.
    if !db.createOrUpdate(BrowserTable()) {
        return nil
    }
    return db
}

class TestBookmarkTreeMerging: XCTestCase {
    let filename = "TBookmarkTreeMerging.db"
    let files = MockFiles()

    func getSQLiteBookmarks() -> SQLiteBookmarks? {
        guard let db = getBrowserDB(self.filename, files: self.files) else {
            XCTFail("Couldn't get prepared DB.")
            return nil
        }

        return SQLiteBookmarks(db: db)
    }

    func dbLocalTree() -> BookmarkTree? {
        guard let bookmarks = self.getSQLiteBookmarks() else {
            XCTFail("Couldn't get bookmarks.")
            return nil
        }

        return bookmarks.treeForLocal().value.successValue
    }

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

    // Our synthesized tree is the same as the one we pull out of a brand new local DB.
    func testLocalTreeAssumption() {
        let constructed = self.localTree()
        let fromDB = self.dbLocalTree()
        XCTAssertNotNil(fromDB)
        XCTAssertTrue(fromDB!.isFullyRootedIn(constructed))
        XCTAssertTrue(constructed.isFullyRootedIn(fromDB!))
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

        XCTAssertTrue(result.isNoOp)
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

        // TODO: enable this when basic merging is implemented.
        // XCTAssertFalse(result.isNoOp)
    }
}
