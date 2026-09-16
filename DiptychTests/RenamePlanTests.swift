import XCTest
@testable import Diptych

/// Working out a folder's worth of renames before touching anything.
final class RenamePlanTests: XCTestCase {

    private func plan(_ names: [String], _ search: String, _ replacement: String) throws
        -> RenamePlan {
        let regex = try NSRegularExpression(pattern: search)
        return RenamePlan.plan(names: names, search: search.isEmpty ? regex : regex,
                               replacement: replacement)
    }

    // MARK: - Matching and replacing

    func testTheSearchMustMatchTheWholeName() throws {
        let made = try plan(["notes.txt", "my notes.txt"], "notes\\.txt", "minutes.txt")

        XCTAssertEqual(made.matched, 1, "\u{201C}my notes.txt\u{201D} is not matched in part")
        XCTAssertEqual(made.steps, [.init(from: "notes.txt", to: "minutes.txt")])
    }

    func testCapturingGroupsAreAvailableInTheReplacement() throws {
        let made = try plan(["2024-03-12 invoice.pdf", "2024-04-01 invoice.pdf"],
                            #"(\d{4})-(\d{2})-(\d{2}) invoice\.pdf"#,
                            "Invoice $1$2$3.pdf")

        XCTAssertEqual(made.steps.map(\.to), ["Invoice 20240312.pdf", "Invoice 20240401.pdf"])
    }

    func testAFileWhoseNameDoesNotChangeIsNotRenamed() throws {
        let made = try plan(["a.txt", "b.txt"], "(.*)", "$1")

        XCTAssertEqual(made.matched, 2)
        XCTAssertEqual(made.unchanged, 2)
        XCTAssertTrue(made.isEmpty)
    }

    func testANameTheFileSystemWouldRefuseIsAProblem() throws {
        let made = try plan(["a.txt"], "(.*)\\.txt", "sub/$1.txt")

        XCTAssertEqual(made.problems.count, 1)
        XCTAssertTrue(made.problems[0].contains("cannot be a file name"))
        XCTAssertTrue(made.isEmpty, "nothing runs while there is a problem")
    }

    func testAnEmptyReplacementIsRefused() throws {
        let made = try plan(["a.txt"], ".*", "")
        XCTAssertEqual(made.problems.count, 1)
    }

    // MARK: - Collisions

    func testTwoFilesWantingOneNameIsRefused() throws {
        let made = try plan(["one.txt", "two.txt"], "(one|two)\\.txt", "same.txt")

        XCTAssertEqual(made.problems.count, 1)
        XCTAssertTrue(made.problems[0].contains("would both be called"))
        XCTAssertTrue(made.isEmpty)
    }

    func testTwoNamesThatDifferOnlyInCaseAlsoCollide() throws {
        // This disk does not tell Notes from notes.
        let made = try plan(["one.txt", "two.txt"], "one\\.txt|two\\.txt", "Same.txt")
        XCTAssertFalse(made.problems.isEmpty)

        let harder = try plan(["a", "b"], "a", "B")
        XCTAssertTrue(harder.problems.contains { $0.contains("already here") }, "\(harder)")
    }

    func testTakingTheNameOfAFileThatStaysPutIsRefused() throws {
        let made = try plan(["draft.txt", "final.txt"], "draft\\.txt", "final.txt")

        XCTAssertEqual(made.problems.count, 1)
        XCTAssertTrue(made.problems[0].contains("is not being renamed"))
    }

    func testRenamingOnlyTheLettersOfItsOwnNameIsFine() throws {
        let made = try plan(["notes.txt"], "notes\\.txt", "Notes.txt")

        XCTAssertTrue(made.problems.isEmpty, "\(made.problems)")
        XCTAssertEqual(made.steps, [.init(from: "notes.txt", to: "Notes.txt")])
    }

    // MARK: - Order

    func testAChainIsOrderedSoTheNameIsFreeWhenItIsNeeded() throws {
        // A -> B while B -> C: B has to move first.
        let ordered = try planPairs([("A", "B"), ("B", "C")])

        XCTAssertEqual(ordered.steps, [.init(from: "B", to: "C"), .init(from: "A", to: "B")])
        XCTAssertTrue(ordered.problems.isEmpty)
    }

    func testARealChainThroughOneSearchAndReplacement() throws {
        // The window's way in: one regex over the whole folder. Numbering
        // files up by one is the everyday chain.
        let made = try plan(["2.txt", "3.txt"], #"(\d)\.txt"#, "$1x.txt")

        XCTAssertEqual(made.steps.map(\.to), ["2x.txt", "3x.txt"])
        XCTAssertTrue(made.problems.isEmpty)
    }

    func testALongerChainIsOrderedFromTheEnd() throws {
        let ordered = try planPairs([("a", "b"), ("b", "c"), ("c", "d")])

        XCTAssertEqual(ordered.steps.map(\.from), ["c", "b", "a"])
        XCTAssertTrue(ordered.problems.isEmpty)
    }

    func testASwapStepsAsideAndComesBack() throws {
        let ordered = try planPairs([("A", "B"), ("B", "A")])

        XCTAssertEqual(ordered.steps.count, 3, "\(ordered.steps)")
        XCTAssertTrue(ordered.steps[0].isTemporary)
        XCTAssertTrue(ordered.steps[0].to.hasPrefix(RenamePlan.temporaryPrefix))
        XCTAssertEqual(ordered.steps[1], .init(from: "B", to: "A"))
        XCTAssertEqual(ordered.steps[2].from, ordered.steps[0].to)
        XCTAssertEqual(ordered.steps[2].to, "B")
        XCTAssertEqual(ordered.renames, 2, "two files are renamed, by three steps")
    }

    func testAThreeWayCycleIsAlsoHandled() throws {
        let ordered = try planPairs([("a", "b"), ("b", "c"), ("c", "a")])

        XCTAssertTrue(ordered.problems.isEmpty)
        // Every name each step wants is free by the time the step runs.
        var present = Set(["a", "b", "c"])
        for step in ordered.steps {
            XCTAssertTrue(present.contains(step.from), "\(step.from) is there: \(ordered.steps)")
            XCTAssertFalse(present.contains(step.to), "\(step.to) is free: \(ordered.steps)")
            present.remove(step.from)
            present.insert(step.to)
        }
        XCTAssertEqual(present, Set(["a", "b", "c"]))
    }

    func testEveryStepOfAMixedFolderRunsOnAFreeName() throws {
        let ordered = try planPairs([("one", "two"), ("two", "three"), ("x", "y"),
                                     ("p", "q"), ("q", "p")])

        XCTAssertTrue(ordered.problems.isEmpty, "\(ordered.problems)")
        var present = Set(["one", "two", "x", "p", "q"])
        for step in ordered.steps {
            XCTAssertTrue(present.contains(step.from), "\(step.from): \(ordered.steps)")
            XCTAssertFalse(present.contains(step.to), "\(step.to): \(ordered.steps)")
            present.remove(step.from)
            present.insert(step.to)
        }
        XCTAssertEqual(present, Set(["two", "three", "y", "p", "q"]),
                       "one became two, two became three, and p and q swapped")
    }

    /// A plan for exactly these renames. One regex cannot express an arbitrary
    /// table of names, and it is the ordering that is under test here, so the
    /// pairs go straight to the two pieces that do that work.
    private func planPairs(_ pairs: [(String, String)]) throws -> RenamePlan {
        let listed = pairs.map { (from: $0.0, to: $0.1) }
        var made = RenamePlan()
        made.matched = pairs.count
        made.problems = RenamePlan.clashes(listed, among: pairs.map(\.0).sorted())
        if made.problems.isEmpty { made.steps = RenamePlan.order(listed) }
        return made
    }
}
