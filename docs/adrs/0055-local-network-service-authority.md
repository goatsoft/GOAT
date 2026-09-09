# ADR-0055: Local network service authority

Status: Accepted · 2026-09-07 · Refines ADRs 0045 and 0054.

## Context

A configured Hindsight server at `http://192.168.253.1:8888` over Thunderbolt is local-network infrastructure, but JUDAS's loopback-only service mode would reject that address. The user's active policy was not established during diagnosis. Hindsight's HTTP validator already admitted private IPv4 addresses, so configuration validation and service policy disagreed about local services. The app also omitted the macOS local-network usage description. Direct health, MCP initialization, tool discovery and configured-bank validation succeeded during diagnosis; that does not prove the app has macOS permission.

## Decision

Replace the service policy named Loopback only with Local networks only. The saved `loopbackOnly` value migrates to `localNetworksOnly`. Explicitly configured origins may use localhost, literal IPv4 loopback, RFC 1918/private addresses, IPv4 link-local addresses, IPv6 loopback, unique-local and link-local addresses. IPv4-mapped IPv6 addresses inherit the embedded address's classification. Public addresses, unspecified/multicast addresses and DNS aliases do not acquire local authority. No DNS resolution or network scanning is added.

JUDAS owns the shared literal classifier. Memory imports that policy for its Hindsight HTTP validation; public endpoints still require TLS. Exact origin binding, credential checks, redirect rejection and capability revocation remain mandatory. Configured mode continues to admit explicitly configured remote services. The explicit Block connections mode remains a full stop, including local HTTP services. MCP subprocesses remain denied in restricted modes because their traffic cannot be confined.

Preview content keeps its separate isolation: off-grid and restricted-mode previews permit only loopback network resources, with existing script, navigation, CSP and content-rule limits. Allowing a configured LAN service does not give arbitrary preview documents access to that LAN.

Declare `NSLocalNetworkUsageDescription` and retain `NSAllowsLocalNetworking` without a global ATS bypass. macOS controls the permission grant; the app cannot silently grant itself access. Failed Hindsight connection copy identifies the Local Network setting and reconnect action without exposing credentials or raw server responses.

## Consequences

Thunderbolt and private LAN services are first-class local services. Existing full-block intent remains enforceable. Service configuration and JUDAS classification share one tested definition. macOS permission remains independent of app policy, and a healthy server does not prove permission for this app identity.

## Alternatives considered

Hardcoding one Thunderbolt address would fail for other local links. Treating every hostname as local would introduce mutable DNS authority. Disabling ATS globally or bypassing JUDAS for Hindsight would expand access unnecessarily. Broadening arbitrary preview access is not required to connect a configured service.

## References

[Apple: local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) and [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).
