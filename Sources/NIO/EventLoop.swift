//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import Dispatch
import NIOPriorityQueue

/// Returned once a task was scheduled on the `EventLoop` for later execution.
///
/// A `Scheduled` allows the user to either `cancel()` the execution of the scheduled task (if possible) or obtain a reference to the `EventLoopFuture` that
/// will be notified once the execution is complete.
public struct Scheduled<T> {
    private let promise: EventLoopPromise<T>
    private let cancellationTask: () -> ()
    
    init(promise: EventLoopPromise<T>, cancellationTask: @escaping () -> ()) {
        self.promise = promise
        promise.futureResult.whenFailure(callback: { error in
            guard let err = error as? EventLoopError else {
                return
            }
            if err == .cancelled {
                cancellationTask()
            }
        })
        self.cancellationTask = cancellationTask
    }
    
    /// Try to cancel the execution of the scheduled task.
    ///
    /// Whether this is successful depends on whether the execution of the task already begun.
    ///  This means that cancellation is not guaranteed.
    public func cancel() {
        promise.fail(error: EventLoopError.cancelled)
    }
    
    /// Returns the `EventLoopFuture` which will be notified once the execution of the scheduled task completes.
    public var futureResult: EventLoopFuture<T> {
        return promise.futureResult
    }
}

/// An EventLoop processes IO / tasks in an endless loop for `Channel`s until it's closed.
///
/// Usually multiple `Channel`s share the same `EventLoop` for processing IO / tasks and so share the same processing `Thread`.
/// For a better understanding of how such an `EventLoop` works internally the following pseudo code may be helpful:
///
/// ```
/// while eventLoop.isOpen {
///     /// Block until there is something to process for 1...n Channels
///     let readyChannels = blockUntilIoOrTasksAreReady()
///     /// Loop through all the Channels
///     for channel in readyChannels {
///         /// Process IO and / or tasks for the Channel.
///         /// This may include things like:
///         ///    - accept new connection
///         ///    - connect to a remote host
///         ///    - read from socket
///         ///    - write to socket
///         ///    - tasks that were submitted via EventLoop methods
///         /// and others.
///         processIoAndTasks(channel)
///     }
/// }
/// ```
///
/// Because an `EventLoop` may be shared between multiple `Channel`s its important to _NOT_ block while processing IO / tasks. This also includes long running computations which will have the same
/// effect as blocking in this case.
public protocol EventLoop: EventLoopGroup {
    /// Returns `true` if the current `Thread` is the same as the `Thread` that is tied to this `EventLoop`. `false` otherwise.
    var inEventLoop: Bool { get }
    
    /// Submit a given task to be executed by the `EventLoop`
    func execute(task: @escaping () -> ())

    /// Submit a given task to be executed by the `EventLoop`. Once the execution is complete the returned `EventLoopFuture` is notified.
    ///
    /// - parameters:
    ///     - task: The closure that will be submited to the `EventLoop` for execution.
    /// - returns: `EventLoopFuture` that is notified once the task was executed.
    func submit<T>(task: @escaping () throws-> (T)) -> EventLoopFuture<T>
    
    /// Schedule a `task` that is executed by this `SelectableEventLoop` after the given amount of time.
    func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws-> (T)) -> Scheduled<T>
}

/// Represents a time _interval_.
///
/// - note: `TimeAmount` should not be used to represent a point in time.
public struct TimeAmount {
    /// The nanoseconds representation of the `TimeAmount`.
    public let nanoseconds: Int

    private init(_ nanoseconds: Int) {
        self.nanoseconds = nanoseconds
    }
    
    /// Creates a new `TimeAmount` for the given amount of nanoseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of nanoseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func nanoseconds(_ amount: Int) -> TimeAmount {
        return TimeAmount(amount)
    }
    
    /// Creates a new `TimeAmount` for the given amount of microseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of microseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func microseconds(_ amount: Int) -> TimeAmount {
        return TimeAmount(amount * 1000)
    }

    /// Creates a new `TimeAmount` for the given amount of milliseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of milliseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func milliseconds(_ amount: Int) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000)
    }
    
    /// Creates a new `TimeAmount` for the given amount of seconds.
    ///
    /// - parameters:
    ///     - amount: the amount of seconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func seconds(_ amount: Int) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000 * 1000)
    }
    
    /// Creates a new `TimeAmount` for the given amount of minutes.
    ///
    /// - parameters:
    ///     - amount: the amount of minutes this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func minutes(_ amount: Int) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000 * 1000 * 60)
    }

    /// Creates a new `TimeAmount` for the given amount of hours.
    ///
    /// - parameters:
    ///     - amount: the amount of hours this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func hours(_ amount: Int) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000 * 1000 * 60 * 60)
    }
}

extension TimeAmount: Comparable {
    public static func < (lhs: TimeAmount, rhs: TimeAmount) -> Bool {
        return lhs.nanoseconds < rhs.nanoseconds
    }
    public static func == (lhs: TimeAmount, rhs: TimeAmount) -> Bool {
        return lhs.nanoseconds == rhs.nanoseconds
    }
}

extension EventLoop {
    public func submit<T>(task: @escaping () throws-> (T)) -> EventLoopFuture<T> {
        let promise: EventLoopPromise<T> = newPromise(file: #file, line: #line)

        execute(task: {() -> () in
            do {
                promise.succeed(result: try task())
            } catch let err {
                promise.fail(error: err)
            }
        })

        return promise.futureResult
    }

    /// Creates and returns a new `EventLoopPromise` that will be notified using this `EventLoop` as execution `Thread`.
    public func newPromise<T>(file: StaticString = #file, line: UInt = #line) -> EventLoopPromise<T> {
        return EventLoopPromise<T>(eventLoop: self, file: file, line: line)
    }

    /// Creates and returns a new `EventLoopFuture` that is already marked as failed. Notifications will be done using this `EventLoop` as execution `Thread`.
    ///
    /// - parameters:
    ///     - error: the `Error` that is used by the `EventLoopFuture`.
    /// - returns: a failed `EventLoopFuture`.
    public func newFailedFuture<T>(error: Error) -> EventLoopFuture<T> {
        return EventLoopFuture<T>(eventLoop: self, error: error, file: "n/a", line: 0)
    }

    /// Creates and returns a new `EventLoopFuture` that is already marked as success. Notifications will be done using this `EventLoop` as execution `Thread`.
    ///
    /// - parameters:
    ///     - result: the value that is used by the `EventLoopFuture`.
    /// - returns: a failed `EventLoopFuture`.
    public func newSucceedFuture<T>(result: T) -> EventLoopFuture<T> {
        return EventLoopFuture<T>(eventLoop: self, result: result, file: "n/a", line: 0)
    }
    
    public func next() -> EventLoop {
        return self
    }
    
    public func close() throws {
        // Do nothing
    }
}

/// Internal representation of a `Registration` to an `Selector`.
///
/// Whenever a `Selectable` is registered to a `Selector` a `Registration` is created internally that is also provided within the
/// `SelectorEvent` that is provided to the user when an event is ready to be consumed for a `Selectable`. As we need to have access to the `ServerSocketChannel`
/// and `SocketChannel` (to dispatch the events) we create our own `Registration` that holds a reference to these.
enum NIORegistration: Registration {
    case serverSocketChannel(ServerSocketChannel, IOEvent)
    case socketChannel(SocketChannel, IOEvent)

    /// The `IOEvent` in which this `NIORegistration` is interested in.
    var interested: IOEvent {
        set {
            switch self {
            case .serverSocketChannel(let c, _):
                self = .serverSocketChannel(c, newValue)
            case .socketChannel(let c, _):
                self = .socketChannel(c, newValue)
            }
        }
        get {
            switch self {
            case .serverSocketChannel(_, let i):
                return i
            case .socketChannel(_, let i):
                return i
            }
        }
    }
}

/// Execute the given closure and ensure we release all auto pools if needed.
private func withAutoReleasePool<T>(_ execute: () throws -> T) rethrows -> T {
    #if os(Linux)
    return try execute()
    #else
    return try autoreleasepool {
        try execute()
    }
    #endif
}

/// The different state in the lifecycle of an `EventLoop`.
private enum EventLoopLifecycleState {
    /// `EventLoop` is open and so can process more work.
    case open
    /// `EventLoop` is currently in the process of closing.
    case closing
    /// `EventLoop` is closed.
    case closed
}

/// `EventLoop` implementation that uses a `Selector` to get notified once there is more I/O or tasks to process.
/// The whole processing of I/O and tasks is done by a `Thread` that is tied to the `SelectableEventLoop`. This `Thread`
/// is guaranteed to never change!
internal final class SelectableEventLoop : EventLoop {
    private let selector: NIO.Selector<NIORegistration>
    private let thread: Thread
    private var scheduledTasks = PriorityQueue<ScheduledTask>(ascending: true)
    private let tasksLock = Lock()
    private var lifecycleState: EventLoopLifecycleState = .open
    
    private let _iovecs: UnsafeMutablePointer<IOVector>
    private let _storageRefs: UnsafeMutablePointer<Unmanaged<AnyObject>>
    
    let iovecs: UnsafeMutableBufferPointer<IOVector>
    let storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>
    
    /// Creates a new `SelectableEventLoop` instance that is tied to the given `pthread_t`.

    private let promiseCreationStoreLock = Lock()
    private var _promiseCreationStore: [ObjectIdentifier: (file: StaticString, line: UInt)] = [:]
    internal func promiseCreationStoreAdd<T>(future: EventLoopFuture<T>, file: StaticString, line: UInt) {
        precondition(_isDebugAssertConfiguration())
        self.promiseCreationStoreLock.withLock {
            self._promiseCreationStore[ObjectIdentifier(future)] = (file: file, line: line)
        }
    }

    internal func promiseCreationStoreRemove<T>(future: EventLoopFuture<T>) -> (file: StaticString, line: UInt) {
        precondition(_isDebugAssertConfiguration())
        return self.promiseCreationStoreLock.withLock {
            self._promiseCreationStore[ObjectIdentifier(future)]!
        }
    }

    public init(thread: Thread) throws {
        self.selector = try NIO.Selector()
        self.thread = thread
        self._iovecs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimitIOVectors)
        self._storageRefs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimitIOVectors)
        self.iovecs = UnsafeMutableBufferPointer(start: self._iovecs, count: Socket.writevLimitIOVectors)
        self.storageRefs = UnsafeMutableBufferPointer(start: self._storageRefs, count: Socket.writevLimitIOVectors)
    }
    
    deinit {
        _iovecs.deallocate()
        _storageRefs.deallocate()
    }
    
    /// Register the given `SelectableChannel` with this `SelectableEventLoop`. After this point all I/O for the `SelectableChannel` will be processed by this `SelectableEventLoop` until it
    /// is deregistered by calling `deregister`.
    public func register<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        try selector.register(selectable: channel.selectable, interested: channel.interestedEvent, makeRegistration: channel.registrationFor(interested:))
    }

    /// Deregister the given `SelectableChannel` from this `SelectableEventLoop`.
    public func deregister<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        guard lifecycleState == .open else {
            // Its possible the EventLoop was closed before we were able to call deregister, so just return in this case as there is no harm.
            return
        }
        try selector.deregister(selectable: channel.selectable)
    }
    
    /// Register the given `SelectableChannel` with this `SelectableEventLoop`. This should be done whenever `channel.interestedEvents` has changed and it should be taken into account when
    /// waiting for new I/O for the given `SelectableChannel`.
    public func reregister<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        try selector.reregister(selectable: channel.selectable, interested: channel.interestedEvent)
    }
    
    public var inEventLoop: Bool {
        return thread.isCurrent
    }

    public func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws-> (T)) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = newPromise()
        let task = ScheduledTask({
            do {
                promise.succeed(result: try task())
            } catch let err {
                promise.fail(error: err)
            }
        }, { error in
            promise.fail(error: error)
        },`in`)
        
        let scheduled = Scheduled(promise: promise, cancellationTask: {
            self.tasksLock.lock()
            self.scheduledTasks.remove(task)
            self.tasksLock.unlock()
            self.wakeupSelector()
        })
      
        schedule0(task)
        return scheduled
    }
    
    public func execute(task: @escaping () -> ()) {
        schedule0(ScheduledTask(task, { error in
            // do nothing
        }, .nanoseconds(0)))
    }
    
    /// Add the `ScheduledTask` to be executed.
    private func schedule0(_ task: ScheduledTask) {
        tasksLock.lock()
        scheduledTasks.push(task)
        tasksLock.unlock()
        
        wakeupSelector()
    }
    
    /// Wake the `Selector` which means `Selector.whenReady(...)` will unblock.
    private func wakeupSelector() {
        do {
            try selector.wakeup()
        } catch let err {
            fatalError("Error during Selector.wakeup(): \(err)")
        }
    }

    /// Handle the given `IOEvent` for the `SelectableChannel`.
    private func handleEvent<C: SelectableChannel>(_ ev: IOEvent, channel: C) {
        guard handleEvents(channel) else {
            return
        }
        
        switch ev {
        case .write:
            channel.writable()
        case .read:
            channel.readable()
        case .all:
            channel.writable()
            guard handleEvents(channel) else {
                return
            }
            channel.readable()
        case .none:
            // spurious wakeup
            break
            
        }
        guard handleEvents(channel) else {
            return
        }

        // Ensure we never reach here if the channel is not open anymore.
        assert(channel.open)
    }

    private func currentSelectorStrategy() -> SelectorStrategy {
        // TODO: Just use an atomic
        tasksLock.lock()
        let scheduled = scheduledTasks.peek()
        tasksLock.unlock()

        guard let sched = scheduled else {
            // No tasks to handle so just block
            return .block
        }
        
        let nextReady = sched.readyIn(DispatchTime.now())

        if nextReady <= .nanoseconds(0) {
            // Something is ready to be processed just do a non-blocking select of events.
            return .now
        } else {
            return .blockUntilTimeout(nextReady)
        }
    }
    
    /// Start processing I/O and tasks for this `SelectableEventLoop`. This method will continue running (and so block) until the `SelectableEventLoop` is closed.
    public func run() throws {
        precondition(self.inEventLoop, "tried to run the EventLoop on the wrong thread.")
        defer {
            var tasksCopy = ContiguousArray<ScheduledTask>()
            
            tasksLock.lock()
            while let sched = scheduledTasks.pop() {
                tasksCopy.append(sched)
            }
            tasksLock.unlock()
            
            // Fail all the scheduled tasks.
            while let task = tasksCopy.first {
                task.fail(error: EventLoopError.shutdown)
            }
        }
        while lifecycleState != .closed {
            // Block until there are events to handle or the selector was woken up
            /* for macOS: in case any calls we make to Foundation put objects into an autoreleasepool */
            try withAutoReleasePool {
                
                try selector.whenReady(strategy: currentSelectorStrategy()) { ev in
                    switch ev.registration {
                    case .serverSocketChannel(let chan, _):
                        self.handleEvent(ev.io, channel: chan)
                    case .socketChannel(let chan, _):
                        self.handleEvent(ev.io, channel: chan)
                    }
                }
            }
            
            // We need to ensure we process all tasks, even if a task added another task again
            while true {
                // TODO: Better locking
                tasksLock.lock()
                if scheduledTasks.isEmpty {
                    tasksLock.unlock()
                    break
                }
                var tasksCopy = ContiguousArray<() -> ()>()

                // We only fetch the time one time as this may be expensive and is generally good enough as if we miss anything we will just do a non-blocking select again anyway.
                let now = DispatchTime.now()
                
                // Make a copy of the tasks so we can execute these while not holding the lock anymore
                while let task = scheduledTasks.peek(), task.readyIn(now) <= .nanoseconds(0) {
                    tasksCopy.append(task.task)

                    let _ = scheduledTasks.pop()
                }

                tasksLock.unlock()
                
                // all pending tasks are set to occur in the future, so we can stop looping.
                if tasksCopy.count == 0 {
                    break
                }
                
                // Execute all the tasks that were summited
                while let task = tasksCopy.first {
                    /* for macOS: in case any calls we make to Foundation put objects into an autoreleasepool */
                    withAutoReleasePool {
                        task()
                    }
                    
                    let _ = tasksCopy.removeFirst()
                }
            }
        }
        
        // This EventLoop was closed so also close the underlying selector.
        try self.selector.close()
    }

    /// Returns `true` if the `SelectableChannel` is still open and so we should continue handling IO / tasks for it. Otherwise it returns `false` and will deregister the `SelectableChannel`
    /// from this `SelectableEventLoop`.
    private func handleEvents<C: SelectableChannel>(_ channel: C) -> Bool {
        if channel.open {
            return true
        }
        do {
            try deregister(channel: channel)
        } catch {
            // ignore for now... We should most likely at least log this.
        }

        return false
    }
    
    fileprivate func close0() throws {
        if inEventLoop {
            self.lifecycleState = .closed
        } else {
            _ = self.submit(task: { () -> (Void) in
                self.lifecycleState = .closed
            })
        }
    }

    /// Gently close this `SelectableEventLoop` which means we will close all `SelectableChannel`s before finally close this `SelectableEventLoop` as well.
    public func closeGently() -> EventLoopFuture<Void> {
        func closeGently0() -> EventLoopFuture<Void> {
            guard self.lifecycleState == .open else {
                return self.newFailedFuture(error: ChannelError.alreadyClosed)
            }
            self.lifecycleState = .closing
            return self.selector.closeGently(eventLoop: self)
        }
        if self.inEventLoop {
            return closeGently0()
        } else {
            let p: EventLoopPromise<Void> = self.newPromise()
            _ = self.submit {
                closeGently0().cascade(promise: p)
            }
            return p.futureResult
        }
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        self.closeGently().whenComplete { closeGentlyResult in
            let closeResult: ()? = try? self.close0()
            switch (closeGentlyResult, closeResult) {
            case (.success(()), .some(())):
                queue.async {
                    callback(nil)
                }
            case (.failure(let error), _):
                queue.async {
                    callback(error)
                }
            case (_, .none):
                queue.async {
                    callback(EventLoopError.shutdownFailed)
                }
            }
        }
    }
}


/// Provides an endless stream of `EventLoop`s to use.
public protocol EventLoopGroup: class {
    /// Returns the next `EventLoop` to use.
    func next() -> EventLoop

    /// Shuts down the eventloop gracefully. This function is clearly an outlier in that it uses a completion
    /// callback instead of an EventLoopFuture. The reason for that is that NIO's EventLoopFutures will call back on an event loop.
    /// The virtue of this function is to shut the event loop down. To work around that we call back on a DispatchQueue
    /// instead.
    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void)
}

extension EventLoopGroup {
    public func shutdownGracefully(_ callback: @escaping (Error?) -> Void) {
        self.shutdownGracefully(queue: .global(), callback)
    }

    public func syncShutdownGracefully() throws {
        let errorStorageLock = Lock()
        var errorStorage: Error? = nil
        let continuation = DispatchWorkItem {}
        self.shutdownGracefully { error in
            if let error = error {
                errorStorageLock.withLock {
                    errorStorage = error
                }
            }
            continuation.perform()
        }
        continuation.wait()
        try errorStorageLock.withLock {
            if let error = errorStorage {
                throw error
            }
        }
    }
}

/// An `EventLoopGroup` which will create multiple `EventLoop`s, each tied to its own `Thread`.
final public class MultiThreadedEventLoopGroup : EventLoopGroup {
    
    private let index = Atomic<Int>(value: 0)
    private let eventLoops: [SelectableEventLoop]

    private static func setupThreadAndEventLoop(name: String) -> SelectableEventLoop {
        let lock = Lock()
        /* the `loopUpAndRunningGroup` is done by the calling thread when the EventLoop has been created and was written to `_loop` */
        let loopUpAndRunningGroup = DispatchGroup()

        /* synchronised by `lock` */
        var _loop: SelectableEventLoop! = nil

        if #available(OSX 10.12, *) {
            loopUpAndRunningGroup.enter()
            Thread.spawnAndRun(name: name) { t in
                do {
                    /* we try! this as this must work (just setting up kqueue/epoll) or else there's not much we can do here */
                    let l = try! SelectableEventLoop(thread: t)
                    lock.withLock {
                        _loop = l
                    }
                    loopUpAndRunningGroup.leave()
                    try l.run()
                } catch let err {
                    fatalError("unexpected error while executing EventLoop \(err)")
                }
            }
            loopUpAndRunningGroup.wait()
            return lock.withLock { _loop }
        } else {
            fatalError("Unsupported platform / OS version")
        }
    }

    public init(numThreads: Int) {
        self.eventLoops = (0..<numThreads).map { threadNo in
            // Maximum name length on linux is 16 by default.
            MultiThreadedEventLoopGroup.setupThreadAndEventLoop(name: "NIO-ELT-#\(threadNo)")
        }
    }
    
    public func next() -> EventLoop {
        return eventLoops[abs(index.add(1) % eventLoops.count)]
    }
    
    internal func unsafeClose() throws {
        for loop in eventLoops {
            // TODO: Should we log this somehow or just rethrow the first error ?
            _ = try loop.close0()
        }
    }

    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        // This method cannot perform its final cleanup using EventLoopFutures, because it requires that all
        // our event loops still be alive, and they may not be. Instead, we use Dispatch to manage
        // our shutdown signaling, and then do our cleanup once the DispatchQueue is empty.
        let g = DispatchGroup()
        let q = DispatchQueue(label: "nio.shutdownGracefullyQueue", target: queue)
        var error: Error? = nil

        for loop in self.eventLoops {
            g.enter()
            loop.closeGently().whenComplete {
                switch $0 {
                case .success:
                    break
                case .failure(let err):
                    q.sync { error = err }
                }
                g.leave()
            }
        }

        g.notify(queue: q) {
            let failure = self.eventLoops.map { try? $0.close0() }.filter { $0 == nil }.count > 0
            if failure {
                error = EventLoopError.shutdownFailed
            }

            callback(error)
        }
    }
}

private final class ScheduledTask {
    let task: () -> ()
    private let failFn: (Error) ->()
    private let readyTime: Int
    
    init(_ task: @escaping () -> (), _ failFn: @escaping (Error) -> (), _ time: TimeAmount) {
        self.task = task
        self.failFn = failFn
        self.readyTime = time.nanoseconds + Int(DispatchTime.now().uptimeNanoseconds)
    }
    
    func readyIn(_ t: DispatchTime) -> TimeAmount {
        if readyTime < t.uptimeNanoseconds {
            return .nanoseconds(0)
        }
        return .nanoseconds(readyTime - Int(t.uptimeNanoseconds))
    }
    
    func fail(error: Error) {
        failFn(error)
    }
}

extension ScheduledTask: CustomStringConvertible {
    var description: String {
        return "ScheduledTask(readyTime: \(self.readyTime))"
    }
}

extension ScheduledTask : Comparable {
    public static func < (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        return lhs.readyTime < rhs.readyTime
    }
    public static func == (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        return lhs === rhs
    }
}

/// Different `Error`s that are specific to `EventLoop` operations / implementations.
public enum EventLoopError: Error {
    /// An operation was executed that is not supported by the `EventLoop`
    case unsupportedOperation
    
    /// An scheduled task was cancelled.
    case cancelled
    
    /// The `EventLoop` was shutdown already.
    case shutdown
    
    /// Shutting down the `EventLoop` failed.
    case shutdownFailed
}
