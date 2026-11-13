//
//  WebDAVClientTests.swift
//  TamioModuleTests
//
//  What the WebDAV client sends, and how it reads what comes back.
//

import Foundation
@testable import TamioModule
import XCTest

final class WebDAVClientTests: XCTestCase {
    private let configuration = WebDAVConfiguration(
        url: URL(string: "https://dav.example.com/tamio/sync.bin")!,
        username: "tamio",
        password: "secret"
    )

    private final class Mock: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data?))?
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with _: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.requests.append(request)
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: WebDAVError.status(0))
                return
            }
            let (code, data) = handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private var client: WebDAVClient!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        Mock.requests = []
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [Mock.self]
        session = URLSession(configuration: sessionConfiguration)
        client = WebDAVClient(configuration: configuration, session: session)
    }

    override func tearDown() {
        Mock.handler = nil
        session.invalidateAndCancel()
        super.tearDown()
    }

    func testReadSendsBasicAuthorizationAndReturnsTheFile() async throws {
        Mock.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Basic \(Data("tamio:secret".utf8).base64EncodedString())"
            )
            return (200, Data("sealed".utf8))
        }
        let data = try await client.read()
        XCTAssertEqual(data, Data("sealed".utf8))
    }

    func testReadTreats404AsNoFile() async throws {
        Mock.handler = { _ in (404, nil) }
        let data = try await client.read()
        XCTAssertNil(data)
    }

    func testUnauthorizedIsReported() async {
        Mock.handler = { _ in (401, nil) }
        do {
            _ = try await client.read()
            XCTFail("a refused password is not an empty file")
        } catch {
            XCTAssertEqual(error as? WebDAVError, .unauthorized)
        }
    }

    func testWriteCreatesTheFolderAndUploads() async throws {
        Mock.handler = { request in
            switch request.httpMethod {
            case "PUT" where Mock.requests.filter { $0.httpMethod == "PUT" }.count == 1:
                return (409, nil)
            case "MKCOL":
                XCTAssertTrue(request.url!.absoluteString.hasSuffix("/"))
                return (201, nil)
            case "PUT":
                return (201, nil)
            default:
                return (500, nil)
            }
        }
        try await client.write(Data("sealed".utf8))
        XCTAssertEqual(Mock.requests.map(\.httpMethod), ["PUT", "MKCOL", "PUT"])
    }

    func testDeleteTreatsAMissingFileAsDone() async throws {
        Mock.handler = { _ in (404, nil) }
        try await client.write(nil)
        XCTAssertEqual(Mock.requests.map(\.httpMethod), ["DELETE"])
    }

    func testTheUserAgentIsSentWhenSet() async throws {
        Mock.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Zotero/10.0.0")
            return (404, nil)
        }
        let configuration = try WebDAVConfiguration(
            url: XCTUnwrap(URL(string: "https://dav.example.com/tamio/sync.bin")),
            username: "tamio",
            password: "secret",
            userAgent: "Zotero/10.0.0"
        )
        let client = WebDAVClient(configuration: configuration, session: session)
        _ = try await client.read()
    }
}
