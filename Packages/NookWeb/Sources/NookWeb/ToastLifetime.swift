// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// Repeated feedback extends the current presentation, even when its text is unchanged.
@MainActor
public enum ToastLifetime {
    private struct Pending {
        let generation: UUID
        let task: Task<Void, Never>
    }
    private static var pending: [ObjectIdentifier: Pending] = [:]

    public static func restart(for owner: AnyObject, after delay: TimeInterval, dismiss: @escaping @MainActor () -> Void) {
        let key = ObjectIdentifier(owner)
        cancel(for: owner)
        let generation = UUID()
        let task = Task { [weak owner] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, pending[key]?.generation == generation else { return }
            pending[key] = nil
            guard owner != nil else { return }
            dismiss()
        }
        pending[key] = Pending(generation: generation, task: task)
    }

    public static func cancel(for owner: AnyObject) {
        pending.removeValue(forKey: ObjectIdentifier(owner))?.task.cancel()
    }
}
