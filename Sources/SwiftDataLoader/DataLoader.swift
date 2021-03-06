//
//  DataLoader.swift
//  App
//
//  Created by Kim de Vos on 01/06/2018.
//
import Foundation
import NIO

public enum DataLoaderFutureValue<T> {
    case success(T)
    case failure(Error)
}

public typealias BatchLoadFunction<Key, Value> = (_ keys: [Key]) throws -> EventLoopFuture<[DataLoaderFutureValue<Value>]>

// Private
private typealias LoaderQueue<Key, Value> = Array<(key: Key, promise: EventLoopPromise<Value>)>

final public class DataLoader<Key: Hashable, Value> {

    private let batchLoadFunction: BatchLoadFunction<Key, Value>
    private let options: DataLoaderOptions<Key, Value>

    private var futureCache = [Key: EventLoopFuture<Value>]()
    private var queue = LoaderQueue<Key, Value>()
    
    private let conurrentQuery = DispatchQueue(label: "DataLoader")

    public init(options: DataLoaderOptions<Key, Value> = DataLoaderOptions(), batchLoadFunction: @escaping BatchLoadFunction<Key, Value>) {
        self.options = options
        self.batchLoadFunction = batchLoadFunction
    }


    /// Loads a key, returning a `Promise` for the value represented by that key.
    public func load(key: Key, on eventLoop: EventLoopGroup) throws -> EventLoopFuture<Value> {
        let cacheKey = options.cacheKeyFunction?(key) ?? key

        var cachedFuture: EventLoopFuture<Value>?
        var promise: EventLoopPromise<Value>?
        
        conurrentQuery.sync {
            if options.cachingEnabled, futureCache[cacheKey] != nil {
                cachedFuture = futureCache[cacheKey]
            } else {
                promise = eventLoop.next().makePromise(of: Value.self)
                if self.options.cachingEnabled {
                    self.futureCache[cacheKey] = promise?.futureResult
                }
            }
        }
        if cachedFuture != nil {
            return cachedFuture!
        }

        let pro = promise!
        let future = pro.futureResult

        if options.batchingEnabled {
            queue.append((key: key, promise: pro))
        } else {
            _ = try batchLoadFunction([key]).map { results  in
                if results.isEmpty {
                    pro.fail(DataLoaderError.noValueForKey("Did not return value for key: \(key)"))
                } else {
                    let result = results[0]
                    switch result {
                    case .success(let value): pro.succeed(value)
                    case .failure(let error): pro.fail(error)
                    }
                }
            }
        }

        return future
    }

    public func loadMany(keys: [Key], on eventLoop: EventLoopGroup) throws -> EventLoopFuture<[Value]> {
        guard !keys.isEmpty else { return eventLoop.next().makeSucceededFuture([])}

        let promise: EventLoopPromise<[Value]> = eventLoop.next().makePromise(of: [Value].self)

        var result = [Value]()

        let futures = try keys.map { try load(key: $0, on: eventLoop) }

        for future in futures {
            _ = future.map { value in
                result.append(value)

                if result.count == keys.count {
                    promise.succeed(result)
                }
            }
        }

        return promise.futureResult
    }

    func clear(key: Key) -> DataLoader<Key, Value> {
        let cacheKey = options.cacheKeyFunction?(key) ?? key
        conurrentQuery.sync {
            futureCache.removeValue(forKey: cacheKey)
        }
        return self
    }

    func clearAll() -> DataLoader<Key, Value> {
        conurrentQuery.sync {
            futureCache.removeAll()
        }
        return self
    }

    public func prime(key: Key, value: Value, on eventLoop: EventLoopGroup) -> DataLoader<Key, Value> {
        let cacheKey = options.cacheKeyFunction?(key) ?? key

        conurrentQuery.sync {
            if futureCache[cacheKey] == nil {
                let promise: EventLoopPromise<Value> = eventLoop.next().makePromise(of: Value.self)
                promise.succeed(value)
                
                futureCache[cacheKey] = promise.futureResult
            }
        }

        return self
    }

    // MARK: - Private
    private func dispatchQueueBatch(queue: LoaderQueue<Key, Value>, on eventLoop: EventLoopGroup) throws { //}-> EventLoopFuture<[Value]> {
        let keys = queue.map { $0.key }

        if keys.isEmpty {
            return //eventLoop.next().newSucceededFuture(result: [])
        }

        // Step through the values, resolving or rejecting each Promise in the
        // loaded queue.
            _ = try batchLoadFunction(keys)
            .flatMapThrowing { values in
                if values.count != keys.count {
                    throw DataLoaderError.typeError("The function did not return an array of the same length as the array of keys. \nKeys count: \(keys.count)\nValues count: \(values.count)")
                }

                for entry in queue.enumerated() {
                    let result = values[entry.offset]

                    switch result {
                    case .failure(let error): entry.element.promise.fail(error)
                    case .success(let value): entry.element.promise.succeed(value)
                    }
                }
            }
            .recover{ error in
                self.failedDispatch(queue: queue, error: error)
            }
    }

    public func dispatchQueue(on eventLoop: EventLoopGroup) throws {
        // Take the current loader queue, replacing it with an empty queue.
        let queue = self.queue
        self.queue = []

        // If a maxBatchSize was provided and the queue is longer, then segment the
        // queue into multiple batches, otherwise treat the queue as a single batch.
        if let maxBatchSize = options.maxBatchSize, maxBatchSize > 0 && maxBatchSize < queue.count {
            for i in 0...(queue.count / maxBatchSize) {
                let startIndex = i * maxBatchSize
                let endIndex = (i + 1) * maxBatchSize
                let slicedQueue = queue[startIndex..<min(endIndex, queue.count)]
                try dispatchQueueBatch(queue: Array(slicedQueue), on: eventLoop)
            }
        } else {
                try dispatchQueueBatch(queue: queue, on: eventLoop)
        }
    }

    private func failedDispatch(queue: LoaderQueue<Key, Value>, error: Error) {
        queue.forEach { (key, promise) in
            _ = clear(key: key)
            promise.fail(error)
        }
    }
}
