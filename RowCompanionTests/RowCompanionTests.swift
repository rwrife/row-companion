import XCTest
@testable import RowCompanion

final class RowCompanionTests: XCTestCase {
    @MainActor
    func testRootViewConstructsWithoutExternalDependencies() {
        _ = ContentView()
    }
}
