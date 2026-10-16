import AudioToolbox
import Foundation

/// The sounds for what starts to wait on you while the app is open (the core's `sounds`), made by
/// scripts/make-sounds.swift. They play as system sounds: at the ringer's volume, not at all with
/// the phone silenced, and over music without stopping it.
enum Sounds {
    /// Where the Macs sheet keeps whether each kind sounds; both are on until you turn one off.
    static let needsYouKey = "sound.needsYou"
    static let yourTurnKey = "sound.yourTurn"

    /// The kinds that are on.
    static var on: [Sound] {
        let defaults = UserDefaults.standard
        return [(Sound.needsYou, needsYouKey), (.yourTurn, yourTurnKey)].filter { defaults.object(forKey: $0.1) as? Bool ?? true }.map(\.0)
    }

    static func play(_ sound: Sound) {
        let id = switch sound {
        case .needsYou: needsYou
        case .yourTurn: yourTurn
        }
        if let id { AudioServicesPlaySystemSound(id) }
    }

    private static let needsYou = load("needs-you")
    private static let yourTurn = load("your-turn")

    private static func load(_ name: String) -> SystemSoundID? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return nil }
        var id: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError ? id : nil
    }
}
