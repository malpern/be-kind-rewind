import Foundation
@preconcurrency import SQLite

public enum TopicStoreError: LocalizedError, Equatable {
    case dataCorruption(context: String)

    public var errorDescription: String? {
        switch self {
        case .dataCorruption(let context):
            return "TopicStore encountered unexpected database data while reading \(context)."
        }
    }
}

extension TopicStore {
    func requiredValue<T>(
        _ row: [Binding?],
        at index: Int,
        as type: T.Type = T.self,
        context: String
    ) throws -> T {
        guard index < row.count, let value = row[index] as? T else {
            throw TopicStoreError.dataCorruption(context: context)
        }
        return value
    }

    func optionalValue<T>(
        _ row: [Binding?],
        at index: Int,
        as type: T.Type = T.self,
        context: String
    ) throws -> T? {
        guard index < row.count else {
            throw TopicStoreError.dataCorruption(context: context)
        }
        guard let value = row[index] else { return nil }
        guard let typed = value as? T else {
            throw TopicStoreError.dataCorruption(context: context)
        }
        return typed
    }

    func optionalIntValue(_ row: [Binding?], at index: Int, context: String) throws -> Int? {
        try optionalValue(row, at: index, as: Int64.self, context: context).map(Int.init)
    }
}
