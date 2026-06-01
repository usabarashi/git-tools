import FoundationModels

public enum ModelAvailability {
    /// Returns `nil` when the on-device model is ready, or a human-readable
    /// reason (for stderr) when it is not (Q6).
    public static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "this device does not support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is not enabled. Enable it in System Settings > Apple Intelligence & Siri, then wait for the model to finish downloading"
        case .unavailable(.modelNotReady):
            return "the on-device model is not ready yet (it may still be downloading). Try again in a moment"
        case .unavailable(let other):
            return "the on-device language model is unavailable: \(other)"
        }
    }
}
