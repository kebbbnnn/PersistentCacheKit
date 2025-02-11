import Foundation
#if os(iOS)
	import UIKit
#endif

public struct CacheData {
    let key: String
    let data: Data?
    var fts: [FTSIndexingColumns]
}

public protocol FTSRepresenting {
    func indices() -> [FTSIndexingColumns]
}

public protocol CacheStorage: AnyObject {
	subscript(_: String) -> CacheData? { get set }
	/// Wait until all operations have been completed and data has been saved.
	func sync()
    /*func batch(insert values: [CacheData])*/
    func search(q: FTSIndexingColumns) -> [Data]
    func search(q: FTSIndexingColumns) -> [String]
}

extension CacheStorage {
	func sync() {}
}

public struct Item<Value: Codable & FTSRepresenting>: Codable, FTSRepresenting {
	public var expiration: Date?
	public var value: Value
	
	public var isValid: Bool {
		if let expiration = expiration {
			return expiration.timeIntervalSinceNow >= 0
		} else {
			return true
		}
	}
	
	public init(_ value: Value, expiration: Date? = nil) {
		self.value = value
		self.expiration = expiration
	}
	
	public init(_ value: Value, expiresIn: TimeInterval) {
		self.init(value, expiration: Date(timeIntervalSinceNow: expiresIn))
	}
    
    public func indices() -> [FTSIndexingColumns] {
        return self.value.indices()
    }
}

public class PersistentCache<Key: CustomStringConvertible & Hashable, Value: Codable & FTSRepresenting> {
	private let queue = DispatchQueue(label: "Cache", attributes: .concurrent)
	private var internalCache = [Key: Item<Value>]()
	
	public let storage: CacheStorage?
	public let namespace: String?
	public let encoder = PropertyListEncoder()
	public let decoder = PropertyListDecoder()
	
	public init(storage: CacheStorage? = SQLiteCacheStorage.shared, namespace: String? = nil) {
		self.storage = storage
		self.namespace = namespace
		
		#if os(iOS)
			NotificationCenter.default.addObserver(self, selector: #selector(self.didReceiveMemoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
		#endif
	}
	
	@objc private func didReceiveMemoryWarning() {
		self.clearMemoryCache()
	}
	
	public func clearMemoryCache(completion: (() -> Void)? = nil) {
		self.queue.async(flags: .barrier) {
			self.internalCache = [:]
			
			if let completion = completion {
				DispatchQueue.global().async {
					completion()
				}
			}
		}
	}
	
	private func stringKey(for key: Key) -> String {
		if let namespace = namespace {
			return namespace + key.description
		} else {
			return key.description
		}
	}
	
	public subscript(key: Key) -> Value? {
		get {
			if let item = self[item: key], item.isValid {
				return item.value
			} else {
				return nil
			}
		}
		set {
			self[item: key] = newValue.map { Item($0) }
		}
	}
	
	public subscript(item key: Key) -> Item<Value>? {
		get {
			return self.queue.sync {
				if let item = self.internalCache[key] {
					return item
                } else if let data = self.storage?[self.stringKey(for: key)]?.data, let item = try? self.decoder.decode(Item<Value>.self, from: data) {
					return item
				} else {
					return nil
				}
			}
		}
		set {
			let data = try? self.encoder.encode(newValue)
			
			self.queue.async(flags: .barrier) {
				self.internalCache[key] = newValue
				
                self.storage?[self.stringKey(for: key)] = CacheData(key: self.stringKey(for: key), data: data, fts: newValue?.indices() ?? [])
			}
		}
	}
    
    public func search(q: FTSIndexingColumns) -> [Item<Value>] {
        return self.queue.sync {
            guard let result: [Data] = self.storage?.search(q: q) else { return [] }
            
            var items: [Item<Value>] = []
            for data in result {
                guard let item = try? self.decoder.decode(Item<Value>.self, from: data) else { continue }
                items.append(item)
            }
            
            return items
        }
    }
    
    public func search(q: FTSIndexingColumns) -> [String] {
        return self.queue.sync {
            guard let result: [String] = self.storage?.search(q: q) else { return [] }
            return result
        }
    }
	
	/// Find a value or generate it if one doesn't exist.
	///
	/// If a value for the given key does not already exist in the cache, the fallback value will be used instead and saved for later use.
	///
	/// - Parameters:
	///   - key: The key to lookup.
	///   - fallback: The value to use if a value for the key does not exist.
	/// - Returns: Either an existing cached value or the result of fallback.
	public func fetch(_ key: Key, fallback: () -> Value) -> Value {
		if let value = self[key] {
			return value
		} else {
			let value = fallback()
			self[key] = value
			return value
		}
	}
	
	private func _fetch(_ key: Key, queue: DispatchQueue = .main, fallback: (() -> Value)?, completion: @escaping (Value?) -> Void) {
		self.queue.sync {
			if let item = self.internalCache[key], item.isValid {
				completion(item.value)
			} else {
				self.queue.async {
                    if let data = self.storage?[self.stringKey(for: key)]?.data, let item = try? self.decoder.decode(Item<Value>.self, from: data) {
						queue.async {
							completion(item.value)
						}
					} else {
						queue.async {
							if let value = fallback?() {
								self[key] = value
								
								completion(value)
							} else {
								completion(nil)
							}
						}
					}
				}
			}
		}
	}
	
	/// Asynchronously fetches data from the filesystem.
	///
	/// This method will sychronously check the in memory cache for the value and call completion immediately if a value is found. Otherwise it will asynchrounously check the filesystem on a background queue. Finally, if no value exists it will call the fallback block and save the returned value to the cache.
	///
	/// - Parameters:
	///   - key: The key to lookup.
	///   - queue: The queue that the completion and fallback blocks will be called on.
	///   - fallback: The value to use if a value for the key does not exist.
	///   - completion: The block to call when a result is found. This will always be called.
	public func fetch(_ key: Key, queue _: DispatchQueue = .main, fallback: @escaping () -> Value, completion: @escaping (Value) -> Void) {
		self._fetch(key, fallback: fallback) { completion($0!) }
	}
	
	/// Asynchronously fetches data from the filesystem.
	///
	/// This method will sychronously check the in memory cache for the value and call completion immediately if a value is found. Otherwise it will asynchrounously check the filesystem on a background queue.
	///
	/// - Parameters:
	///   - key: The key to lookup.
	///   - queue: The queue that the completion block will be called on.
	///   - completion: The block to call when a result is found. This will always be called.
	public func fetch(_ key: Key, queue _: DispatchQueue = .main, completion: @escaping (Value?) -> Void) {
		self._fetch(key, fallback: nil, completion: completion)
	}
	
	/// Wait until all operations have been completed and data has been saved.
	public func sync() {
		queue.sync {}
		self.storage?.sync()
	}
}
