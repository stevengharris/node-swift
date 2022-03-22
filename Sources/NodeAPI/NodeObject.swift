@_implementationOnly import CNodeAPI
import Foundation

@dynamicMemberLookup
public class NodeObject: NodeValue, NodeObjectConvertible {

    @_spi(NodeAPI) public final let base: NodeValueBase
    @_spi(NodeAPI) public required init(_ base: NodeValueBase) {
        self.base = base
    }

    class func isObjectType(for value: NodeValueBase) throws -> Bool {
        let type = try value.nodeType()
        return type == .object || type == .function
    }

    public init(coercing value: NodeValueConvertible) throws {
        let ctx = NodeContext.current
        let env = ctx.environment
        var coerced: napi_value!
        try env.check(napi_coerce_to_object(env.raw, value.rawValue(), &coerced))
        self.base = NodeValueBase(raw: coerced, in: ctx)
    }

    public init(_ properties: NodeObjectPropertyList = [:]) throws {
        let ctx = NodeContext.current
        let env = ctx.environment
        var obj: napi_value!
        try env.check(napi_create_object(env.raw, &obj))
        base = NodeValueBase(raw: obj, in: ctx)
        try define(properties)
    }

    public final func isInstance(of constructor: NodeFunction) throws -> Bool {
        var result = false
        try base.environment.check(
            napi_instanceof(base.environment.raw, base.rawValue(), constructor.base.rawValue(), &result)
        )
        return result
    }

}

extension Dictionary: NodeValueConvertible, NodeObjectConvertible, NodePropertyConvertible
    where Key == String, Value == NodePropertyConvertible {
    public func nodeValue() throws -> NodeValue {
        try NodeObject(.init(Array(self)))
    }
}

extension Dictionary: NodeValueCreatable, AnyNodeValueCreatable where Key == String, Value == NodeValue {
    public static func from(_ value: NodeObject) throws -> [Key: Value] {
        guard let keys = try value.propertyNames(
            collectionMode: .includePrototypes,
            filter: [.enumerable, .skipSymbols],
            conversion: .numbersToStrings
        ).as([NodeValue].self) else {
            throw NodeAPIError(.invalidArg, message: "Could not convert JS object to [NodeValue]")
        }
        return try Dictionary(uniqueKeysWithValues: keys.map {
            guard let k = try $0.as(String.self) else {
                throw NodeAPIError(.invalidArg, message: "Expected string key in JS object, got \($0)")
            }
            return try (k, value[k].nodeValue())
        })
    }
}

// MARK: - Properties

extension NodeObject {

    @dynamicCallable
    @dynamicMemberLookup
    @NodeActor public final class DynamicProperty: NodeValueConvertible {
        let obj: NodeObject
        let key: NodeValueConvertible

        init(obj: NodeObject, key: NodeValueConvertible) {
            self.obj = obj
            self.key = key
        }

        public func nodeValue() throws -> NodeValue {
            let env = obj.base.environment
            var ret: napi_value!
            try env.check(
                napi_get_property(
                    env.raw,
                    obj.base.rawValue(),
                    key.rawValue(),
                    &ret
                )
            )
            return AnyNodeValue(raw: ret)
        }

        public func set(to value: NodeValueConvertible) throws {
            let env = obj.base.environment
            try env.check(napi_set_property(
                env.raw,
                obj.base.rawValue(),
                key.rawValue(),
                value.rawValue()
            ))
        }

        @discardableResult
        public func delete() throws -> Bool {
            let env = obj.base.environment
            var result = false
            try env.check(napi_delete_property(
                env.raw,
                obj.base.rawValue(),
                key.rawValue(),
                &result
            ))
            return result
        }

        public func exists() throws -> Bool {
            let env = obj.base.environment
            var result = false
            try env.check(napi_has_property(
                env.raw,
                obj.base.rawValue(),
                key.rawValue(),
                &result
            ))
            return result
        }

        // see NodeFunction for an explanation on why we can't use callAsFunction
        @discardableResult
        public func dynamicallyCall(withArguments args: [NodeValueConvertible]) throws -> NodeValue {
            guard let fn = try self.as(NodeFunction.self) else {
                throw NodeAPIError(.functionExpected)
            }
            return try fn.call(on: obj, args)
        }

        public func property(forKey key: NodeValueConvertible) throws -> DynamicProperty {
            // forwards to nodeValue()
            guard let obj = try self.as(NodeObject.self) else {
                throw NodeAPIError(.objectExpected, message: "Cannot access property on non-object")
            }
            return DynamicProperty(obj: obj, key: key)
        }

        public subscript(key: NodeValueConvertible) -> DynamicProperty {
            get throws {
                try property(forKey: key)
            }
        }

        public subscript(dynamicMember key: String) -> DynamicProperty {
            get throws {
                try property(forKey: key)
            }
        }
    }

    public final func property(forKey key: NodeValueConvertible) -> DynamicProperty {
        DynamicProperty(obj: self, key: key)
    }

    public final subscript(key: NodeValueConvertible) -> DynamicProperty {
        property(forKey: key)
    }

    public final subscript(dynamicMember key: String) -> DynamicProperty {
        property(forKey: key)
    }

    public final func hasOwnProperty(_ key: NodeName) throws -> Bool {
        var result = false
        let env = base.environment
        try env.check(napi_has_own_property(
            env.raw,
            base.rawValue(),
            key.rawValue(),
            &result
        ))
        return result
    }

    public enum KeyCollectionMode {
        case includePrototypes
        case ownOnly

        var raw: napi_key_collection_mode {
            switch self {
            case .includePrototypes:
                return napi_key_include_prototypes
            case .ownOnly:
                return napi_key_own_only
            }
        }
    }

    public enum KeyConversion {
        case keepNumbers
        case numbersToStrings

        var raw: napi_key_conversion {
            switch self {
            case .keepNumbers:
                return napi_key_keep_numbers
            case .numbersToStrings:
                return napi_key_numbers_to_strings
            }
        }
    }

    public struct KeyFilter: RawRepresentable, OptionSet {
        public let rawValue: CEnum
        public init(rawValue: CEnum) {
            self.rawValue = rawValue
        }

        init(_ raw: napi_key_filter) {
            self.rawValue = raw.rawValue
        }
        var raw: napi_key_filter { .init(rawValue) }

        public static let allProperties = KeyFilter(napi_key_all_properties)
        public static let writable = KeyFilter(napi_key_writable)
        public static let enumerable = KeyFilter(napi_key_enumerable)
        public static let configurable = KeyFilter(napi_key_configurable)
        public static let skipStrings = KeyFilter(napi_key_skip_strings)
        public static let skipSymbols = KeyFilter(napi_key_skip_symbols)
    }

    public final func propertyNames(
        collectionMode: KeyCollectionMode,
        filter: KeyFilter,
        conversion: KeyConversion
    ) throws -> NodeArray {
        let env = base.environment
        var result: napi_value!
        try env.check(
            napi_get_all_property_names(
                env.raw,
                base.rawValue(),
                collectionMode.raw,
                filter.raw,
                conversion.raw,
                &result
            )
        )
        return NodeArray(NodeValueBase(raw: result, in: .current))
    }

    public final func define(_ properties: NodeObjectPropertyList) throws {
        let env = base.environment
        var descriptors: [napi_property_descriptor] = []
        var callbacks: [NodeProperty.Callbacks] = []
        for (name, prop) in properties.elements {
            let (desc, cb) = try prop.nodeProperty.raw(name: name)
            descriptors.append(desc)
            if let cb = cb {
                callbacks.append(cb)
            }
        }
        try env.check(napi_define_properties(env.raw, base.rawValue(), properties.elements.count, descriptors))
        if !callbacks.isEmpty {
            // retain new callbacks
            try addFinalizer { _ = callbacks }
        }
    }

    public final func prototype() throws -> NodeValue {
        let env = base.environment
        var result: napi_value!
        try env.check(napi_get_prototype(env.raw, base.rawValue(), &result))
        return AnyNodeValue(raw: result)
    }

    #if !NAPI_VERSIONED || NAPI_GE_8
    public final func freeze() throws {
        try base.environment.check(
            napi_object_freeze(
                base.environment.raw,
                base.rawValue()
            )
        )
    }

    public final func seal() throws {
        try base.environment.check(
            napi_object_seal(
                base.environment.raw,
                base.rawValue()
            )
        )
    }
    #else
    @available(*, unavailable, message: "Requires NAPI >= 8")
    public final func freeze() throws { fatalError() }

    @available(*, unavailable, message: "Requires NAPI >= 8")
    public final func seal() throws { fatalError() }
    #endif

}

// MARK: - Object Wrap

extension NodeObject {

    fileprivate enum TypeTagStatus {
        case present
        case absent
        case unknown
    }

    #if !NAPI_VERSIONED || NAPI_GE_8

    // we could make this public but its functionality can pretty much be
    // replicated by the wrapped value stuff

    private func withTypeTag<T>(_ tag: UUID, do action: (UnsafePointer<napi_type_tag>) throws -> T) rethrows -> T {
        try withUnsafePointer(to: tag.uuid) {
            try $0.withMemoryRebound(to: napi_type_tag.self, capacity: 1, action)
        }
    }

    // can be called at most once per value
    fileprivate func setTypeTag(_ tag: UUID) throws {
        let env = base.environment
        try withTypeTag(tag) {
            try env.check(
                napi_type_tag_object(
                    env.raw, base.rawValue(), $0
                )
            )
        }
    }

    fileprivate func hasTypeTag(_ tag: UUID) throws -> TypeTagStatus {
        let env = base.environment
        var result = false
        try withTypeTag(tag) {
            try env.check(
                napi_check_object_type_tag(
                    env.raw, base.rawValue(), $0, &result
                )
            )
        }
        return result ? .present : .absent
    }

    #else

    fileprivate func setTypeTag(_ tag: UUID) throws {}
    fileprivate func hasTypeTag(_ tag: UUID) throws -> TypeTagStatus { .unknown }

    #endif

}

public final class NodeWrappedDataKey<T> {
    public init() {}
}

private typealias WrappedData = Box<[ObjectIdentifier: Any]>

private func cWrapFinalizer(rawEnv: napi_env!, data: UnsafeMutableRawPointer!, hint: UnsafeMutableRawPointer!) {
    Unmanaged<WrappedData>.fromOpaque(data).release()
}

extension NodeObject {

    private static let ourTypeTag = UUID()

    // TODO: Figure out an alternative solution for wrap tag checking in NAPI < 8
    // (atm we're just blindly trusting that the user is calling the API correctly,
    // which is unsafe and semantically incorrect)

    final func setWrappedValue(_ wrap: Any?, forID id: ObjectIdentifier) throws {
        let env = base.environment
        let raw = try base.rawValue()
        if try hasTypeTag(Self.ourTypeTag) == .present {
            var objRaw: UnsafeMutableRawPointer!
            try env.check(napi_unwrap(env.raw, raw, &objRaw))
            let objUnmanaged = Unmanaged<WrappedData>.fromOpaque(objRaw)
            let obj = objUnmanaged.takeUnretainedValue()
            obj.value[id] = wrap
            // we can't remove the wrap here because we'd also have to remove the
            // type tag, which isn't possible with current APIs
        } else if let wrap = wrap {
            let obj = WrappedData([:])
            obj.value[id] = wrap
            let objUnmanaged = Unmanaged<WrappedData>.passRetained(obj)
            let objRaw = objUnmanaged.toOpaque()
            do {
                try env.check(napi_wrap(env.raw, raw, objRaw, cWrapFinalizer, nil, nil))
            } catch {
                objUnmanaged.release()
                throw error
            }
            try setTypeTag(Self.ourTypeTag)
        }
    }

    final func wrappedValue(forID id: ObjectIdentifier) throws -> Any? {
        guard try hasTypeTag(Self.ourTypeTag) != .absent else { return nil }
        let env = base.environment
        var objRaw: UnsafeMutableRawPointer!
        try env.check(napi_unwrap(env.raw, base.rawValue(), &objRaw))
        let obj = Unmanaged<WrappedData>.fromOpaque(objRaw).takeUnretainedValue()
        return obj.value[id]
    }

    /// - Warning: when using NAPI < 8, it is currently UB to call this on an object
    /// that already has a wrapped value.
    public final func setWrappedValue<T>(_ wrap: T?, forKey key: NodeWrappedDataKey<T>) throws {
        try setWrappedValue(wrap, forID: ObjectIdentifier(key))
    }

    /// - Warning: when using NAPI < 8, it is currently UB to call this on an object
    /// that does not have the expected wrapped value.
    public final func wrappedValue<T>(forKey key: NodeWrappedDataKey<T>) throws -> T? {
        try wrappedValue(forID: ObjectIdentifier(key)) as? T
    }

}

// MARK: - Finalizers

private typealias FinalizeWrapper = Box<() -> Void>

private func cFinalizer(rawEnv: napi_env!, data: UnsafeMutableRawPointer!, hint: UnsafeMutableRawPointer!) {
    Unmanaged<FinalizeWrapper>
        .fromOpaque(data)
        .takeRetainedValue() // releases the wrapper post-call
        .value()
}

extension NodeObject {

    // Wrap should be sufficient in most cases, but finalizers are handy
    // when you don't want to tag the object
    public final func addFinalizer(_ finalizer: @escaping () -> Void) throws {
        let data = Unmanaged.passRetained(FinalizeWrapper(finalizer)).toOpaque()
        try base.environment.check(
            napi_add_finalizer(base.environment.raw, base.rawValue(), data, cFinalizer, nil, nil)
        )
    }

}
