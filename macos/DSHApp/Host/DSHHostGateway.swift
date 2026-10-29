import Foundation

/// DSH 0.2 Host transport: token handshake, authenticated gateway RPC, and the
/// /api/remote.mux WebSocket carrier for real-time events.
///
/// 0.1.1 spoke dot-named methods (POST api/session.prompt with a bare payload).
/// 0.2 replaced that surface: the launch line carries a one-shot token, the token
/// URL answers 303 and installs a dsh-auth cookie, and every call is a
/// two-segment endpoint whose payload must be exactly {args:{...}}.
/// See .agents/notes/implemented/architecture/2026-08-28-dsh-0.2-protocol-migration.md
struct DSHHostLaunch: Equatable {
  /// Host origin, e.g. http://127.0.0.1:53910, with the token query removed.
  let baseURL: URL
  /// One-shot bootstrap token from the launch line, absent on 0.1.x hosts.
  let token: String?

  /// Parse the "dsh web: <url>" launch line. 0.1.1 prints a bare URL; 0.2
  /// appends ?token=..., so one parser serves both and the caller decides
  /// whether a handshake is required.
  static func parse(launchLine: String) -> DSHHostLaunch? {
    guard let raw = launchLine.split(separator: " ").last,
          let url = URL(string: String(raw)),
          let scheme = url.scheme,
          let host = url.host else { return nil }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = url.port
    guard let baseURL = components.url else { return nil }
    let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first { $0.name == "token" }?
      .value
    return DSHHostLaunch(baseURL: baseURL, token: token?.isEmpty == false ? token : nil)
  }
}

/// One dsh-auth cookie parsed from the handshake response.
struct DSHHostAuthCookie: Equatable {
  let name: String
  let value: String
  var headerValue: String { name + "=" + value }

  static func parse(setCookie: String) -> DSHHostAuthCookie? {
    let parts = setCookie.split(separator: ";", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let pair = parts.first, let equals = pair.firstIndex(of: "=") else { return nil }
    let name = String(pair[pair.startIndex..<equals])
    let value = String(pair[pair.index(after: equals)...])
    guard name.hasPrefix("dsh-auth-"), value.isEmpty == false else { return nil }
    return DSHHostAuthCookie(name: name, value: value)
  }
}

struct DSHHostConnection {
  let launch: DSHHostLaunch
  let cookie: DSHHostAuthCookie
}

/// Performs the 0.2 token-to-cookie exchange once per Host launch.
///
/// GET <launch url with ?token> answers 303 and sets the cookie; following the
/// redirect would land on the static UI without exposing the header we must
/// replay ourselves, so the redirect is deliberately not followed.
enum DSHHostHandshake {
  private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  static func authenticate(launch: DSHHostLaunch) async throws -> DSHHostAuthCookie {
    guard let token = launch.token else { throw URLError(.userAuthenticationRequired) }
    var components = URLComponents(url: launch.baseURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "token", value: token)]
    guard let url = components?.url else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = true
    let delegate = NoRedirectDelegate()
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 303 else {
      throw URLError(.userAuthenticationRequired)
    }
    if let raw = http.value(forHTTPHeaderField: "Set-Cookie"),
       let cookie = DSHHostAuthCookie.parse(setCookie: raw) {
      return cookie
    }
    let candidates = session.configuration.httpCookieStorage?.cookies(for: url)
      ?? session.configuration.httpCookieStorage?.cookies
      ?? []
    for stored in candidates
    where stored.name.hasPrefix("dsh-auth-") {
      return DSHHostAuthCookie(name: stored.name, value: stored.value)
    }
    throw URLError(.userAuthenticationRequired)
  }
}
