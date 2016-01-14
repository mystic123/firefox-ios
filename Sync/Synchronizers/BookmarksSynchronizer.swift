/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage
import XCGLogger

private let log = Logger.syncLogger

// MARK: - External synchronizer interface.

public class BufferingBookmarksSynchronizer: TimestampedSingleCollectionSynchronizer, Synchronizer {
    public required init(scratchpad: Scratchpad, delegate: SyncDelegate, basePrefs: Prefs) {
        super.init(scratchpad: scratchpad, delegate: delegate, basePrefs: basePrefs, collection: "bookmarks")
    }

    override var storageVersion: Int {
        return BookmarksStorageVersion
    }

    public func synchronizeBookmarksToStorage(storage: SyncableBookmarks, usingBuffer buffer: BookmarkBufferStorage, withServer storageClient: Sync15StorageClient, info: InfoCollections, greenLight: () -> Bool) -> SyncResult {
        if let reason = self.reasonToNotSync(storageClient) {
            return deferMaybe(.NotStarted(reason))
        }

        let encoder = RecordEncoder<BookmarkBasePayload>(decode: BookmarkType.somePayloadFromJSON, encode: { $0 })

        guard let bookmarksClient = self.collectionClient(encoder, storageClient: storageClient) else {
            log.error("Couldn't make bookmarks factory.")
            return deferMaybe(FatalError(message: "Couldn't make bookmarks factory."))
        }

        let mirrorer = BookmarksMirrorer(storage: buffer, client: bookmarksClient, basePrefs: self.prefs, collection: "bookmarks")
        let applier = MergeApplier(buffer: buffer, storage: storage, client: bookmarksClient, greenLight: greenLight)

        // TODO: if the mirrorer tells us we're incomplete, then don't bother trying to sync!
        // We will need to extend the BookmarksMirrorer interface to allow us to see what's
        // going on.
        return mirrorer.go(info, greenLight: greenLight)
           >>> applier.go
    }
}

private class MergeApplier {
    let greenLight: () -> Bool
    let buffer: BookmarkBufferStorage
    let storage: SyncableBookmarks
    let client: Sync15CollectionClient<BookmarkBasePayload>
    let merger: BookmarksStorageMerger

    init(buffer: BookmarkBufferStorage, storage: SyncableBookmarks, client: Sync15CollectionClient<BookmarkBasePayload>, greenLight: () -> Bool) {
        self.greenLight = greenLight
        self.buffer = buffer
        self.storage = storage
        self.merger = NoOpBookmarksMerger(buffer: buffer, storage: storage)
        self.client = client
    }

    func go() -> SyncResult {
        if !self.greenLight() {
            log.info("Green light turned red; not merging bookmarks.")
            return deferMaybe(SyncStatus.Completed)
        }

        return self.merger.merge() >>== { result in
            result.describe(log)
            return result.uploadCompletion.applyToClient(self.client)
              >>== { result.overrideCompletion.applyToStore(self.storage, withUpstreamResult: $0) }
               >>> { result.bufferCompletion.applyToBuffer(self.buffer) }
               >>> always(SyncStatus.Completed)
        }

    }
}

// MARK: - Self-description.

protocol DescriptionDestination {
    func write(message: String)
}

extension XCGLogger: DescriptionDestination {
    func write(message: String) {
        self.info(message)
    }
}

// MARK: - Protocols to define merge results.

protocol PerhapsNoOp {
    var isNoOp: Bool { get }
}

protocol UpstreamCompletionOp: PerhapsNoOp {
    func describe(log: DescriptionDestination)

    // TODO: this should probably return a timestamp.
    // The XIUS that we'll need for the upload can be captured as part of the op.
    func applyToClient(client: Sync15CollectionClient<BookmarkBasePayload>) -> Deferred<Maybe<UploadResult>>
}

protocol LocalOverrideCompletionOp: PerhapsNoOp {
    func describe(log: DescriptionDestination)
    func applyToStore(storage: SyncableBookmarks, withUpstreamResult upstream: UploadResult) -> Success
}

protocol BufferCompletionOp: PerhapsNoOp {
    func describe(log: DescriptionDestination)
    func applyToBuffer(buffer: BookmarkBufferStorage) -> Success
}

struct BookmarksMergeResult: PerhapsNoOp {
    let uploadCompletion: UpstreamCompletionOp
    let overrideCompletion: LocalOverrideCompletionOp
    let bufferCompletion: BufferCompletionOp

    // If this is true, the merge was only partial, and you should try again immediately.
    // This allows for us to make progress on individual subtrees, without having huge
    // waterfall steps.
    let again: Bool

    var isNoOp: Bool {
        return self.uploadCompletion.isNoOp &&
               self.overrideCompletion.isNoOp &&
               self.bufferCompletion.isNoOp &&
               !self.again
    }

    func describe(log: DescriptionDestination) {
        log.write("Merge result:")
        self.uploadCompletion.describe(log)
        self.overrideCompletion.describe(log)
        self.bufferCompletion.describe(log)
        log.write("Again? \(again)")
    }

    static let NoOp = BookmarksMergeResult(uploadCompletion: UpstreamCompletionNoOp(), overrideCompletion: LocalOverrideCompletionNoOp(), bufferCompletion: BufferCompletionNoOp(), again: false)
}


/**
 * The merger takes as input an existing storage state (mirror and local override),
 * a buffer of new incoming records that relate to the mirror, and performs a three-way
 * merge.
 *
 * The merge itself does not mutate storage. The result of the merge is conceptually a
 * tuple: a new mirror state, a set of reconciled + locally changed records to upload,
 * and two checklists of buffer and local state to discard.
 *
 * Typically the merge will be complete, resulting in a new mirror state, records to
 * upload, and completely emptied buffer and local. In the case of partial inconsistency
 * this will not be the case; incomplete subtrees will remain in the buffer. (We don't
 * expect local subtrees to ever be incomplete.)
 *
 * It is expected that the caller will immediately apply the result in this order:
 *
 * 1. Upload the remote changes, if any. If this fails we can retry the entire process.
 *
 * 2(a). Apply the local changes, if any. If this fails we will re-download the records
 *       we just uploaded, and should reach the same end state.
 *       This step takes a timestamp key from (1), because pushing a record into the mirror
 *       requires a server timestamp.
 *
 * 2(b). Switch to the new mirror state. If this fails, we should find that our reconciled
 *       server contents apply neatly to our mirror and empty local, and we'll reach the
 *       same end state.
 *       Mirror state is applied in a sane order to respect relational constraints:
 *
 *       - Add any new records in the value table.
 *       - Change any existing records in the value table.
 *       - Update structure.
 *       - Remove records from the value table.
 *
 * 3. Apply buffer changes. We only do this after the mirror has advanced; if we fail to
 *    clean up the buffer, it'll reconcile neatly with the mirror on a subsequent try.
 *
 * 4. Update bookkeeping timestamps. If this fails we will download uploaded records,
 *    find they match, and have no repeat merging work to do.
 *
 * The goal of merging is that the buffer is empty (because we reconciled conflicts and
 * updated the server), our local overlay is empty (because we reconciled conflicts and
 * applied our changes to the server), and the mirror matches the server.
 *
 * Note that upstream application is robust: we can use XIUS to ensure that writes don't
 * race. Buffer application is similarly robust, because this code owns all writes to the
 * buffer. Local and mirror application, however, is not: the user's actions can cause
 * changes to write to the database before we're done applying the results of a sync.
 * We mitigate this a little by being explicit about the local changes that we're flushing
 * (rather than, say, `DELETE FROM local`), but to do better we'd need change detection
 * (e.g., an in-memory monotonic counter) or locking to prevent bookmark operations from
 * racing. Later!
 */
protocol BookmarksStorageMerger {
    init(buffer: BookmarkBufferStorage, storage: SyncableBookmarks)
    func merge() -> Deferred<Maybe<BookmarksMergeResult>>
}

// MARK: - No-op implementations of each protocol.

typealias UploadResult = (succeeded: [GUID: Timestamp], failed: Set<GUID>)

class NoOpBookmarksMerger: BookmarksStorageMerger {
    let buffer: BookmarkBufferStorage
    let storage: SyncableBookmarks

    required init(buffer: BookmarkBufferStorage, storage: SyncableBookmarks) {
        self.buffer = buffer
        self.storage = storage
    }

    func merge() -> Deferred<Maybe<BookmarksMergeResult>> {
        return deferMaybe(BookmarksMergeResult.NoOp)
    }
}

class UpstreamCompletionNoOp: UpstreamCompletionOp {
    var isNoOp: Bool {
        return true
    }

    func describe(log: DescriptionDestination) {
        log.write("No upstream operation.")
    }

    func applyToClient(client: Sync15CollectionClient<BookmarkBasePayload>) -> Deferred<Maybe<UploadResult>> {
        return deferMaybe((succeeded: [:], failed: Set<GUID>()))
    }
}

class LocalOverrideCompletionNoOp: LocalOverrideCompletionOp {
    var isNoOp: Bool {
        return true
    }

    func describe(log: DescriptionDestination) {
        log.write("No local override operation.")
    }

    func applyToStore(storage: SyncableBookmarks, withUpstreamResult upstream: UploadResult) -> Success {
        return succeed()
    }
}

class BufferCompletionNoOp: BufferCompletionOp {
    var isNoOp: Bool {
        return true
    }

    func describe(log: DescriptionDestination) {
        log.write("No buffer operation.")
    }

    func applyToBuffer(buffer: BookmarkBufferStorage) -> Success {
        return succeed()
    }
}

public class BookmarksMergeError: MaybeErrorType, ErrorType {
    public var description: String {
        return "Merge error"
    }
}

public class BookmarksMergeConsistencyError: BookmarksMergeError {
    override public var description: String {
        return "Merge consistency error"
    }
}

public class BookmarksMergeErrorTreeIsUnrooted: BookmarksMergeConsistencyError {
    public let roots: Set<GUID>

    public init(roots: Set<GUID>) {
        self.roots = roots
    }

    override public var description: String {
        return "Tree is unrooted: roots are \(self.roots)"
    }
}

// MARK: - Real implementations of each protocol.

/** This class takes as input three 'trees'.
  *
  * The mirror is always complete, never contains deletions, never has
  * orphans, and has a single root.
  *
  * Each of local and buffer can contain a number of subtrees (each of which must
  * be a folder or root), a number of deleted GUIDs, and a number of orphans (records
  * with no known parent).
  *
  * It's very likely that there's almost no overlap, and thus no real conflicts to
  * resolve -- a three-way merge isn't always a bad thing -- but we won't know until
  * we compare records.
  *
  * Even though this is called 'three way merge', it also handles the case
  * of a two-way merge (one without a shared parent; for the roots, this will only
  * be on a first sync): content-based and structural merging is needed at all
  * layers of the hierarchy, so we simply generalize that to also apply to roots.
  *
  * In a sense, a two-way merge is solved by constructing a shared parent consisting of
  * roots, which are implicitly shared.
  * (Special care must be taken to not deduce that one side has deleted a root, of course,
  * as would be the case of a Sync server that doesn't contain
  * a Mobile Bookmarks folder -- the set of roots can only grow, not shrink.)
  */
class ThreeWayTreeMerger {
    let local: BookmarkTree
    let mirror: BookmarkTree
    let remote: BookmarkTree

    // Sets computed by looking at the three trees. These are used for diagnostics,
    // to simplify operations, and for testing.
    let mirrorAllGUIDs: Set<GUID>
    let localAllGUIDs: Set<GUID>
    let remoteAllGUIDs: Set<GUID>
    let localAdditions: Set<GUID>
    let remoteAdditions: Set<GUID>
    let allGUIDs: Set<GUID>
    let conflictingGUIDs: Set<GUID>

    // Work queues. Trees are walked and additional work pushed here.
    // This allows us to prepare non-structural work while we're walking
    // the trees, to avoid re-processing complementary nodes, and of
    // course to flatten a recursive tree walk into iteration.
    var conflictValueQueue: [GUID] = []
    var remoteValueQueue: [GUID] = []                 // Need value reconciling.
    var remoteQueue: [BookmarkTreeNode] = []          // Structure to walk.

    init(local: BookmarkTree, mirror: BookmarkTree, remote: BookmarkTree) {
        self.local = local
        self.mirror = mirror
        self.remote = remote

        self.mirrorAllGUIDs = Set<GUID>(self.mirror.lookup.keys)
        self.localAllGUIDs = Set<GUID>(self.local.lookup.keys)
        self.remoteAllGUIDs = Set<GUID>(self.remote.lookup.keys)
        self.localAdditions = localAllGUIDs.subtract(mirrorAllGUIDs)
        self.remoteAdditions = remoteAllGUIDs.subtract(mirrorAllGUIDs)
        self.allGUIDs = localAllGUIDs.union(remoteAllGUIDs)
        self.conflictingGUIDs = localAllGUIDs.intersect(remoteAllGUIDs)
    }

    func processRemoteNode(node: BookmarkTreeNode) throws {
        switch node {
        case let .Folder(guid, remoteChildren):
            // Folder: children changed and/or the folder's value changed.
            try self.processRemoteFolderWithGUID(guid, children: remoteChildren)
        case let .NonFolder(guid):
            // Value change or parent change.
            remoteValueQueue.append(guid)
        case .Unknown:
            // Placeholder. Nothing to do: it hasn't changed.
            // We should never get here.
            log.warning("Structurally processing an Unknown buffer node. We should never get here!")
            break
        }
    }

    func processRemoteFolderWithGUID(guid: GUID, children: [BookmarkTreeNode]) throws {
        // Find the mirror node from which we descend, and find any corresponding local change.
        // Search by GUID only, because (a) the mirror is a GUID match by definition, and (b)
        // we only do content-based matches for nodes where we categorically know their parent
        // folder, and when the node is new (i.e., no mirror match), so we do it when processing a folder.
        if let mirrored = self.mirror.find(guid) {
            // This is a change from a known mirror node.
            guard case let .Folder(_, originalChildren) = mirrored else {
                // It's not a folder! Uh oh!
                log.error("Unable to process change of \(guid) from non-folder to folder.")
                throw BookmarksMergeConsistencyError()
            }
            try self.processKnownRemoteFolderWithGUID(guid, children: children, originalChildren: originalChildren)
        } else {
            // No mirror node. It must be a remote addition.
            try self.processPotentiallyNewRemoteFolderWithGUID(guid, children: children)
        }
    }

    func processPotentiallyNewRemoteFolderWithGUID(guid: GUID, children: [BookmarkTreeNode]) throws {
        // Check for a local counterpart. If none exists, create this folder. If one does exist,
        // do a two-way merge.
        // Doing this work involves value-processing the incoming record, and all of its
        // children, before doing the structure insert. So it's a good job we queue up
        // all of these work items and run the insertion value changes first, isn't it?
        //
        // Note that it's theoretically possible for two remote folders to match against a
        // local folder -- e.g., add two child folders named "AAA" to a folder that locally
        // already contains "AAA". We must ensure that one or none of the remote records
        // matches, not both.
    }


    func enqueueRemoteChildrenForProcessing(children: [BookmarkTreeNode]) {
        // Recursively enqueue the children for processing.
        children.forEach { child in
            switch child {
            case let .Folder(childGUID, _):
                // Depth-first.
                log.debug("Queueing child \(childGUID) for structural and value changes.")
                remoteQueue.append(child)
                remoteValueQueue.append(childGUID)
            case let .NonFolder(childGUID):
                log.debug("Queueing child \(childGUID) for value-only change.")
                remoteValueQueue.append(childGUID)
            case let .Unknown(childGUID):
                log.debug("Child \(childGUID) didn't change. Descending no further.")
            }
        }
    }

    func processKnownChangedRemoteFolderWithGUID(guid: GUID, children: [BookmarkTreeNode], originalChildren: [BookmarkTreeNode]) throws {
            // TODO: for each child, check whether it's an addition, removal, rearrangement, or move.
            // Look in other trees to check for the other part of these operations.
            // Mark those nodes as done so we don't process moves etc. more than once.
    }

    // Only call this if you know the lists differ.
    func processKnownChangedLocalFolderWithGUID(guid: GUID, originalChildren: [BookmarkTreeNode], localChildren: [BookmarkTreeNode]) throws {

    }

    /**
     * This handles the case when we're processing an incoming folder that supersedes
     * an existing mirror folder.
     */
    func processKnownRemoteFolderWithGUID(guid: GUID, children: [BookmarkTreeNode], originalChildren: [BookmarkTreeNode]) throws {
        if let counterpart = self.local.find(guid) {
            // Also locally changed. Resolve the conflict.
            guard case let .Folder(_, localChildren) = counterpart else {
                log.error("Local record \(guid) changed the type of a mirror node!")
                throw BookmarksMergeConsistencyError()
            }
            try self.processPotentiallyConflictingKnownRemoteFolderWithGUID(guid, remoteChildren: children, originalChildren: originalChildren, localChildren: localChildren)
            return
        }

        // Not locally changed. But the children might have been modified or deleted, so
        // we can't unilaterally apply the incoming record.
        // Make sure that the records in our child list still exist, and that our child
        // list doesn't create orphans.
        // Also track this folder to check for value changes.
        remoteValueQueue.append(guid)

        self.enqueueRemoteChildrenForProcessing(children)

        let remoteChildGUIDs = children.map { $0.recordGUID }
        let originalChildGUIDs = originalChildren.map { $0.recordGUID }
        if remoteChildGUIDs == originalChildGUIDs {
            // Great, the child list didn't change. Must've just changed this folder's values.
            log.debug("Remote child list hasn't changed from the mirror.")
        } else {
            log.debug("Remote child list changed children. Was: \(originalChildGUIDs). Now: \(remoteChildGUIDs).")
            try self.processKnownChangedRemoteFolderWithGUID(guid, children: children, originalChildren: originalChildren)
        }
    }

    func processKnownLocalFolderWithGUID(guid: GUID, originalChildren: [BookmarkTreeNode], localChildren: [BookmarkTreeNode]) throws {
        // TODO
    }

    /**
     * This handles the case where we have both local and remote folder entries that supersede
     * a mirror folder.
     */
    func processPotentiallyConflictingKnownRemoteFolderWithGUID(guid: GUID, remoteChildren: [BookmarkTreeNode], originalChildren: [BookmarkTreeNode], localChildren: [BookmarkTreeNode]) throws {
        let remoteChildGUIDs = remoteChildren.map { $0.recordGUID }
        let originalChildGUIDs = originalChildren.map { $0.recordGUID }
        let localChildGUIDs = localChildren.map { $0.recordGUID }

        let remoteUnchanged = (remoteChildGUIDs == originalChildGUIDs)
        let localUnchanged = (localChildGUIDs == originalChildGUIDs)

        if remoteUnchanged {
            if localUnchanged {
                // Neither side changed structure, so this must be a value-only change on both sides.
                log.debug("Value-only local-remote conflict for \(guid).")
                conflictValueQueue.append(guid)
            } else {
                // This folder changed locally.
                log.debug("Remote folder didn't change structure, but collides with a local structural change.")
                log.debug("Local child list changed children. Was: \(originalChildGUIDs). Now: \(localChildGUIDs).")

                // Track the folder to check for value changes.
                remoteValueQueue.append(guid)

                // TODO: for each child, check whether it's an addition, removal, rearrangement, or move.
                // Look in other trees to check for the other part of these operations.
                // Mark those nodes as done so we don't process moves etc. more than once.
            }
        } else {
            // Remote changed structure.

            // Track the folder to check for value changes.
            remoteValueQueue.append(guid)

            if localUnchanged {
                log.debug("Remote folder changed structure for \(guid).")
                try self.processKnownChangedRemoteFolderWithGUID(guid, children: remoteChildren, originalChildren: originalChildren)
            } else {
                log.debug("Structural conflict for \(guid).")
                // TODO: reconcile.
            }
        }
    }

    func merge() -> Deferred<Maybe<BookmarksMergeResult>> {
        // To begin with we structurally reconcile. If necessary we will lazily fetch the
        // attributes of records in order to do a content-based reconciliation. Once we've
        // matched up any records that match (including remapping local GUIDs), we're able to
        // process _content_ changes, which is much simpler.
        //
        // We have to handle an arbitrary combination of the following structural operations:
        //
        // * Creating a folder.
        //   Created folders might now hold existing items, new items, or nothing at all.
        // * Creating a bookmark.
        //   It might be in a new folder or an existing folder.
        // * Moving one or more leaf records to an existing or new folder.
        // * Reordering the children of a folder.
        // * Deleting an entire subtree.
        // * Deleting an entire subtree apart from some moved nodes.
        // * Deleting a leaf node.
        // * Transplanting a subtree: moving a folder but not changing its children.
        //
        // And, of course, the non-structural operations such as renaming or changing URLs.
        //
        // We ignore all changes to roots themselves; the only acceptable operation on a root
        // is to change its children. The Places root is entirely immutable.
        //
        // Steps:
        // * Construct a collection of subtrees for local and buffer, and a complete tree for the mirror.
        //   The more thorough this step, the more confidence we have in consistency.
        // * Fetch all local and remote deletions. These won't be included in structure (for obvious
        //   reasons); we hold on to them explicitly so we can spot the difference between a move
        //   and a deletion.
        // * If every GUID on each side is present in the mirror, we have no new records.
        // * If a non-root GUID is present on both sides but not in the mirror, then either
        //   we're re-syncing from scratch, or (unlikely) we have a random collision.
        // * Otherwise, we have a GUID that we don't recognize. We will structure+content reconcile
        //   this later -- we first make sure we have handled any tree moves, so that the addition
        //   of a bookmark to a moved folder on A, and the addition of the same bookmark to the non-
        //   moved version of the folder, will collide successfully.
        //
        // * Walk each subtree, top-down. At each point if there are two back-pointers to
        //   the mirror node for a GUID, we have a potential conflict, and we have all three
        //   parts that we need to resolve it via a content-based or structure-based 3WM.

        // When we look at a child list:
        // * It's the same. Great! Keep walking down.
        // * There are added GUIDs.
        //   * An added GUID might be a move from elsewhere. Coordinate with the removal step.
        //   * An added GUID might be a brand new record. If there are local additions too,
        //     check to see if they value-reconcile, and keep the remote GUID.
        // * There are removed GUIDs.
        //   * A removed GUID might have been deleted. Deletions win.
        //   * A missing GUID might be a move -- removed from here and added to another folder.
        //     Process this as a move.
        // * The order has changed.

        // When we get to a subtree that contains no changes, we can never hit conflicts, and
        // application becomes easier.
        // When we run out of subtrees on both sides, we're done.
        //
        // Match, no conflict? Apply.
        // Match, conflict? Resolve. Might involve moves from other matches!
        // No match in the mirror? Check for content match with the same parent, any position.
        // Still no match? Add.

        // Both local and remote should reach a single root when overlayed. If not, it means that
        // the tree is inconsistent -- there isn't a full tree present either on the server (or local)
        // or in the mirror, or the changes aren't congruent in some way. If we reach this state, we
        // cannot proceed.
        if !self.local.isFullyRootedIn(self.mirror) {
            log.warning("Local bookmarks not fully rooted when overlayed on mirror. This is most unusual.")
            return deferMaybe(BookmarksMergeErrorTreeIsUnrooted(roots: self.local.subtreeGUIDs))
        }

        if !self.remote.isFullyRootedIn(mirror) {
            log.warning("Remote bookmarks not fully rooted when overlayed on mirror. Partial read or write in buffer?")

            // TODO: request recovery.
            return deferMaybe(BookmarksMergeErrorTreeIsUnrooted(roots: self.remote.subtreeGUIDs))
        }

        log.debug("Processing \(self.localAllGUIDs.count) local changes and \(self.remoteAllGUIDs.count) remote.")
        log.debug("\(self.local.subtrees.count) local subtrees and \(self.remote.subtrees.count) subtrees.")
        log.debug("Local is adding \(self.localAdditions.count) records, and remote is adding \(self.remoteAdditions.count).")

        if !conflictingGUIDs.isEmpty {
            log.warning("Expecting conflicts between local and remote: \(conflictingGUIDs.joinWithSeparator(", ")).")
        }

        // Process incoming subtrees first.
        // Skip the root; we never move roots, nor change its name. Sync shouldn't sync
        // the Places root, but if it does, we won't screw up.
        self.remote.subtrees.forEach { subtree in
            if subtree.recordGUID == BookmarkRoots.RootGUID {
                if case let .Folder(_, roots) = subtree {
                    self.remoteQueue.appendContentsOf(roots.reverse())
                } else {
                    log.error("Root wasn't a folder!")
                }
            } else {
                self.remoteQueue.append(subtree)
            }
        }

        do {
            repeat {} while try self.step()
        } catch {
            log.warning("Caught error \(error) while processing queue. \(self.remoteQueue.count) remaining items.")
            return deferMaybe(error as? MaybeErrorType ?? BookmarksMergeError())
        }

        // TODO: process local subtrees, skipping nodes that were already picked up and processed while
        // walking the buffer.

        return deferMaybe(BookmarksMergeResult.NoOp)
    }

    /**
     * Returns true if work was done.
     */
    func step() throws -> Bool {
        guard let item = self.remoteQueue.popLast() else {
            log.debug("No more items.")
            return false
        }
        try self.processRemoteNode(item)
        return true
    }
}

class ThreeWayBookmarksStorageMerger: BookmarksStorageMerger {
    let buffer: BookmarkBufferStorage
    let storage: SyncableBookmarks

    required init(buffer: BookmarkBufferStorage, storage: SyncableBookmarks) {
        self.buffer = buffer
        self.storage = storage
    }

    // Trivial one-way sync.
    private func applyLocalDirectlyToMirror() -> Deferred<Maybe<BookmarksMergeResult>> {
        // Theoretically, we do the following:
        // * Construct a virtual bookmark tree overlaying local on the mirror.
        // * Walk the tree to produce Sync records.
        // * Upload those records.
        // * Flatten that tree into the mirror, clearing local.
        //
        // This is simpler than a full three-way merge: it's tree delta then flatten.
        //
        // But we are confident that our local changes, when overlaid on the mirror, are
        // consistent. So we can take a little bit of a shortcut: process records
        // directly, rather than building a tree.
        //
        // So do the following:
        // * Take everything in `local` and turn it into a Sync record. This means pulling
        //   folder hierarchies out of localStructure, values out of local, and turning
        //   them into records. Do so in hierarchical order if we can, and set sortindex
        //   attributes to put folders first.
        // * Upload those records in as many batches as necessary. Ensure that each batch
        //   is consistent, if at all possible.
        // * Take everything in local that was successfully uploaded and move it into the
        //   mirror, using the timestamps we tracked from the upload.
        //
        // Optionally, set 'again' to true in our response, and do this work only for a
        // particular subtree (e.g., a single root, or a single branch of changes). This
        // allows us to make incremental progress.

        // TODO
        log.debug("No special-case local-only merging yet. Falling back to three-way merge.")
        return self.threeWayMerge()
    }

    private func applyIncomingDirectlyToMirror() -> Deferred<Maybe<BookmarksMergeResult>> {
        // If the incoming buffer is consistent -- and the result of the mirrorer
        // gives us a hint about that! -- then we can move the buffer records into
        // the mirror directly.
        //
        // Note that this is also true for entire subtrees: if none of the children
        // of, say, 'menu________' are modified locally, then we can apply it without
        // merging.
        //
        // TODO
        log.debug("No special-case remote-only merging yet. Falling back to three-way merge.")
        return self.threeWayMerge()
    }

    private func threeWayMerge() -> Deferred<Maybe<BookmarksMergeResult>> {
        return self.storage.treesForEdges() >>== { (local, buffer) in
            if local.isEmpty && buffer.isEmpty {
                // We should never have been called!
                return deferMaybe(BookmarksMergeResult.NoOp)
            }

            // Find the mirror tree so we can compare.
            return self.storage.treeForMirror() >>== { mirror in
                // At this point we know that there have been changes both locally and remotely.
                // (Or, in the general case, changes either locally or remotely.)
                let merger = ThreeWayTreeMerger(local: local, mirror: mirror, remote: buffer)
                return merger.merge()
            }
        }
    }

    func merge() -> Deferred<Maybe<BookmarksMergeResult>> {
        return self.buffer.isEmpty() >>== { noIncoming in

            // TODO: the presence of empty desktop roots in local storage
            // isn't something we really need to worry about. Can we skip it here?

            return self.storage.isUnchanged() >>== { noOutgoing in
                switch (noIncoming, noOutgoing) {
                case (true, true):
                    // Nothing to do!
                    return deferMaybe(BookmarksMergeResult.NoOp)
                case (true, false):
                    // No incoming records to apply. Unilaterally apply local changes.
                    return self.applyLocalDirectlyToMirror()
                case (false, true):
                    // No outgoing changes. Unilaterally apply remote changes if they're consistent.
                    return self.buffer.validate() >>> self.applyIncomingDirectlyToMirror
                default:
                    // Changes on both sides. Merge.
                    return self.buffer.validate() >>> self.threeWayMerge
                }
            }
        }
    }
}