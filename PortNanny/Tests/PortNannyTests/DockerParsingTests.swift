import XCTest
@testable import PortNannyCore
@testable import PortNanny

final class DockerParsingTests: XCTestCase {

    func testParsesSingleMapping() {
        let map = DockerService.parsePortMap("0.0.0.0:5432->5432/tcp::my-postgres")
        XCTAssertEqual(map[5432], "my-postgres")
    }

    func testParsesMultipleMappingsPerContainer() {
        let map = DockerService.parsePortMap("0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp::web")
        XCTAssertEqual(map[80], "web")
        XCTAssertEqual(map[443], "web")
    }

    func testParsesIPv6Mapping() {
        let map = DockerService.parsePortMap(":::8080->8080/tcp::api")
        XCTAssertEqual(map[8080], "api")
    }

    /// Compose publishes ranges, and only a single number was read: the
    /// container went unnamed, so `kill` never offered `docker stop`.
    func testParsesAPublishedRange() {
        let map = DockerService.parsePortMap("0.0.0.0:3000-3005->3000-3005/tcp::web")
        XCTAssertEqual(map[3000], "web")
        XCTAssertEqual(map[3003], "web")
        XCTAssertEqual(map[3005], "web")
        XCTAssertNil(map[3006])
    }

    func testARidiculousRangeCannotFillTheMap() {
        let map = DockerService.parsePortMap("0.0.0.0:1-65535->1-65535/tcp::greedy")
        XCTAssertEqual(map.count, 256, "capped")
        XCTAssertEqual(DockerService.publishedPorts("70000-70010"), [], "not ports at all")
        XCTAssertEqual(DockerService.publishedPorts("3005-3000"), [], "backwards")
    }

    func testIgnoresUnpublishedPortsAndGarbage(){
        let map = DockerService.parsePortMap("""
        6379/tcp::redis-no-publish
        garbage line without separator
        """)
        XCTAssertTrue(map.isEmpty)
    }
}
