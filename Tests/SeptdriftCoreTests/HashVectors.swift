// SPEC §3 — the ten fixed hash vectors. A second implementation that matches these
// matches our canonical bytes byte for byte.
//
// Every expected value below was produced by python3, NOT by this code, so the vectors
// are an independent check. The generator (re-derivable by anyone):
//
//   python3 -c 'import json,hashlib; obj={}; s=json.dumps(obj,separators=(",",":"),sort_keys=True,ensure_ascii=False); print(s, hashlib.sha256(s.encode()).hexdigest())'
//
// with `obj` replaced per vector:
//   1  {}
//   2  {"b":{"a":1},"a":[1,2]}
//   3  {"s":"é/→"}
//   4  {"s":"a\u0001b\nc\td"}
//   5  {"d":2}            <- see note
//   6  {"d":2.5}
//   7  {"n":-42}
//   8  {"b":True,"c":False}
//   9  {"x":None}
//  10  [1,"a",True,None,{"k":"v"}]
//
// Note on vector 5: the value under test is the Double 2.0. SPEC §3 says numbers render as
// integers where integral, so the canonical bytes are {"d":2}. Python renders 2.0 as "2.0",
// so the Python one-liner is run on the integer form `{"d":2}` — the form the rule demands.
import Foundation
@testable import SeptdriftCore

struct HashVector: Sendable {
    let name: String
    let value: JSONValue
    /// Expected canonical bytes, as text.
    let canonical: String
    /// Expected SHA-256 of those bytes, from python3.
    let sha256: String
}

enum HashVectors {
    static let all: [HashVector] = [
        HashVector(
            name: "empty-object",
            value: .obj([]),
            canonical: "{}",
            sha256: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"),

        HashVector(
            name: "nested",
            value: .obj([
                ("b", .obj([("a", .int(1))])),
                ("a", .array([.int(1), .int(2)])),
            ]),
            canonical: #"{"a":[1,2],"b":{"a":1}}"#,
            sha256: "08ed84788afeb1354bc16d0c651161e81c98bbfd3c68fee30d28c2e7ba414131"),

        HashVector(
            name: "unicode-and-slash",
            value: .obj([("s", .string("\u{00E9}/\u{2192}"))]),
            canonical: "{\"s\":\"\u{00E9}/\u{2192}\"}",
            sha256: "36c5e3cd70863e8b690ecc2c3d1d44551eba0b2e44f81890aa160b377d324074"),

        HashVector(
            name: "control-characters",
            value: .obj([("s", .string("a\u{01}b\nc\td"))]),
            canonical: "{\"s\":\"a\\u0001b\\nc\\td\"}",
            sha256: "2f001bbdc5bc0db3090e68f62f30121d53846d39024e91a6be4a537e6b70b83d"),

        HashVector(
            name: "integral-double",
            value: .obj([("d", .double(2.0))]),
            canonical: #"{"d":2}"#,
            sha256: "1b8adba507eae44988a5f4e416dacb926dffedfe3d649fcfa8bcd33a268be15d"),

        HashVector(
            name: "non-integral-double",
            value: .obj([("d", .double(2.5))]),
            canonical: #"{"d":2.5}"#,
            sha256: "5739bd5d132eb2fe58b1179e36d4af62184d0c6e7e0cf904bc264a485067264c"),

        HashVector(
            name: "negative-int",
            value: .obj([("n", .int(-42))]),
            canonical: #"{"n":-42}"#,
            sha256: "fbd5ac2f42479228ed2d3b495816fbda98a9cb9d71d523869a37e784790e9f2c"),

        HashVector(
            name: "bools",
            value: .obj([("b", .bool(true)), ("c", .bool(false))]),
            canonical: #"{"b":true,"c":false}"#,
            sha256: "7c7b50f79e2b93f33038c05aafd984c5c338fef7e461446c7867a9e456b86b59"),

        HashVector(
            name: "null",
            value: .obj([("x", .null)]),
            canonical: #"{"x":null}"#,
            sha256: "c6b8df5aba33a39cbdee46ffaf77fae93ea2aa7d99d66408162b05a42105bd71"),

        HashVector(
            name: "array",
            value: .array([.int(1), .string("a"), .bool(true), .null, .obj([("k", .string("v"))])]),
            canonical: #"[1,"a",true,null,{"k":"v"}]"#,
            sha256: "9a2058e6d181e8a63f6d4915e923871f9acfbf2a6c46b1684f9d2221ea2632b5"),
    ]
}
