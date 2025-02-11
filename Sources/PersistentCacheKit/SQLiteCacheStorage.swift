import Foundation
import os
import SQLite3

public enum FTSIndexingColumns {
    var name: String {
        switch self {
        case .index1: return "index1"
        case .index2: return "index2"
        case .index3: return "index3"
        case .index4: return "index4"
        }
    }
    
    var q: String {
        switch self {
        case .index1(let string): return string
        case .index2(let string): return string
        case .index3(let string): return string
        case .index4(let string): return string
        }
    }
    
    case index1(String), index2(String), index3(String), index4(String)
}

public final class SQLiteCacheStorage: CacheStorage {
	@available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
	static let log = OSLog(subsystem: "co.davidbeck.persistent_cache_kit.plist", category: "sqlite_storage")
	
	public static let shared: SQLiteCacheStorage? = {
		do {
			var url = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
			url.appendPathComponent("SQLiteCacheStorage.shared")
			url.appendPathComponent("storage.sqlite")
			let storage = try SQLiteCacheStorage(url: url)
			
			return storage
		} catch {
			if #available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
				os_log("failed to create shared db: %{public}@", log: log, type: .error, String(describing: error))
			}
			return nil
		}
	}()
	
	private let db: SQLiteDB
	private let queue = DispatchQueue(label: "SQLiteCacheStorage")
	
	public var url: URL {
		return self.db.url
	}
	
	public init(url: URL) throws {
		self.db = try SQLiteDB(url: url)
		
		try self.createTable()
	}
	
	public var maxFilesize: Int? {
		didSet {
			self.queue.async {
				do {
					try self._trimFilesize()
				} catch {
					if #available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
						os_log("failed to trim cache size: %{public}@", log: SQLiteCacheStorage.log, type: .error, String(describing: error))
					}
				}
			}
		}
	}
	
	public func removeAll() throws {
		try self.queue.sync {
			do {
				let sql = "DELETE FROM cache_storage;"
				let statement = try self.db.preparedStatement(forSQL: sql)
				try statement.step()
				try statement.reset()
			}
			
			do {
				let sql = "VACUUM;"
				let statement = try self.db.preparedStatement(forSQL: sql)
				try statement.step()
				try statement.reset()
			}
			
			lastTrimmed = Date()
		}
	}
	
	// MARK: - Queries
	
	private func createTable() throws {
		let statement = try db.preparedStatement(forSQL: "CREATE TABLE IF NOT EXISTS cache_storage (key TEXT PRIMARY KEY NOT NULL, data BLOB, createdAt INTEGER)", shouldCache: false)
		try statement.step()

        let createFTSStatement = try db.preparedStatement(
            forSQL: "CREATE VIRTUAL TABLE IF NOT EXISTS cache_storage_fts USING fts4(key TEXT, index1 TEXT, index2 TEXT, index3 TEXT, index4 TEXT)",
            shouldCache: false
        )
        try createFTSStatement.step()
	}
	
	public subscript(key: String) -> CacheData? {
		get {
			return self.queue.sync {
				var data: Data?
				
				do {
					let sql = "SELECT data FROM cache_storage WHERE key = ?"
					let statement = try self.db.preparedStatement(forSQL: sql)
					
					try statement.bind(key, at: 1)
					
					if try statement.step() {
						data = statement.getData(atColumn: 0)
					}
					
					try statement.reset()
				} catch {
					if #available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
						os_log("error retrieving data from SQLite: %{public}@", log: SQLiteCacheStorage.log, type: .error, String(describing: error))
					}
				}
				
                return CacheData(key: key, data: data,fts: [])
			}
		}
		set {
			self.queue.async {
				do {
					let sql = "INSERT OR REPLACE INTO cache_storage (key, data, createdAt) VALUES (?, ?, ?)"
					
					let statement = try self.db.preparedStatement(forSQL: sql)
					
					try statement.bind(key, at: 1)
                    try statement.bind(newValue?.data, at: 2)
					try statement.bind(Date(), at: 3)
					
					try statement.step()
					try statement.reset()
                    
                    if let fts = newValue?.fts, !fts.isEmpty {
                        let c = fts.map({ $0.name }).joined(separator: ", ")
                        let ftsSql = "INSERT OR REPLACE INTO cache_storage_fts (key, \(c)) VALUES (?, ?, ?, ?, ?)"
                        let ftsStatement = try self.db.preparedStatement(forSQL: ftsSql)
                        try ftsStatement.bind(key, at: 1)
                        for (index, f) in fts.enumerated() {
                            try ftsStatement.bind(f.q, at: Int32(index + 2))
                        }
                        try ftsStatement.step()
                        try ftsStatement.reset()
                    }
					
					try self.trimIfNeeded()
				} catch {
					if #available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
						os_log("error saving data to SQLite: %{public}@", log: SQLiteCacheStorage.log, type: .error, String(describing: error))
					}
				}
			}
		}
	}
    
    /*public func batch(insert values: [CacheData]) {
        self.queue.async {
            do {
                let sql = "INSERT OR REPLACE INTO cache_storage (key, data, createdAt) VALUES (?, ?, ?)"

                for newValue in values {
                    let statement = try self.db.preparedStatement(forSQL: sql)

                    //try statement.bind(key, at: 1)
                    try statement.bind(newValue.data, at: 2)
                    try statement.bind(Date(), at: 3)

                    try statement.step()
                    try statement.reset()

                    let fts = newValue.fts
                    if !fts.isEmpty {
                        let c = fts.map({ $0.name }).joined(separator: ", ")
                        let ftsSql = "INSERT OR REPLACE INTO cache_storage_fts (key, \(c)) VALUES (?, ?, ?, ?, ?)"
                        let ftsStatement = try self.db.preparedStatement(forSQL: ftsSql)

                        //try ftsStatement.bind(key, at: 1)
                        for (index, f) in fts.enumerated() {
                            try ftsStatement.bind(f.q, at: Int32(index + 2))
                        }
                        try ftsStatement.step()
                        try ftsStatement.reset()
                    }
                }

                try self.trimIfNeeded()
            } catch {
                if #available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
                    os_log("error saving data to SQLite: %{public}@", log: SQLiteCacheStorage.log, type: .error, String(describing: error))
                }
            }

        }
    }*/
    
    public func search(q: FTSIndexingColumns) -> [Data] {
        return self.queue.sync {
            var data = Set<Data>()

            do {
                let c = q.name
                let sql = "SELECT data FROM cache_storage WHERE key IN (SELECT key FROM cache_storage_fts WHERE \(c) MATCH ?)"
                let statement = try self.db.preparedStatement(forSQL: sql)

                try statement.bind("*\(q.q)*", at: 1)

                while try statement.step() {
                    if let rowData = statement.getData(atColumn: 0) {
                        //data.append(rowData)
                        data.insert(rowData)
                    }
                }

                try statement.reset()
            } catch {
                print(error.localizedDescription)
            }

            return Array(data)
        }
    }
    
    public func search(q: FTSIndexingColumns) -> [String] {
        return self.queue.sync {
            var data = Set<String>()

            do {
                let c = q.name
                let sql = "SELECT key FROM cache_storage WHERE key IN (SELECT key FROM cache_storage_fts WHERE \(c) MATCH ?)"
                let statement = try self.db.preparedStatement(forSQL: sql)

                try statement.bind("*\(q.q)*", at: 1)

                while try statement.step() {
                    if let rowData = statement.getString(atColumn: 0) {
                        data.insert(rowData)
                    }
                }

                try statement.reset()
            } catch {
                print(error.localizedDescription)
            }

            return Array(data)
        }
    }
    
	private var lastTrimmed: Date?
	
	private func currentFilesize(fast: Bool) throws -> Int {
		if fast {
			var currentFilesize = 0
			
			let sql = "SELECT SUM(LENGTH(data)) AS filesize FROM cache_storage;"
			let statement = try self.db.preparedStatement(forSQL: sql)
			
			if try statement.step() {
				currentFilesize = statement.getInt(atColumn: 0) ?? 0
			}
			
			try statement.reset()
			
			return currentFilesize
		} else {
			return try FileManager.default.attributesOfItem(atPath: self.url.path)[.size] as? Int ?? 0
		}
	}
	
	private func objectCount() throws -> Int {
		var count = 0
		
		let sql = "SELECT COUNT(*) AS count FROM cache_storage;"
		let statement = try self.db.preparedStatement(forSQL: sql)
		
		if try statement.step() {
			count = statement.getInt(atColumn: 0) ?? 0
		}
		
		try statement.reset()
		
		return count
	}
	
	private func trimIfNeeded() throws {
		if let lastTrimmed = lastTrimmed, -lastTrimmed.timeIntervalSinceNow <= 60 {
			return
		}
		
		try self._trimFilesize()
	}
	
	public func trimFilesize() throws {
		try self.queue.sync {
			try self._trimFilesize(fast: false)
		}
	}
	
	private func _trimFilesize(fast: Bool = false) throws {
		guard let maxFilesize = maxFilesize else { return }
		var currentFileSize = try currentFilesize(fast: fast)
		var iteration = 0
		
		while currentFileSize > maxFilesize && iteration < 5 {
			if #available(OSX 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
				os_log("currentFilesize %{public}d is greater than maxFilesize %{public}d. Trimming cache.", log: SQLiteCacheStorage.log, type: .info, currentFileSize, maxFilesize)
			}
			
			let count = try Int(ceil(Double(objectCount()) / 2))
			
			do {
				let sql = "DELETE FROM cache_storage WHERE key IN (SELECT key FROM cache_storage ORDER BY createdAt ASC LIMIT ?);"
				let statement = try self.db.preparedStatement(forSQL: sql)
				try statement.bind(count, at: 1)
				try statement.step()
				try statement.reset()
			}
			
			do {
				let sql = "VACUUM;"
				let statement = try self.db.preparedStatement(forSQL: sql)
				try statement.step()
				try statement.reset()
			}
			
			currentFileSize = try self.currentFilesize(fast: false)
			iteration += 1
		}
		
		self.lastTrimmed = Date()
	}
	
	
	
	/// Wait until all operations have been completed and data has been saved.
	public func sync() {
		queue.sync {}
	}
}
