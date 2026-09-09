import CoreFoundation
import Foundation

/// Deliberately small JSON-schema dialect for bundled tools. Unsupported keywords fail at
/// registration; providers cannot accidentally advertise validation the host does not enforce.
enum Schema {
    static let keywords: Set<String> = [
        "type", "properties", "required", "additionalProperties", "items", "enum", "minimum", "maximum", "minLength",
        "maxLength", "maxItems", "description",
    ]
    static func object(_ json: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw CapabilityError.invalidPayload
        }
        return value
    }
    static func validateDefinition(_ json: String) throws {
        let schema = try object(json)
        guard schema["type"] as? String == "object" else { throw CapabilityError.invalidPayload }
        try definition(schema, depth: 0)
    }
    static func definition(_ schema: [String: Any], depth: Int) throws {
        guard depth < 12, Set(schema.keys).isSubset(of: keywords),
            let type = schema["type"] as? String,
            ["object", "array", "string", "number", "integer", "boolean", "null"].contains(type)
        else { throw CapabilityError.invalidPayload }
        if let description = schema["description"], !(description is String) {
            throw CapabilityError.invalidPayload
        }
        for key in ["minimum", "maximum", "minLength", "maxLength", "maxItems"] {
            if let value = schema[key] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                    number.doubleValue.isFinite
                else { throw CapabilityError.invalidPayload }
                if ["minLength", "maxLength", "maxItems"].contains(key) {
                    guard number.doubleValue >= 0, number.doubleValue <= 1_048_576,
                        number.doubleValue.rounded() == number.doubleValue
                    else { throw CapabilityError.invalidPayload }
                }
            }
        }
        if let minimum = schema["minimum"] as? Double, let maximum = schema["maximum"] as? Double, minimum > maximum {
            throw CapabilityError.invalidPayload
        }
        if let minimum = schema["minLength"] as? Int, let maximum = schema["maxLength"] as? Int, minimum > maximum {
            throw CapabilityError.invalidPayload
        }
        if let choices = schema["enum"] {
            guard let values = choices as? [Any], !values.isEmpty, values.count <= 128 else {
                throw CapabilityError.invalidPayload
            }
            var withoutEnum = schema
            withoutEnum.removeValue(forKey: "enum")
            for value in values { try check(value, schema: withoutEnum, depth: depth) }
        }
        if type == "object" {
            guard let properties = schema["properties"] as? [String: [String: Any]],
                schema["additionalProperties"] as? Bool == false
            else { throw CapabilityError.invalidPayload }
            for child in properties.values { try definition(child, depth: depth + 1) }
            if let required = schema["required"] {
                guard let keys = required as? [String], Set(keys).isSubset(of: Set(properties.keys)) else {
                    throw CapabilityError.invalidPayload
                }
            }
        }
        if type == "array" {
            guard let item = schema["items"] as? [String: Any] else { throw CapabilityError.invalidPayload }
            try definition(item, depth: depth + 1)
        }
    }
    static func validate(_ json: String, schema: String) throws {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        try check(value, schema: object(schema), depth: 0)
    }
    static func check(_ value: Any, schema: [String: Any], depth: Int) throws {
        guard depth < 12 else { throw CapabilityError.invalidPayload }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any], let props = schema["properties"] as? [String: [String: Any]],
                Set(object.keys).isSubset(of: Set(props.keys)),
                Set(schema["required"] as? [String] ?? []).isSubset(of: Set(object.keys))
            else { throw CapabilityError.invalidPayload }
            for (key, item) in object {
                guard let property = props[key] else { throw CapabilityError.invalidPayload }
                try check(item, schema: property, depth: depth + 1)
            }
        case "string":
            guard let text = value as? String, text.unicodeScalars.count >= (schema["minLength"] as? Int ?? 0),
                text.unicodeScalars.count <= (schema["maxLength"] as? Int ?? 65_536)
            else { throw CapabilityError.invalidPayload }
        case "integer", "number":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite,
                number.doubleValue >= (schema["minimum"] as? Double ?? -.infinity),
                number.doubleValue <= (schema["maximum"] as? Double ?? .infinity),
                schema["type"] as? String != "integer" || number.doubleValue.rounded() == number.doubleValue
            else { throw CapabilityError.invalidPayload }
        case "boolean":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw CapabilityError.invalidPayload
            }
        case "null": guard value is NSNull else { throw CapabilityError.invalidPayload }
        case "array":
            guard let list = value as? [Any], list.count <= (schema["maxItems"] as? Int ?? 256),
                let item = schema["items"] as? [String: Any]
            else { throw CapabilityError.invalidPayload }
            for element in list { try check(element, schema: item, depth: depth + 1) }
        default: throw CapabilityError.invalidPayload
        }
        if let choices = schema["enum"] as? [Any] {
            guard choices.contains(where: { String(describing: $0) == String(describing: value) }) else {
                throw CapabilityError.invalidPayload
            }
        }
    }
}
