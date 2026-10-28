//
//  OpenSourceTests.swift
//  AsterFINTests
//
//  Every component on Open Source & Licenses has its license texts in the
//  app, so none shows "missing".
//

import Foundation
import Testing
@testable import AsterFIN

struct OpenSourceTests {
    @Test func everyLicenseTextIsInTheApp() {
        let components = [OpenSourceComponent.aster] + OpenSourceComponent.groups.flatMap(\.components)
        for component in components {
            #expect(!component.files.isEmpty, "\(component.name) lists no license")
            for file in component.files {
                #expect(OpenSourceComponent.text(file)?.isEmpty == false, "\(component.name): \(file).txt is missing")
            }
        }
    }

    @Test func componentsAreListedOnce() {
        let names = OpenSourceComponent.groups.flatMap(\.components).map(\.name)
        #expect(Set(names).count == names.count)
    }
}
