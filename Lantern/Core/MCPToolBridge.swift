import Foundation
import FoundationModels

/// MCP 서버 도구를 Foundation Models의 `Tool`로 감싼다.
/// JSON Schema를 DynamicGenerationSchema로 변환해 모델이 올바른 인자를 생성하도록 안내하고,
/// 모델이 만든 GeneratedContent를 JSON으로 되돌려 MCP 서버에 전달한다.
nonisolated struct MCPBridgedTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let descriptor: MCPToolDescriptor
    let client: MCPClient
    let onCall: (@Sendable (String, String) -> Void)?

    var name: String { Self.sanitizedName(descriptor.name) }
    var description: String {
        let text = descriptor.description.isEmpty ? "\(descriptor.serverName) 서버의 \(descriptor.name) 도구" : descriptor.description
        return String(text.prefix(200))
    }

    var parameters: GenerationSchema {
        (try? SchemaConverter.generationSchema(from: descriptor.inputSchema, name: name)) ?? Self.fallbackSchema
    }

    private static var fallbackSchema: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "input", description: "도구에 전달할 입력", schema: DynamicGenerationSchema(type: String.self))
            ]
        )
        // 빈 스키마는 만들 수 없으므로 실패 시 문자열 하나짜리로 대체한다.
        return (try? GenerationSchema(root: root, dependencies: [])) ?? String.generationSchema
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let json = arguments.jsonString
        let argumentValue = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:])
        let normalized: JSONValue
        if case .object = argumentValue {
            normalized = argumentValue
        } else {
            normalized = .object(["input": argumentValue])
        }
        let result = try await client.callTool(name: descriptor.name, arguments: normalized)
        onCall?(descriptor.name, String(result.prefix(400)))
        return String(result.prefix(1_500))
    }

    /// 모델 도구 이름은 영문자/숫자/밑줄만 쓰는 편이 안전하다.
    static func sanitizedName(_ raw: String) -> String {
        let allowed = raw.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        return String(allowed)
    }
}

/// JSON Schema(object) → DynamicGenerationSchema
nonisolated enum SchemaConverter {
    enum ConversionError: Error { case unsupported }

    static func generationSchema(from schema: JSONValue, name: String) throws -> GenerationSchema {
        let root = try dynamicSchema(from: schema, name: "\(name)_Arguments")
        return try GenerationSchema(root: root, dependencies: [])
    }

    static func dynamicSchema(from schema: JSONValue, name: String) throws -> DynamicGenerationSchema {
        let description = schema["description"]?.stringValue
        // enum → 문자열 선택지
        if let choices = schema["enum"]?.arrayValue {
            let values = choices.compactMap(\.stringValue)
            if !values.isEmpty {
                return DynamicGenerationSchema(name: name, description: description, anyOf: values)
            }
        }
        let type = schema["type"]?.stringValue ?? (schema["properties"] != nil ? "object" : "string")
        switch type {
        case "string":
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "array":
            let items = schema["items"] ?? .object(["type": .string("string")])
            let itemSchema = try dynamicSchema(from: items, name: "\(name)_Item")
            return DynamicGenerationSchema(arrayOf: itemSchema)
        case "object":
            let properties = schema["properties"]?.objectValue ?? [:]
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            var dynamicProperties: [DynamicGenerationSchema.Property] = []
            for key in properties.keys.sorted() {
                guard let propertySchema = properties[key] else { continue }
                let child = try dynamicSchema(from: propertySchema, name: "\(name)_\(key)")
                dynamicProperties.append(
                    DynamicGenerationSchema.Property(
                        name: key,
                        description: propertySchema["description"]?.stringValue,
                        schema: child,
                        isOptional: !required.contains(key)
                    )
                )
            }
            if dynamicProperties.isEmpty {
                // 인자 없는 도구. 모델이 빈 객체를 만들도록 더미 선택 필드를 둔다.
                dynamicProperties.append(
                    DynamicGenerationSchema.Property(
                        name: "note",
                        description: "선택 메모. 비워 두어도 된다.",
                        schema: DynamicGenerationSchema(type: String.self),
                        isOptional: true
                    )
                )
            }
            return DynamicGenerationSchema(name: name, description: description, properties: dynamicProperties)
        default:
            throw ConversionError.unsupported
        }
    }
}
