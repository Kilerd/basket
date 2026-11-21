import Foundation
import Testing
@testable import BasketCore

@Suite struct LocalizedListTests {
    @Test func listSeparatorFollowsTheLanguage() {
        #expect(ListSeparator.separator(for: Locale(identifier: "en_US")) == ", ")
        #expect(ListSeparator.separator(for: Locale(identifier: "de_DE")) == ", ")
        #expect(ListSeparator.separator(for: Locale(identifier: "zh_Hans_CN")) == "、")
        #expect(ListSeparator.separator(for: Locale(identifier: "ja_JP")) == "、")
    }

    @Test func compactListHasNoConjunction() {
        let list = ["postgres", "shop-db-1"].compactList
        #expect(list.hasPrefix("postgres") && list.hasSuffix("shop-db-1"))
        #expect(list.count <= "postgres".count + "shop-db-1".count + 2)
        #expect(["solo"].compactList == "solo")
        #expect([String]().compactList.isEmpty)
    }
}
