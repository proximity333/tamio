//
//  WebDAVClient.swift
//  TamioModule
//
//  The one file on the user's WebDAV server that holds the sealed sync
//  document. It is read and written with plain HTTP: GET, PUT and, for a
//  folder that does not exist yet, MKCOL. Only ciphertext leaves the device.
//

import Foundation

/// Where the sealed document lives, and who may read it.
struct WebDAVConfiguration: Equatable, Sendable {
    var url: URL
    var username: String
    var password: String

    /// Why this cannot be used, in a sentence; nil when it can.
    var problem: String? {
        guard let host = url.host, !host.isEmpty else {
            return String(localized: "Enter the address of the file on your WebDAV server.")
        }
        if url.user != nil || url.password != nil {
            return String(localized: "Enter the user name and password in their own fields, not in the address.")
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return String(localized: "The address must begin with https://.")
        }
        if scheme == "http", !Self.isLocal(host) {
            return String(localized: "WebDAV needs an https:// address, so the password is not sent in the clear.")
        }
        if url.lastPathComponent.isEmpty || url.absoluteString.hasSuffix("/") {
            return String(localized: "Enter the file's address, not its folder's.")
        }
        if username.isEmpty != password.isEmpty {
            return String(localized: "Enter both your WebDAV user name and password, or neither.")
        }
        return nil
    }

    /// A server on this Mac, or on the local network, may be plain HTTP.
    private static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" {
            return true
        }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") {
            return true
        }
        if host.hasPrefix("fe80:") || host.hasPrefix("fd") || host.hasPrefix("fc") {
            return true
        }
        return isPrivateIPv4(host)
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ Int($0).map { 0 ... 255 ~= $0 } ?? false }),
              let first = Int(parts[0]), let second = Int(parts[1])
        else { return false }
        return first == 10 || first == 127 || (first == 169 && second == 254)
            || (first == 192 && second == 168)
            || (first == 172 && (16 ... 31).contains(second))
    }
}

enum WebDAVError: LocalizedError, Equatable {
    case unauthorized
    case forbidden
    case redirected
    case missingFolder
    case status(Int)
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: String(localized: "The server refused the user name or password.")
        case .forbidden: String(localized: "The server refused access to this file.")
        case .redirected: String(localized: "The server redirected to another address. Enter the file's final address.")
        case .missingFolder: String(localized: "The file's folder does not exist. Create it on the server, or enter the file's full address.")
        case let .status(code): String(localized: "The server answered with status \(code).")
        case let .connection(reason): String(localized: "Could not reach the server: \(reason)")
        }
    }
}

struct WebDAVClient {
    let configuration: WebDAVConfiguration
    private let session: URLSession

    init(configuration: WebDAVConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? Self.sharedSession
    }

    /// iCloud's key-value store is small; a WebDAV server is not, but a
    /// document that grew past this is more likely a wrong address.
    private static let limit = 20_000_000

    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// The file's bytes, or nil when the server does not have it yet.
    func read() async throws -> Data? {
        let (data, response) = try await perform(request("GET"))
        switch response.statusCode {
        case 200 ... 299:
            guard data.count <= Self.limit else {
                throw WebDAVError.connection(String(localized: "The file is larger than Tamio will read."))
            }
            return data
        case 404:
            return nil
        case 401:
            throw WebDAVError.unauthorized
        case 403:
            throw WebDAVError.forbidden
        case 300 ... 399:
            throw WebDAVError.redirected
        default:
            throw WebDAVError.status(response.statusCode)
        }
    }

    /// Replaces the file, or removes it when `data` is nil.
    func write(_ data: Data?) async throws {
        guard let data else {
            try await delete()
            return
        }
        var put = request("PUT")
        put.httpBody = data
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        var (_, response) = try await perform(put)
        if response.statusCode == 404 || response.statusCode == 409 {
            // The usual first-run state: the folder is not there yet.
            try await createParentFolder()
            (_, response) = try await perform(put)
        }
        switch response.statusCode {
        case 200 ... 299: return
        case 401: throw WebDAVError.unauthorized
        case 403: throw WebDAVError.forbidden
        case 300 ... 399: throw WebDAVError.redirected
        default: throw WebDAVError.status(response.statusCode)
        }
    }

    private func delete() async throws {
        let (_, response) = try await perform(request("DELETE"))
        switch response.statusCode {
        case 200 ... 299, 404: return
        case 401: throw WebDAVError.unauthorized
        case 403: throw WebDAVError.forbidden
        case 300 ... 399: throw WebDAVError.redirected
        default: throw WebDAVError.status(response.statusCode)
        }
    }

    private func createParentFolder() async throws {
        let folder = configuration.url.deletingLastPathComponent()
        guard folder.path != "/", !folder.path.isEmpty else { return }
        // A collection's own address ends with a slash; some servers redirect
        // without it, and the client refuses redirects.
        var collection = folder
        if !folder.path.hasSuffix("/"), var parts = URLComponents(url: folder, resolvingAgainstBaseURL: false) {
            parts.path = folder.path + "/"
            collection = parts.url ?? folder
        }
        let (_, response) = try await perform(request("MKCOL", url: collection))
        switch response.statusCode {
        case 200 ... 299, 405: return
        case 401: throw WebDAVError.unauthorized
        case 403: throw WebDAVError.forbidden
        case 300 ... 399: throw WebDAVError.redirected
        case 409, 501: throw WebDAVError.missingFolder
        default: throw WebDAVError.status(response.statusCode)
        }
    }

    private func request(_ method: String, url: URL? = nil) -> URLRequest {
        var request = URLRequest(url: url ?? configuration.url)
        request.httpMethod = method
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if !configuration.username.isEmpty {
            let login = "\(configuration.username):\(configuration.password)"
            request.setValue(
                "Basic \(Data(login.utf8).base64EncodedString())",
                forHTTPHeaderField: "Authorization"
            )
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw WebDAVError.status(0)
            }
            if (300 ... 399).contains(response.statusCode) {
                throw WebDAVError.redirected
            }
            return (data, response)
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.connection(error.localizedDescription)
        }
    }
}

/// A redirect would send the Basic authorization somewhere else. The client
/// reports it instead.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
