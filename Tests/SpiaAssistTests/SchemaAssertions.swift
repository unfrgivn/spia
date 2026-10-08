import SpiaAssist
import Testing

func assertStrict(_ value: JSONValue) {
    guard case .object(let object) = value else { return }
    if case .array(let alternatives)? = object["anyOf"] {
        for alternative in alternatives { assertStrict(alternative) }
    }
    let isObjectSchema = object["type"]?.string == "object"
    guard isObjectSchema else { return }
    #expect(object["additionalProperties"] == .bool(false))
    guard case .object(let properties)? = object["properties"],
        case .array(let required)? = object["required"]
    else { return }
    #expect(Set(required.compactMap(\.string)) == Set(properties.keys))
    for property in properties.values { assertStrict(property) }
    if let items = object["items"] { assertStrict(items) }
}
