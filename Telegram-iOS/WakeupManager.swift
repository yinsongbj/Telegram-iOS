import Foundation
import TelegramCore
import SwiftSignalKit
import UIKit
import Postbox
import UserNotifications
import TelegramUI

private final class WakeupManagerTask {
    let nativeId: UIBackgroundTaskIdentifier
    let id: Int32
    let timer: SwiftSignalKit.Timer

    init(nativeId: UIBackgroundTaskIdentifier, id: Int32, timer: SwiftSignalKit.Timer) {
        self.nativeId = nativeId
        self.id = id
        self.timer = timer
    }
    
    deinit {
        assert(Queue.mainQueue().isCurrent())
        self.timer.invalidate()
    }
}

private final class WakeupManagerState {
    var nextTaskId: Int32 = 0
    var currentTask: WakeupManagerTask?
    var currentServiceTask: WakeupManagerTask?
}

private struct CombinedRunningImportantTasks: Equatable {
    let serviceTasks: AccountRunningImportantTasks
    let backgroundLocation: Bool
    let watchTasks: WatchRunningTasks?
    
    var isEmpty: Bool {
        var hasWatchTask = false
        if let watchTasks = self.watchTasks {
            hasWatchTask = watchTasks.running
        }
        return self.serviceTasks.isEmpty && !self.backgroundLocation && !hasWatchTask
    }
    
    static func ==(lhs: CombinedRunningImportantTasks, rhs: CombinedRunningImportantTasks) -> Bool {
        return lhs.serviceTasks == rhs.serviceTasks && lhs.backgroundLocation == rhs.backgroundLocation && lhs.watchTasks == rhs.watchTasks
    }
}

final class WakeupManager {
    private var state = WakeupManagerState()
    
    var account: Account? {
        didSet {
            assert(Queue.mainQueue().isCurrent())
        }
    }
    
    private let isProcessingNotificationsValue = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let isProcessingServiceTasksValue = ValuePromise<Bool>(false, ignoreRepeated: true)
    var isWokenUp: Signal<Bool, NoError> {
        return combineLatest([self.isProcessingNotificationsValue.get(), isProcessingServiceTasksValue.get()])
            |> map { values -> Bool in
                for value in values {
                    if value {
                        return true
                    }
                }
                return false
            }
    }
    
    private var inForegroundDisposable: Disposable?
    private var runningServiceTasksDisposable: Disposable?
    private var runningServiceTasksValue: CombinedRunningImportantTasks = CombinedRunningImportantTasks(serviceTasks: [], backgroundLocation: false, watchTasks: nil)
    private let wakeupDisposable = MetaDisposable()
    
    private var wakeupResultSubscribers: [(Int32, ([MessageId]) -> Signal<Void, NoError>)] = []
    
    init(inForeground: Signal<Bool, NoError>, runningServiceTasks: Signal<AccountRunningImportantTasks, NoError>, runningBackgroundLocationTasks: Signal<Bool, NoError>, runningWatchTasks: Signal<WatchRunningTasks?, NoError>) {
        self.inForegroundDisposable = (inForeground |> distinctUntilChanged |> deliverOnMainQueue).start(next: { [weak self] value in
            if let strongSelf = self {
                if value {
                    if let currentTask = strongSelf.state.currentTask {
                        strongSelf.state.currentTask = nil
                        Logger.shared.log("WakeupManager", "ending task #\(currentTask.id) (entered foreground)")
                        currentTask.timer.invalidate()
                        strongSelf.wakeupDisposable.set(nil)
                        strongSelf.isProcessingNotificationsValue.set(false)
                        UIApplication.shared.endBackgroundTask(currentTask.nativeId)
                    }
                }
            }
        })
        self.runningServiceTasksDisposable = (combineLatest(inForeground, runningServiceTasks, runningBackgroundLocationTasks, runningWatchTasks)
            |> map { inForeground, runningServiceTasks, runningBackgroundLocationTasks, runningWatchTasks -> CombinedRunningImportantTasks in
                let combinedTasks = CombinedRunningImportantTasks(serviceTasks: runningServiceTasks, backgroundLocation: runningBackgroundLocationTasks, watchTasks: runningWatchTasks)
                if !inForeground && !combinedTasks.isEmpty {
                    return combinedTasks
                } else {
                    return CombinedRunningImportantTasks(serviceTasks: [], backgroundLocation: false, watchTasks: nil)
                }
            }
            |> distinctUntilChanged
            |> deliverOnMainQueue).start(next: { [weak self] value in
            if let strongSelf = self {
                strongSelf.runningServiceTasksValue = value
                if !value.isEmpty {
                    //assert(strongSelf.state.currentServiceTask == nil)
                    strongSelf.wakeupForServiceTasks(timeout: value.serviceTasks.contains(.pendingMessages) ? 85.0 : 25.0)
                } else if let currentServiceTask = strongSelf.state.currentServiceTask {
                    strongSelf.state.currentServiceTask = nil
                    Logger.shared.log("WakeupManager", "ending service task #\(currentServiceTask.id)")
                    currentServiceTask.timer.invalidate()
                    strongSelf.isProcessingServiceTasksValue.set(false)
                    
                    Queue.mainQueue().after(2.0, {
                        UIApplication.shared.endBackgroundTask(currentServiceTask.nativeId)
                    })
                }
            }
        })
    }
    
    deinit {
        self.inForegroundDisposable?.dispose()
        self.wakeupDisposable.dispose()
    }
    
    private func reportCompletionToSubscribersAndGetUnreadCount(maxId: Int32, messageIds: [MessageId]) -> Signal<Int32?, NoError> {
        var collectedSignals: [Signal<Void, NoError>] = []
        while !self.wakeupResultSubscribers.isEmpty {
            let first = self.wakeupResultSubscribers[0]
            if first.0 <= maxId {
                self.wakeupResultSubscribers.remove(at: 0)
                collectedSignals.append(first.1(messageIds))
            }
        }
        return combineLatest(collectedSignals)
            |> map { _ -> Void in
                return Void()
            } |> mapToSignal { [weak self] _ -> Signal<Int32?, NoError> in
                if let strongSelf = self, let account = strongSelf.account, !messageIds.isEmpty {
                    return account.postbox.transaction { transaction -> Int32? in
                        let (unreadCount, _) = renderedTotalUnreadCount(transaction: transaction)
                        return unreadCount
                    }
                } else {
                    return .single(nil)
                }
            }
    }
    
    private func wakeupForServiceTasks(timeout: Double = 25.0) {
        assert(Queue.mainQueue().isCurrent())
        
        var endTask: WakeupManagerTask?
        let updatedId: Int32 = self.state.nextTaskId
        self.state.nextTaskId += 1
        
        let handleExpiration: (Bool) -> Void = { [weak self] byTimer in
            Queue.mainQueue().async {
                if let strongSelf = self {
                    if let currentServiceTask = strongSelf.state.currentServiceTask {
                        if currentServiceTask.id == updatedId {
                            if byTimer && strongSelf.runningServiceTasksValue.serviceTasks.contains(.pendingMessages) {
                                /*if #available(iOS 10.0, *) {
                                    let content = UNMutableNotificationContent()
                                    content.body = "Please open the app to continue sending messages"
                                    content.sound = UNNotificationSound.default()
                                    content.categoryIdentifier = "error"
                                 
                                    let request = UNNotificationRequest(identifier: "reply-error", content: content, trigger: nil)
                                 
                                    let center = UNUserNotificationCenter.current()
                                    center.add(request)
                                }*/
                            }
                            
                            Logger.shared.log("WakeupManager", "handleExpiration(by timer: \(byTimer)) invoked, ending service task #\(currentServiceTask.id)")
                            strongSelf.state.currentServiceTask = nil
                            currentServiceTask.timer.invalidate()
                            strongSelf.isProcessingServiceTasksValue.set(false)
                            UIApplication.shared.endBackgroundTask(currentServiceTask.nativeId)
                        } else {
                            Logger.shared.log("WakeupManager", "handleExpiration(by timer: \(byTimer)) invoked, current service task doesn't match")
                        }
                    } else {
                        Logger.shared.log("WakeupManager", "handleExpiration(by timer: \(byTimer)) invoked, no current service task")
                    }
                }
            }
        }
        
        let updatedNativeId = UIApplication.shared.beginBackgroundTask(withName: "service", expirationHandler: {
            handleExpiration(false)
        })
        Logger.shared.log("WakeupManager", "started service task #\(updatedId)")
        let updatedTimer = SwiftSignalKit.Timer(timeout: timeout, repeat: false, completion: {
            handleExpiration(true)
        }, queue: Queue.mainQueue())
        let updatedTask = WakeupManagerTask(nativeId: updatedNativeId, id: updatedId, timer: updatedTimer)
        
        if let currentServiceTask = self.state.currentServiceTask {
            endTask = currentServiceTask
        }
        self.state.currentServiceTask = updatedTask
        self.isProcessingServiceTasksValue.set(true)
        
        updatedTimer.start()
        
        if let endTask = endTask {
            Logger.shared.log("WakeupManager", "ending service task #\(endTask.id) (replaced by #\(updatedTask.id))")
            endTask.timer.invalidate()
            UIApplication.shared.endBackgroundTask(endTask.nativeId)
        }
    }
    
    func wakeupForIncomingMessages(timeout: Double = 25.0, completion: (([MessageId]) -> Signal<Void, NoError>)? = nil) {
        assert(Queue.mainQueue().isCurrent())
        guard let account = self.account else {
            return
        }
        
        var endTask: WakeupManagerTask?
        let updatedId: Int32 = self.state.nextTaskId
        self.state.nextTaskId += 1
        
        if let completion = completion {
            self.wakeupResultSubscribers.append((updatedId, completion))
        }
        
        let handleExpiration: (Bool) -> Void = { [weak self] byTimer in
            if let strongSelf = self {
                if let currentTask = strongSelf.state.currentTask {
                    if currentTask.id == updatedId {
                        Logger.shared.log("WakeupManager", "handleExpiration(by timer: \(byTimer)) invoked, ending task #\(currentTask.id)")
                        strongSelf.state.currentTask = nil
                        currentTask.timer.invalidate()
                        strongSelf.isProcessingNotificationsValue.set(false)
                        let _ = strongSelf.reportCompletionToSubscribersAndGetUnreadCount(maxId: updatedId, messageIds: []).start()
                        UIApplication.shared.endBackgroundTask(currentTask.nativeId)
                    } else {
                        Logger.shared.log("WakeupManager", "handleExpiration(by timer: \(byTimer)) invoked, current task doesn't match")
                    }
                } else {
                    Logger.shared.log("WakeupManager", "handleExpiration(by timer: \(byTimer)) invoked, no current task")
                }
            }
        }
        
        let updatedNativeId = UIApplication.shared.beginBackgroundTask(withName: "wakeup", expirationHandler: {
            handleExpiration(false)
        })
        Logger.shared.log("WakeupManager", "started task #\(updatedId)")
        let updatedTimer = SwiftSignalKit.Timer(timeout: timeout, repeat: false, completion: {
            handleExpiration(true)
        }, queue: Queue.mainQueue())
        let updatedTask = WakeupManagerTask(nativeId: updatedNativeId, id: updatedId, timer: updatedTimer)
        
        if let currentTask = self.state.currentTask {
            endTask = currentTask
        }
        self.state.currentTask = updatedTask
        self.isProcessingNotificationsValue.set(true)
        
        updatedTimer.start()
        
        if let endTask = endTask {
            Logger.shared.log("WakeupManager", "ending task #\(endTask.id) (replaced by #\(updatedTask.id))")
            endTask.timer.invalidate()
            UIApplication.shared.endBackgroundTask(endTask.nativeId)
        }
        
        self.wakeupDisposable.set((account.stateManager.pollStateUpdateCompletion() |> deliverOnMainQueue |> mapToSignal { [weak self] messageIds -> Signal<Int32?, NoError> in
            if let strongSelf = self {
                Logger.shared.log("WakeupManager", "pollStateUpdateCompletion messageIds: \(messageIds)")
                return strongSelf.reportCompletionToSubscribersAndGetUnreadCount(maxId: updatedId, messageIds: messageIds)
            } else {
                return .complete()
            }
        } |> deliverOnMainQueue).start(next: { [weak self] maybeUnreadCount in
            if let strongSelf = self {
                if let maybeUnreadCount = maybeUnreadCount {
                    if UIApplication.shared.applicationIconBadgeNumber != Int(maybeUnreadCount) {
                        UIApplication.shared.applicationIconBadgeNumber = Int(maybeUnreadCount)
                    }
                }
                if let currentTask = strongSelf.state.currentTask {
                    if currentTask.id == updatedId {
                        Logger.shared.log("WakeupManager", "account state wakeup completed, ending task #\(currentTask.id)")
                        strongSelf.isProcessingNotificationsValue.set(false)
                        strongSelf.state.currentTask = nil
                        currentTask.timer.invalidate()
                        UIApplication.shared.endBackgroundTask(currentTask.nativeId)
                    } else {
                        Logger.shared.log("WakeupManager", "account state wakeup completed, current task doesn't match")
                    }
                } else {
                    Logger.shared.log("WakeupManager", "account state wakeup completed, no current task")
                }
            }
        }))
    }
}
