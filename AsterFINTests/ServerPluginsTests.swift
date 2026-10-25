//
//  ServerPluginsTests.swift
//  AsterFINTests
//
//  A companion plugin's state from the server's plugin list (GUIDs without
//  dashes, status as a word), its catalogue and its version.
//

import Foundation
import Testing
@testable import AsterFIN

struct ServerPluginsTests {
    private func installed(_ json: String) throws -> [InstalledPlugin] {
        try JSONDecoder().decode([InstalledPlugin].self, from: Data(json.utf8))
    }

    private let channels = #"{"Name":"Aster Channels","Version":"0.2.0.0","Id":"5b4892272fc44dceb7f86d0e3b2082ee","CanUninstall":true,"HasImage":false,"Status":"%@"}"#

    private func channelsListed(_ status: String) throws -> [InstalledPlugin] {
        try installed("[\(channels.replacingOccurrences(of: "%@", with: status))]")
    }

    @Test func eachStatusOnTheServerIsAState() throws {
        #expect(PluginState.from(installed: try channelsListed("Active"), packages: nil, serverVersion: "12.1.0", for: .channels) == .active)
        #expect(PluginState.from(installed: try channelsListed("Restart"), packages: nil, serverVersion: "12.1.0", for: .channels) == .afterRestart(on: true))
        #expect(PluginState.from(installed: try channelsListed("Disabled"), packages: nil, serverVersion: "12.1.0", for: .channels) == .disabled)
        #expect(PluginState.from(installed: try channelsListed("Deleted"), packages: nil, serverVersion: "12.1.0", for: .channels) == .afterRestart(on: false))
        #expect(PluginState.from(installed: try channelsListed("Malfunctioned"), packages: nil, serverVersion: "12.1.0", for: .channels) == .broken)
    }

    @Test func aSupersededVersionDoesNotCount() throws {
        let list = try channelsListed("Superceded")
        #expect(PluginState.from(installed: list, packages: nil, serverVersion: "12.1.0", for: .channels) == .notInstalled)
    }

    @Test func anotherPluginIsNotThisOne() throws {
        let list = try channelsListed("Active")
        #expect(PluginState.from(installed: list, packages: nil, serverVersion: "12.1.0", for: .disc) == .notInstalled)
    }

    @Test func tooOldAServerNeedsANewerOne() throws {
        let packages = try JSONDecoder().decode([PluginPackage].self, from: Data(#"""
        [{"name":"Aster Channels","guid":"5b489227-2fc4-4dce-b7f8-6d0e3b2082ee","versions":[
            {"version":"0.2.0.0","targetAbi":"12.1.0.0","repositoryUrl":"x"},
            {"version":"0.1.1.0","targetAbi":"12.1.0.0","repositoryUrl":"x"}]}]
        """#.utf8))
        #expect(PluginState.from(installed: [], packages: packages, serverVersion: "12.0.3", for: .channels) == .needsNewerServer("12.1"))
        #expect(PluginState.from(installed: [], packages: packages, serverVersion: "12.1.0", for: .channels) == .notInstalled)
        // Before the repository is added, the plugin's own minimum.
        #expect(PluginState.from(installed: [], packages: nil, serverVersion: "12.0.3", for: .channels) == .needsNewerServer("12.1"))
        #expect(PluginState.from(installed: [], packages: nil, serverVersion: "12.0.3", for: .disc) == .notInstalled)
    }

    @Test func versionsCompareByNumber() {
        #expect(PluginState.versionLess("12.0.9", "12.1.0.0"))
        #expect(PluginState.versionLess("0.9.0.0", "0.10.0.0"))
        #expect(!PluginState.versionLess("12.1.0", "12.1.0.0"))
        #expect(PluginState.shortVersion("12.1.0.0") == "12.1")
    }

    @Test func onlyAnAdministratorsStatesCanBeSwitched() {
        #expect(PluginState.notInstalled.canSwitch)
        #expect(PluginState.disabled.canSwitch)
        #expect(!PluginState.installing.canSwitch)
        #expect(!PluginState.needsNewerServer("12.1").canSwitch)
        #expect(!PluginState.present(true).canSwitch)
        #expect(PluginState.present(true).isOn)
        #expect(!PluginState.afterRestart(on: false).isOn)
    }
}
