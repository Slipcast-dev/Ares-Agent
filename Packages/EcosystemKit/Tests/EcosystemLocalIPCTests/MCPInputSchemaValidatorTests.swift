import Foundation
import XCTest
@testable import EcosystemLocalIPC

final class MCPInputSchemaValidatorTests: XCTestCase {
    private func check(_ json: String, _ schema: String) throws {
        try MCPInputSchemaValidator.validate(arguments: Data(json.utf8), schema: Data(schema.utf8))
    }

    func testNestedObjectsRejectUnknownAndRequireAdvertisedKeys() throws {
        let schema = #"{"type":"object","properties":{"draft":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}},"required":["draft"],"additionalProperties":false}"#
        try check(#"{"draft":{"name":"Правило"}}"#, schema)
        for json in [#"{}"#, #"{"draft":{}}"#, #"{"draft":{"name":"x","enabled":true}}"#, #"{"draft":{"name":"x"},"approved":true}"#] {
            XCTAssertThrowsError(try check(json, schema))
        }
    }

    func testBooleanCannotBecomeNumberOrEnumOne() throws {
        for type in ["integer", "number"] {
            XCTAssertThrowsError(try check("true", "{\"type\":\"\(type)\"}"))
            try check("1", "{\"type\":\"\(type)\"}")
        }
        XCTAssertThrowsError(try check("1", #"{"type":"boolean"}"#))
        XCTAssertThrowsError(try check("true", #"{"enum":[1]}"#))
        XCTAssertThrowsError(try check("1", #"{"enum":[true]}"#))
        try check("false", #"{"enum":[false]}"#)
    }

    func testIntegerFractionOverflowAndExactBounds() throws {
        try check("9223372036854775807", #"{"type":"integer"}"#)
        try check("-9223372036854775808", #"{"type":"integer"}"#)
        for json in ["9223372036854775808", "-9223372036854775809", "1.5", "1e100", "1e400"] {
            XCTAssertThrowsError(try check(json, #"{"type":"integer"}"#))
        }
        try check("1.0", #"{"type":"integer","minimum":1,"maximum":1}"#)
        XCTAssertThrowsError(try check("0", #"{"type":"number","exclusiveMinimum":0}"#))
    }

    func testArrayItemsUniquenessAndSizeUseTypedEquality() throws {
        let schema = #"{"type":"array","items":{"type":"integer","minimum":0},"minItems":1,"maxItems":3,"uniqueItems":true}"#
        try check("[0,1,2]", schema)
        for json in ["[]", "[1,1.0]", "[true]", "[-1]", "[0,1,2,3]"] { XCTAssertThrowsError(try check(json, schema)) }
        try check("[true,1]", #"{"type":"array","uniqueItems":true}"#)
        XCTAssertThrowsError(try check(#"[{"a":1,"b":2},{"b":2,"a":1}]"#, #"{"uniqueItems":true}"#))
    }

    func testUnicodeLengthPatternUUIDAndUTCDate() throws {
        try check(#""е́""#, #"{"type":"string","minLength":2,"maxLength":2}"#)
        XCTAssertThrowsError(try check(#""е́""#, #"{"type":"string","maxLength":1}"#))
        try check(#""A12""#, #"{"type":"string","pattern":"^A[0-9]{2}$"}"#)
        XCTAssertThrowsError(try check(#""B12""#, #"{"pattern":"^A[0-9]{2}$"}"#))
        try check(#""D910F6A4-D21E-42FA-BB6E-C77B1AFD5B92""#, #"{"format":"uuid"}"#)
        XCTAssertThrowsError(try check(#""not-a-uuid""#, #"{"format":"uuid"}"#))
        for date in ["2026-10-17T12:30:00Z", "2026-10-17T12:30:00.123Z"] { try check("\"\(date)\"", #"{"type":"string","format":"date-time"}"#) }
        for date in ["2026-10-17", "2026-10-17T12:30:00+00:00", "2026-13-99T99:99:99Z", "2026-02-30T12:30:00Z"] { XCTAssertThrowsError(try check("\"\(date)\"", #"{"format":"date-time"}"#)) }
    }

    func testUnionAndAdditionalPropertySchema() throws {
        let schema = #"{"oneOf":[{"type":"integer"},{"type":"string","minLength":1}]}"#
        try check("1", schema); try check(#""x""#, schema)
        XCTAssertThrowsError(try check("true", schema))
        XCTAssertThrowsError(try check("1", #"{"oneOf":[{"type":"integer"},{"type":"number"}]}"#))
        try check("null", #"{"type":["string","null"]}"#)
        try check(#"{"x":1}"#, #"{"type":"object","additionalProperties":{"type":"integer"}}"#)
        XCTAssertThrowsError(try check(#"{"x":true}"#, #"{"additionalProperties":{"type":"integer"}}"#))
    }

    func testUnknownOrMalformedSchemaFailsClosedEvenUnusedBranch() throws {
        for schema in [#"{"type":"object","unknown":true}"#, #"{"properties":{"unused":{"format":"email"}}}"#, #"{"additionalProperties":1}"#, #"{"type":"mystery"}"#, #"{"minItems":true}"#, #"{"pattern":"["}"#] {
            XCTAssertThrowsError(try check("{}", schema))
        }
        try check("{}", "true")
        XCTAssertThrowsError(try check("{}", "false"))
    }

    func testDepthNodesAndInputSizeAreBounded() throws {
        let nested = String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17)
        XCTAssertThrowsError(try check(nested, "{}"))
        XCTAssertThrowsError(try check("[" + Array(repeating: "0", count: 10_000).joined(separator: ",") + "]", "{}"))
        XCTAssertThrowsError(try check("\"" + String(repeating: "a", count: 1_048_576) + "\"", "{}"))
        XCTAssertThrowsError(try check("{", "{}"))
    }
}
