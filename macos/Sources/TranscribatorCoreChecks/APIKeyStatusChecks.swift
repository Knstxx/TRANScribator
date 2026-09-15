import Foundation
import TranscribatorCore

enum APIKeyStatusChecks {
    static func run() throws {
        let audio = RecordingAudioStatus(includesMicrophone: true, microphoneVolume: 1, systemAudioVolume: 1)
        let found = APIKeyStatus.checkPresence { true }
        let missing = APIKeyStatus.checkPresence { false }
        let fixtureError = NSError(domain: "offline-keychain", code: -25308,
                                   userInfo: [NSLocalizedDescriptionKey: "fixture-secret-do-not-display"])
        let unavailable = APIKeyStatus.checkPresence { throw fixtureError }
        try require(found == .available && found.hasSavedKey, "A saved key must remain usable after a successful presence lookup")
        try require(missing == .missing && !missing.hasSavedKey, "Only a negative presence lookup can report a missing key")
        try require(unavailable == .unavailable && !unavailable.hasSavedKey,
                    "A failed Keychain lookup must not be treated as a missing item")
        try require(unavailable.authorizationRequiredMessage != missing.authorizationRequiredMessage,
                    "Keychain errors must not ask the user to add the existing key again")
        try require(!unavailable.statusText.contains("fixture-secret") && !String(reflecting: unavailable).contains("fixture-secret"),
                    "Keychain diagnostics must never retain raw error details")
        let checking = AppStatus(phase: .idle, audio: audio,
                                 authorizationRequiredMessage: APIKeyStatus.checking.authorizationRequiredMessage)
        try require(checking.statusText != missing.authorizationRequiredMessage,
                    "A pending presence lookup must not report that the key is missing")
        for status in [APIKeyStatus.checking, found, missing, unavailable] {
            let recording = AppStatus(phase: .recording, audio: audio,
                                      authorizationRequiredMessage: status.authorizationRequiredMessage)
            try require(recording.statusText == audio.recordingText,
                        "Keychain presence must never hide an ongoing recording")
        }
        // A later successful lookup replaces an earlier failure; errors never
        // become a permanent negative cache or a request to modify credentials.
        let recovered = APIKeyStatus.checkPresence { true }
        try require(recovered == .available && recovered.authorizationRequiredMessage == nil,
                    "A successful recheck must restore readiness without saving a new key")
    }
}
