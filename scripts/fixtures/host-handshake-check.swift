import Foundation

@main
struct HostHandshakeCheck {
  static func main() async throws {
    guard CommandLine.arguments.count == 2,
          let launch = DSHHostLaunch.parse(launchLine: "dsh web: \(CommandLine.arguments[1])")
    else {
      throw URLError(.badURL)
    }
    let cookie = try await DSHHostHandshake.authenticate(launch: launch)
    guard cookie.name.hasPrefix("dsh-auth-"), !cookie.value.isEmpty else {
      throw URLError(.userAuthenticationRequired)
    }
    print("host-handshake: OK")
  }
}
