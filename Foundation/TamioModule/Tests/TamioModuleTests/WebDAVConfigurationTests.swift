//
//  WebDAVConfigurationTests.swift
//  TamioModuleTests
//
//  Where Tamio will send the sealed sync document, and where it will not.
//

@testable import TamioModule
import XCTest

final class WebDAVConfigurationTests: XCTestCase {
    private func configuration(
        _ address: String, username: String = "tamio", password: String = "secret"
    ) -> WebDAVConfiguration {
        WebDAVConfiguration(url: URL(string: address)!, username: username, password: password)
    }

    func testAnHTTPSFileIsFine() {
        XCTAssertNil(configuration("https://dav.example.com/tamio/sync.bin").problem)
    }

    func testPlainHTTPIsRefusedAwayFromTheLocalNetwork() {
        XCTAssertNotNil(configuration("http://dav.example.com/tamio/sync.bin").problem)
        XCTAssertNil(configuration("http://localhost:8080/tamio/sync.bin").problem)
        XCTAssertNil(configuration("http://127.0.0.1:8080/tamio/sync.bin").problem)
        XCTAssertNil(configuration("http://nas.local/tamio/sync.bin").problem)
        XCTAssertNil(configuration("http://192.168.1.20:5005/tamio/sync.bin").problem)
        XCTAssertNil(configuration("http://10.0.0.4/tamio/sync.bin").problem)
    }

    func testAFolderIsNotAFile() {
        XCTAssertNotNil(configuration("https://dav.example.com/tamio/").problem)
    }

    func testCredentialsBelongInTheirFields() {
        XCTAssertNotNil(configuration("https://user:secret@dav.example.com/tamio/sync.bin").problem)
    }

    func testHalfTheCredentialsIsRefused() {
        XCTAssertNotNil(configuration("https://dav.example.com/tamio/sync.bin", username: "tamio", password: "").problem)
        XCTAssertNotNil(configuration("https://dav.example.com/tamio/sync.bin", username: "", password: "secret").problem)
        XCTAssertNil(configuration("https://dav.example.com/tamio/sync.bin", username: "", password: "").problem)
    }
}
