import XCTest
@testable import NanopicCore
final class SmokeTests: XCTestCase { func testSmoke() { XCTAssertEqual(IntRect(x:0,y:0,width:10,height:10).area, 100) } }
