import Foundation
import Testing
@testable import BasketCore

@Suite("YAML parser")
struct YAMLParserTests {
    func parse(_ text: String) throws -> YAMLValue { try YAMLParser.parse(text) }

    func map(_ pairs: KeyValuePairs<String, YAMLValue>) -> YAMLValue { .mapping(YAMLMapping(pairs)) }

    // MARK: Structure

    @Test func nestedMappingsAndSequencesKeepOrder() throws {
        let value = try parse("""
            # leading comment
            services:
              web:
                image: nginx:1.27   # trailing comment
                ports:
                  - "8080:80"
                  - 443:443
              db:
                image: postgres:16
            volumes:
              data: {}
            """)
        #expect(value["services"]?.mapping?.keys == ["web", "db"])
        #expect(value["services"]?["web"]?["image"] == .string("nginx:1.27"))
        #expect(value["services"]?["web"]?["ports"] == .sequence([.string("8080:80"), .string("443:443")]))
        #expect(value["volumes"]?["data"] == .mapping(YAMLMapping()))
        #expect(value.mapping?.keys == ["services", "volumes"])
    }

    @Test func compactSequenceAtKeyIndentation() throws {
        let value = try parse("""
            command:
            - sh
            - -c
            - echo hi
            next: 1
            """)
        #expect(value["command"] == .sequence([.string("sh"), .string("-c"), .string("echo hi")]))
        #expect(value["next"] == .int(1))
    }

    @Test func sequenceOfCompactMappings() throws {
        let value = try parse("""
            ports:
              - target: 80
                published: "8080"
                protocol: tcp
              - target: 443
                published: 8443
            """)
        let ports = try #require(value["ports"]?.sequence)
        #expect(ports.count == 2)
        #expect(ports[0] == map(["target": .int(80), "published": .string("8080"), "protocol": .string("tcp")]))
        #expect(ports[1]["published"] == .int(8443))
    }

    @Test func nestedSequences() throws {
        let value = try parse("""
            - - a
              - b
            - - c
            -
              - d
            """)
        #expect(value == .sequence([
            .sequence([.string("a"), .string("b")]), .sequence([.string("c")]), .sequence([.string("d")]),
        ]))
    }

    @Test func emptyValuesAreNull() throws {
        let value = try parse("""
            environment:
              DEBUG:
              EMPTY: ""
            other:
            """)
        #expect(value["environment"]?["DEBUG"] == .null)
        #expect(value["environment"]?["EMPTY"] == .string(""))
        #expect(value["other"] == .null)
    }

    @Test func emptyDocumentAndDocumentMarkers() throws {
        #expect(try parse("") == .null)
        #expect(try parse("# only a comment\n") == .null)
        #expect(try parse("%YAML 1.2\n---\na: 1\n...\n") == map(["a": .int(1)]))
        #expect(try parse("--- # start\nname: shop\n") == map(["name": .string("shop")]))
    }

    @Test func windowsLineEndingsAndBOM() throws {
        #expect(try parse("\u{FEFF}a: 1\r\nb:\r\n  - x\r\n") == map(["a": .int(1), "b": .sequence([.string("x")])]))
    }

    // MARK: Scalars

    @Test func coreSchemaResolution() throws {
        let value = try parse("""
            t: true
            f: False
            yes_is_text: yes
            on_is_text: on
            int: 42
            negative: -7
            octal: 0o17
            hex: 0x1F
            float: 3.25
            exp: 1e3
            version: "3.8"
            tilde: ~
            null_word: null
            port_pair: 8080:80
            time_like: 12:30:00
            inf: .inf
            text: hello world
            dotted: 1.2.3
            """)
        #expect(value["t"] == .bool(true))
        #expect(value["f"] == .bool(false))
        #expect(value["yes_is_text"] == .string("yes"))
        #expect(value["on_is_text"] == .string("on"))
        #expect(value["int"] == .int(42))
        #expect(value["negative"] == .int(-7))
        #expect(value["octal"] == .int(15))
        #expect(value["hex"] == .int(31))
        #expect(value["float"] == .float(3.25))
        #expect(value["exp"] == .float(1000))
        #expect(value["version"] == .string("3.8"))
        #expect(value["tilde"] == .null)
        #expect(value["null_word"] == .null)
        #expect(value["port_pair"] == .string("8080:80"))
        #expect(value["time_like"] == .string("12:30:00"))
        #expect(value["inf"] == .float(.infinity))
        #expect(value["text"] == .string("hello world"))
        #expect(value["dotted"] == .string("1.2.3"))
    }

    @Test func plainScalarsWithIndicatorsInside() throws {
        let value = try parse("""
            url: http://example.com:8080/path?q=1#frag
            hash: a#b
            dash: -x
            colon: a:b
            spaced: a - b
            """)
        #expect(value["url"] == .string("http://example.com:8080/path?q=1#frag"))
        #expect(value["hash"] == .string("a#b"))
        #expect(value["dash"] == .string("-x"))
        #expect(value["colon"] == .string("a:b"))
        #expect(value["spaced"] == .string("a - b"))
    }

    @Test func multiLinePlainScalarsFold() throws {
        let value = try parse("""
            command: python -m http.server
              --bind 0.0.0.0

              8000
            next: x
            """)
        #expect(value["command"] == .string("python -m http.server --bind 0.0.0.0\n8000"))
        #expect(value["next"] == .string("x"))
    }

    @Test func quotedScalars() throws {
        let value = try parse(#"""
            single: 'it''s ${HOME}'
            double: "tab\tnew\nquote\" slash\\ unicode\u00e9 \x41"
            hash: "# not a comment"
            folded: "first
              second

              third"
            escaped_break: "a\
              b"
            """#)
        #expect(value["single"] == .string("it's ${HOME}"))
        #expect(value["double"] == .string("tab\tnew\nquote\" slash\\ unicodeé A"))
        #expect(value["hash"] == .string("# not a comment"))
        #expect(value["folded"] == .string("first second\nthird"))
        #expect(value["escaped_break"] == .string("ab"))
    }

    @Test func quotedKeys() throws {
        let value = try parse("""
            labels:
              "com.example.team": payments
              'traefik.http.routers.web.rule': "Host(`shop.localhost`)"
            """)
        #expect(value["labels"]?.mapping?.keys == ["com.example.team", "traefik.http.routers.web.rule"])
        #expect(value["labels"]?["traefik.http.routers.web.rule"] == .string("Host(`shop.localhost`)"))
    }

    @Test func literalBlockScalarsAndChomping() throws {
        let value = try parse("""
            clip: |
              line 1
                indented
              line 3

            strip: |-
              no newline
            keep: |+
              kept


            after: x
            """)
        #expect(value["clip"] == .string("line 1\n  indented\nline 3\n"))
        #expect(value["strip"] == .string("no newline"))
        #expect(value["keep"] == .string("kept\n\n\n"))
        #expect(value["after"] == .string("x"))
    }

    @Test func foldedBlockScalars() throws {
        let value = try parse("""
            command: >
              sh -c "
              echo one &&
              echo two"

              final
                more indented
              back
            stripped: >-
              a
              b
            """)
        #expect(value["command"] == .string("sh -c \" echo one && echo two\"\nfinal\n  more indented\nback\n"))
        #expect(value["stripped"] == .string("a b"))
    }

    @Test func blockScalarWithIndentationIndicatorAndComment() throws {
        let value = try parse("""
            script: |2  # keeps leading spaces
                indented twice
              base
            done: true
            """)
        #expect(value["script"] == .string("  indented twice\nbase\n"))
        #expect(value["done"] == .bool(true))
    }

    @Test func blockScalarInSequenceAndAtEndOfFile() throws {
        let value = try parse("- |\n  one\n  two\n- >-\n  three\n  four")
        #expect(value == .sequence([.string("one\ntwo\n"), .string("three four")]))
        #expect(try parse("a: |\n  last") == map(["a": .string("last")]))
    }

    // MARK: Flow collections

    @Test func flowCollections() throws {
        let value = try parse("""
            command: ["npm", "run", start]
            empty_list: []
            env: {NODE_ENV: production, PORT: 3000, "QUOTED": 'x'}
            nested: [a, [b, c], {d: e}]
            multi_line: [
              one,   # comment
              two,
            ]
            pair: [a: 1, b]
            set_like: {a, b: 2}
            url_list: [http://a:1, b]
            """)
        #expect(value["command"] == .sequence([.string("npm"), .string("run"), .string("start")]))
        #expect(value["empty_list"] == .sequence([]))
        #expect(value["env"] == map(["NODE_ENV": .string("production"), "PORT": .int(3000), "QUOTED": .string("x")]))
        #expect(value["nested"] == .sequence([.string("a"), .sequence([.string("b"), .string("c")]), map(["d": .string("e")])]))
        #expect(value["multi_line"] == .sequence([.string("one"), .string("two")]))
        #expect(value["pair"] == .sequence([map(["a": .int(1)]), .string("b")]))
        #expect(value["set_like"] == map(["a": .null, "b": .int(2)]))
        #expect(value["url_list"] == .sequence([.string("http://a:1"), .string("b")]))
    }

    // MARK: Anchors, aliases, merge keys, tags

    @Test func anchorsAliasesAndMergeKeys() throws {
        let value = try parse("""
            x-common: &common
              restart: unless-stopped
              environment: &env
                TZ: UTC
                LOG: info
              mem_limit: 256m
            x-extra: &extra
              mem_limit: 1g
              cpus: 2
            services:
              api:
                <<: [*common, *extra]
                image: api
                mem_limit: 512m
              worker:
                <<: *common
                environment:
                  <<: *env
                  LOG: debug
              copy:
                environment: *env
            """)
        let api = try #require(value["services"]?["api"])
        #expect(api["restart"] == .string("unless-stopped"))
        #expect(api["mem_limit"] == .string("512m"))  // explicit beats merged
        #expect(api["cpus"] == .int(2))
        #expect(api["image"] == .string("api"))
        #expect(api.mapping?.keys.contains("<<") == false)
        let worker = try #require(value["services"]?["worker"])
        #expect(worker["environment"] == map(["TZ": .string("UTC"), "LOG": .string("debug")]))
        #expect(worker["mem_limit"] == .string("256m"))
        #expect(value["services"]?["copy"]?["environment"] == map(["TZ": .string("UTC"), "LOG": .string("info")]))
    }

    @Test func earlierMergeSourceWins() throws {
        let value = try parse("""
            a: &a {k: 1, only_a: x}
            b: &b {k: 2, only_b: y}
            c:
              <<: [*a, *b]
            """)
        #expect(value["c"] == map(["k": .int(1), "only_a": .string("x"), "only_b": .string("y")]))
    }

    @Test func anchoredScalarsAndSequences() throws {
        let value = try parse("""
            image: &img redis:7-alpine
            ports: &ports
              - 6379
            copy_image: *img
            copy_ports: *ports
            flow: [*img, &n 5, *n]
            """)
        #expect(value["copy_image"] == .string("redis:7-alpine"))
        #expect(value["copy_ports"] == .sequence([.int(6379)]))
        #expect(value["flow"] == .sequence([.string("redis:7-alpine"), .int(5), .int(5)]))
    }

    @Test func tags() throws {
        let value = try parse("""
            port: !!str 8080
            flag: !!str true
            number: !!int "42"
            ratio: !!float 1
            reset: !reset []
            empty_string: !!str
            """)
        #expect(value["port"] == .string("8080"))
        #expect(value["flag"] == .string("true"))
        #expect(value["number"] == .int(42))
        #expect(value["ratio"] == .float(1))
        #expect(value["reset"] == .sequence([]))
        #expect(value["empty_string"] == .string(""))
    }

    // MARK: Errors

    @Test(arguments: [
        ("a: 1\na: 2\n", 2, 1, "duplicate key"),
        ("a:\n\tb: 1\n", 2, 1, "tabs"),
        ("a: [1, 2\n", 1, 4, "unterminated flow sequence"),
        ("a: \"open\n", 1, 4, "unterminated double-quoted"),
        ("a: *missing\n", 1, 4, "unknown alias"),
        ("a: b: c\n", 1, 4, "unexpected “: ”"),
        ("a:\n  b: 1\n c: 2\n", 3, 2, "bad indentation"),
        ("- a\nb: 1\n", 2, 1, "unexpected content"),
        ("a: 1\n---\nb: 2\n", 2, 1, "more than one YAML document"),
        ("? complex\n: value\n", 1, 1, "complex mapping keys"),
        ("a: \"\\q\"\n", 1, 5, "unknown escape"),
        ("a: 'x' y\n", 1, 8, "unexpected text"),
        ("base: &b 1\nc:\n  <<: *b\n", 3, 3, "merge key"),
        ("a: |x\n  t\n", 1, 4, "block scalar header"),
    ])
    func errorsCarryPositions(_ text: String, _ line: Int, _ column: Int, _ fragment: String) throws {
        do {
            _ = try YAMLParser.parse(text)
            Issue.record("expected an error for \(text.debugDescription)")
        } catch let error as YAMLError {
            #expect(error.line == line && error.column == column, "\(error.localizedDescription)")
            #expect(error.message.contains(fragment), "\(error.message)")
            #expect(error.localizedDescription.hasPrefix("line \(line), column \(column): "))
        }
    }

    // MARK: Real-world shapes

    @Test func typicalComposeFile() throws {
        let value = try parse("""
            name: storefront

            x-healthcheck: &hc
              interval: 10s
              retries: 5

            services:
              proxy:
                image: "nginx:1.27-alpine"
                ports: ["80:80", "443:443"]
                depends_on:
                  app:
                    condition: service_healthy
                volumes:
                  - ./nginx.conf:/etc/nginx/nginx.conf:ro
                  - type: volume
                    source: certs
                    target: /etc/certs
                    read_only: true
              app:
                build:
                  context: ./app
                  args:
                    - NODE_VERSION=22
                image: storefront/app:dev
                command: >-
                  node server.js
                  --port 3000
                environment:
                  - NODE_ENV=production
                  - DATABASE_URL=postgres://app:${DB_PASSWORD:-secret}@db:5432/app
                healthcheck:
                  <<: *hc
                  test: ["CMD", "wget", "-qO-", "http://localhost:3000/health"]
                deploy:
                  resources:
                    limits: {cpus: '0.50', memory: 256M}
              db:
                image: postgres:16
                environment:
                  POSTGRES_PASSWORD: ${DB_PASSWORD:?set DB_PASSWORD}
                volumes: [pgdata:/var/lib/postgresql/data]

            volumes:
              pgdata:
              certs:
                external: true
            """)
        let services = try #require(value["services"]?.mapping)
        #expect(services.keys == ["proxy", "app", "db"])
        #expect(value["services"]?["app"]?["command"] == .string("node server.js --port 3000"))
        #expect(value["services"]?["app"]?["healthcheck"]?["retries"] == .int(5))
        #expect(value["services"]?["app"]?["deploy"]?["resources"]?["limits"]?["cpus"] == .string("0.50"))
        #expect(value["services"]?["proxy"]?["depends_on"]?["app"]?["condition"] == .string("service_healthy"))
        #expect(value["volumes"]?["pgdata"] == .null)
        #expect(value["volumes"]?["certs"]?["external"] == .bool(true))
        #expect(value["services"]?["proxy"]?["volumes"]?.sequence?[1]["read_only"] == .bool(true))
    }
}
