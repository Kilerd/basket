import Foundation
import Testing
@testable import BasketCore

@Suite("JSON formatter (Inspect tab)")
struct JSONFormatterTests {
    /// (kind, text) of every token, read back through UTF-16 ranges as the highlighter does.
    func tokens(_ formatted: FormattedJSON) -> [(JSONToken.Kind, String)] {
        let text = formatted.text as NSString
        return formatted.tokens.map { ($0.kind, text.substring(with: NSRange(location: $0.location, length: $0.length))) }
    }

    @Test func tidiesTheCLIPrettyPrint() throws {
        // The shape `container inspect` prints: " : ", empty containers over several lines.
        let input = """
        [
          {
            "configuration" : {
              "capAdd" : [
                "ALL"
              ],
              "capDrop" : [

              ],
              "dns" : {
                "nameservers" : [

                ],
                "options" : {

                }
              },
              "id" : "web"
            }
          }
        ]

        """
        let expected = """
        [
          {
            "configuration": {
              "capAdd": [
                "ALL"
              ],
              "capDrop": [],
              "dns": {
                "nameservers": [],
                "options": {}
              },
              "id": "web"
            }
          }
        ]
        """
        #expect(try #require(JSONFormatter.format(input)).text == expected)
    }

    @Test func formatsCompactJSONAndKeepsKeyOrder() throws {
        let input = #"{"zeta":1,"alpha":{"y":true,"b":null,"m":[false,"x"]},"mid":"v"}"#
        let expected = """
        {
          "zeta": 1,
          "alpha": {
            "y": true,
            "b": null,
            "m": [
              false,
              "x"
            ]
          },
          "mid": "v"
        }
        """
        #expect(try #require(JSONFormatter.format(input)).text == expected)
    }

    @Test func copiesStringsAndNumbersByteForByte() throws {
        let strings = [#""a\/b""#, #""say \"hi\"""#, #""\u00e9\uD83D\ude00""#, #""tab\there\\""#, "\"é😀中\"", #""\b\f\n\r""#]
        let numbers = ["0", "-0", "1.0e+10", "-0.5", "1E5", "2e-3", "12345678901234567890123456789", "3.14159265358979323846"]
        let input = "[" + (strings + numbers).joined(separator: ",") + "]"
        let formatted = try #require(JSONFormatter.format(input))
        let found = tokens(formatted)
        #expect(found.map(\.1) == strings + numbers)
        #expect(found.map(\.0) == Array(repeating: .string, count: strings.count) + Array(repeating: .number, count: numbers.count))
    }

    @Test func emptyContainers() throws {
        #expect(JSONFormatter.format("[]")?.text == "[]")
        #expect(JSONFormatter.format(" {\n\n } ")?.text == "{}")
        let formatted = try #require(JSONFormatter.format(#"{"a":[ ],"b":{ },"c":[[]],"d":[{}]}"#))
        #expect(formatted.text == """
        {
          "a": [],
          "b": {},
          "c": [
            []
          ],
          "d": [
            {}
          ]
        }
        """)
    }

    @Test func tokenKindsAndRanges() throws {
        let formatted = try #require(JSONFormatter.format(#"{"k":"v","n":-1.5,"t":true,"f":false,"z":null,"e":"😀"}"#))
        let found = tokens(formatted)
        #expect(found.map(\.0) == [.key, .string, .key, .number, .key, .literal, .key, .literal, .key, .literal, .key, .string])
        #expect(found.map(\.1) == [#""k""#, #""v""#, #""n""#, "-1.5", #""t""#, "true", #""f""#, "false", #""z""#, "null", #""e""#, "\"😀\""])
        // Tokens are ordered and never overlap.
        for (a, b) in zip(formatted.tokens, formatted.tokens.dropFirst()) {
            #expect(a.location + a.length <= b.location)
        }
    }

    @Test func scalarsAndWhitespace() {
        #expect(JSONFormatter.format("  42 \n")?.text == "42")
        #expect(JSONFormatter.format("\"text\"")?.text == "\"text\"")
        #expect(JSONFormatter.format("null")?.tokens == [JSONToken(kind: .literal, location: 0, length: 4)])
        #expect(JSONFormatter.format("{\"a\"\t:\r\n1}")?.text == "{\n  \"a\": 1\n}")
    }

    @Test(arguments: [
        "", "   ", "plain text", "{", "[", "]", "{,}", "[1,]", #"{"a":1,}"#, "[1 2]", #"{"a" 1}"#, #"{"a":}"#,
        #"{1:2}"#, #"{"a":1}}"#, #"{"a":1} x"#, "[1][2]", "\"unterminated", "tru", "nul", "truex", "01", "1.",
        "-", "+1", ".5", "1e", "0x10", "NaN", "[Infinity]", #""\x""#, #""\u12G4""#, "\"a\u{01}b\"", "'single'",
        "[\"a\"\n", "\u{FEFF}{}",
    ])
    func invalidInputIsReturnedUnchanged(_ input: String) {
        #expect(JSONFormatter.format(input) == nil)
        #expect(JSONFormatter.tidy(input) == input)
    }

    @Test func formattingIsIdempotentAndKeepsTheValue() throws {
        let input = try String(decoding: TestFixtures.real("image-inspect.json"), as: UTF8.self)
        let once = try #require(JSONFormatter.format(input))
        #expect(JSONFormatter.format(once.text) == once)
        let before = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? NSArray
        let after = try JSONSerialization.jsonObject(with: Data(once.text.utf8)) as? NSArray
        #expect(before != nil && before == after)
        #expect(!once.text.contains(" : "))
    }

    @Test func deepNestingDoesNotRecurse() throws {
        let depth = 1_000
        let input = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let formatted = try #require(JSONFormatter.format(input))
        #expect(formatted.text.contains("[]\n" + String(repeating: " ", count: 2 * (depth - 2)) + "]\n"))
        #expect(formatted.text.hasSuffix("\n  ]\n]"))
    }

    /// Image inspect output can be hundreds of KB; 5 MB must stay well within interactive time even
    /// in a debug build (release is several times faster).
    @Test func fiveMegabytesInLinearTime() throws {
        var parts: [String] = []
        var size = 0
        var index = 0
        while size < 5_000_000 {
            let element = #"{"id":"layer-\#(index)","digest":"sha256:\#(String(repeating: "ab12", count: 16))","#
                + #""size":\#(index * 4096),"ratio":0.\#(index % 97),"empty":[],"labels":{},"flags":[true,false,null],"#
                + #""history":[{"created_by":"RUN echo \"step \#(index)\" \/ é 😀","empty_layer":false}]}"#
            parts.append(element)
            size += element.utf8.count + 1
            index += 1
        }
        let input = "[" + parts.joined(separator: ",") + "]"
        let clock = ContinuousClock()
        var formatted: FormattedJSON?
        let elapsed = clock.measure { formatted = JSONFormatter.format(input) }
        let result = try #require(formatted)
        #expect(input.utf8.count >= 5_000_000)
        #expect(result.tokens.count == index * 19)
        #expect(tokens(FormattedJSON(text: result.text, tokens: [result.tokens.last!])).first?.1 == "false")
        #expect(elapsed < .seconds(3), "formatting 5 MB took \(elapsed)")
    }
}
