import Foundation
import Testing

@testable import Waycar

@Suite("Found computers")
struct FoundComputerTests {
    private func computer(
        _ address: String, name: String? = nil, software: String? = nil,
        source: FoundComputer.Source = .sweep
    ) -> FoundComputer {
        FoundComputer(
            address: address, port: 22, serviceName: name, software: software, source: source)
    }

    @Test func banners() {
        #expect(
            FoundComputer.software(fromBanner: "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5\r\n")
                == "OpenSSH_9.6p1 Ubuntu-3ubuntu13.5")
        #expect(FoundComputer.software(fromBanner: "SSH-2.0-dropbear_2022.83") == "dropbear_2022.83")
        #expect(FoundComputer.software(fromBanner: "SSH-2.0-") == nil)
        #expect(FoundComputer.software(fromBanner: "HTTP/1.1 400 Bad Request") == nil)
    }

    @Test func aComputerBothSourcesSawKeepsItsNameAndGainsTheBanner() {
        let merged = FoundComputer.merged([
            computer("192.168.1.20", name: "Mac mini", source: .bonjour),
            computer("192.168.1.20", software: "OpenSSH_9.8"),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].serviceName == "Mac mini")
        #expect(merged[0].software == "OpenSSH_9.8")
        #expect(merged[0].source == .bonjour)
    }

    @Test func sameNameOnTwoInterfacesIsOneRowAndSweepOfEitherAddressEnrichesIt() {
        let home = IPv4Subnet(address: 0xC0A8_012A, mask: 0xFFFF_FF00)
        let interfaces = [
            computer("10.0.0.2", name: "Studio Mac", source: .bonjour),
            computer("192.168.1.21", name: "studio mac", source: .bonjour),
            computer("192.168.1.20", name: "Studio Mac", source: .bonjour),
        ]
        for input in [interfaces, interfaces.reversed().map { $0 }] {
            let merged = FoundComputer.merged(input + [
                computer("10.0.0.2", software: "OpenSSH_9.8"),
                computer("192.168.1.31", software: "OpenSSH_Ubuntu"),
            ], subnet: home)
            #expect(merged.count == 2)
            #expect(merged[0].address == "192.168.1.20")
            #expect(merged[0].serviceName == "Studio Mac")
            #expect(merged[0].software == "OpenSSH_9.8")
            #expect(merged[0].source == .bonjour)
            #expect(merged[1].address == "192.168.1.31")
            // Off this subnet, the lowest interface wins instead.
            #expect(FoundComputer.merged(input).first?.address == "10.0.0.2")
        }
    }

    @Test func namedComputersComeFirstThenAddressesInNumericOrder() {
        let merged = FoundComputer.merged([
            computer("192.168.1.100"),
            computer("192.168.1.9"),
            computer("192.168.1.50", name: "Mac 10", source: .bonjour),
            computer("192.168.1.51", name: "Mac 2", source: .bonjour),
        ])
        #expect(merged.map(\.address) == ["192.168.1.51", "192.168.1.50", "192.168.1.9", "192.168.1.100"])
    }

    @Test func aTitleIsTheNameOrTheAddress() {
        let named = computer("10.0.0.2", name: "Studio")
        #expect(named.title == "Studio")
        #expect(named.subtitle == "10.0.0.2")
        let bare = computer("10.0.0.3")
        #expect(bare.title == "10.0.0.3")
        #expect(bare.subtitle == nil)
    }

    /// The pairing installer runs on macOS and Linux only.
    @Test func aWindowsServerIsNotOfferedPairing() {
        #expect(computer("10.0.0.2", name: "Studio").canPair)
        let windows = FoundComputer(
            address: "10.0.0.3", port: 22, serviceName: nil,
            software: "OpenSSH_for_Windows_9.5", source: .sweep)
        #expect(!windows.canPair)
    }
}

@Suite("IPv4 subnet")
struct IPv4SubnetTests {
    private func subnet(_ address: String, _ mask: String) throws -> IPv4Subnet {
        IPv4Subnet(
            address: try #require(IPv4Subnet.numericValue(of: address)),
            mask: try #require(IPv4Subnet.numericValue(of: mask)))
    }

    @Test func aSlash24SweepsTheOtherHostsOnly() throws {
        let targets = try subnet("192.168.1.42", "255.255.255.0").sweepTargets.map(IPv4Subnet.dotted)
        #expect(targets.count == 253)
        #expect(!targets.contains("192.168.1.42"))
        #expect(!targets.contains("192.168.1.0"))
        #expect(!targets.contains("192.168.1.255"))
        #expect(targets.first == "192.168.1.1")
        #expect(targets.last == "192.168.1.254")
    }

    @Test func aBiggerNetworkIsNarrowedToTheSlash24AroundThePhone() throws {
        let targets = try subnet("10.0.7.9", "255.255.0.0").sweepTargets.map(IPv4Subnet.dotted)
        #expect(targets.count == 253)
        #expect(targets.allSatisfy { $0.hasPrefix("10.0.7.") })
    }

    @Test func aSmallerNetworkKeepsItsOwnBounds() throws {
        let targets = try subnet("192.168.1.70", "255.255.255.192").sweepTargets.map(IPv4Subnet.dotted)
        #expect(targets.first == "192.168.1.65")
        #expect(targets.last == "192.168.1.126")
        #expect(targets.count == 61)
    }

    @Test func aNetworkWithNoOtherHostsHasNoTargets() throws {
        #expect(try subnet("192.168.1.2", "255.255.255.254").sweepTargets.isEmpty)
        #expect(try subnet("192.168.1.2", "255.255.255.255").sweepTargets.isEmpty)
    }

    @Test func onlyPrivateRangesMaySweep() throws {
        for address in ["10.1.2.3", "172.16.0.1", "172.31.255.1", "192.168.0.5"] {
            #expect(try subnet(address, "255.255.255.0").isPrivate, "\(address)")
        }
        // Carrier-grade NAT, Tailscale's range, public and link-local space.
        for address in ["100.64.1.1", "172.32.0.1", "8.8.8.8", "169.254.1.1", "192.169.1.1"] {
            #expect(try !subnet(address, "255.255.255.0").isPrivate, "\(address)")
        }
    }

    @Test func parsesOnlyDottedIPv4() {
        #expect(IPv4Subnet.numericValue(of: "10.0.0.1") == 0x0A00_0001)
        #expect(IPv4Subnet.numericValue(of: "mac.local") == nil)
        #expect(IPv4Subnet.numericValue(of: "10.0.0.256") == nil)
        #expect(IPv4Subnet.numericValue(of: "10.0.1") == nil)
    }
}
