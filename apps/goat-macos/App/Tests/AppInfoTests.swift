import Foundation
import Testing

@testable import GOAT

@Test func releaseLabelPreservesPatchAndPrereleaseIdentity() {
    #expect(AppInfo.releaseLabel(version: "0.1.0", codename: "Kid") == "0.1 (Kid)")
    #expect(AppInfo.releaseLabel(version: "0.1.2", codename: "Kid") == "0.1.2 (Kid)")
    #expect(AppInfo.releaseLabel(version: "0.2.0", codename: "Yearling") == "0.2 (Yearling)")
    #expect(AppInfo.releaseLabel(version: "0.1.0-rc.1", codename: "Kid") == "0.1.0-rc.1 (Kid)")
}

@Test func releaseChannelCannotSilentlyDefaultToPublished() {
    #expect(AppInfo.buildDetails(channel: "Release", build: "1338") == "Build 1338")
    #expect(AppInfo.buildDetails(channel: "Candidate", build: "1338") == "Candidate · build 1338")
    #expect(AppInfo.buildDetails(channel: "Development", build: "1338") == "Development · build 1338")
    #expect(AppInfo.buildDetails(channel: nil, build: "Unknown") == "Unknown channel · build Unknown")
    #expect(AppInfo.buildDetails(channel: "release", build: "1338") == "Unknown channel · build 1338")
}

@Test func appDeclaresLocalNetworkAccessWithoutDisablingTransportSecurityGlobally() {
    let info = Bundle.main.infoDictionary ?? [:]
    let description = info["NSLocalNetworkUsageDescription"] as? String
    #expect(description?.isEmpty == false)
    let ats = info["NSAppTransportSecurity"] as? [String: Any]
    #expect(ats?["NSAllowsLocalNetworking"] as? Bool == true)
    #expect(ats?["NSAllowsArbitraryLoads"] as? Bool != true)
}
