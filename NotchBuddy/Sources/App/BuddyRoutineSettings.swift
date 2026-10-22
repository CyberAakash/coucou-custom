import Foundation
import Combine

// coucou-custom fork: Settings → Buddy → Assistant & routines, stored in UserDefaults (reminders
// included: they are what you asked to be reminded of, nothing secret).

@MainActor
final class BuddyRoutineSettings: ObservableObject {
    static let shared = BuddyRoutineSettings()

    static let toolsKey = "buddyAssistantTools"
    static let focusPlanKey = "buddyFocusPlan"
    static let waterKey = "buddyWaterEnabled"
    static let waterIntervalKey = "buddyWaterInterval"   // before the plan: its `every`
    static let waterPlanKey = "buddyWaterPlan"
    static let waterLogKey = "buddyWaterLog"
    static let greetingKey = "buddyLaunchGreeting"
    static let greetingSoundKey = "buddyLaunchGreetingSound"
    static let alertSoundKey = "buddyAlertSound"
    static let remindersKey = "buddyReminders"
    static let breathingCuesKey = "buddyBreathingCues"
    static let lastBreathingKey = "buddyLastBreathing"
    static let breathingFullKey = "buddyBreathingFullScreen"

    private let defaults: UserDefaults

    /// The notch chat can act through the Buddy's tools (reminders, focus, timers…).
    @Published var assistantTools: Bool { didSet { defaults.set(assistantTools, forKey: Self.toolsKey) } }
    @Published var focusPlan: BuddyFocusPlan {
        didSet { defaults.set(try? JSONEncoder().encode(focusPlan), forKey: Self.focusPlanKey) }
    }
    @Published var waterEnabled: Bool { didSet { defaults.set(waterEnabled, forKey: Self.waterKey) } }
    /// When and how much: interval, hours, days, goal, glass.
    @Published var waterPlan: BuddyWaterPlan {
        didSet {
            var p = waterPlan
            p.every = min(max(p.every, 10), 240)
            p.goal = min(max(p.goal, 250), 6000)
            p.glass = min(max(p.glass, 50), 1500)
            p.from = min(max(p.from, 0), 24 * 60 - 1)
            p.to = min(max(p.to, 0), 24 * 60 - 1)
            if p != waterPlan { waterPlan = p; return }
            defaults.set(try? JSONEncoder().encode(waterPlan), forKey: Self.waterPlanKey)
        }
    }
    /// What you drank, per day.
    @Published var waterLog: BuddyWaterLog {
        didSet { defaults.set(try? JSONEncoder().encode(waterLog), forKey: Self.waterLogKey) }
    }
    /// Launch Buddy: it greets you when Coucou starts.
    @Published var launchGreeting: Bool { didSet { defaults.set(launchGreeting, forKey: Self.greetingKey) } }
    @Published var launchGreetingSound: Bool { didSet { defaults.set(launchGreetingSound, forKey: Self.greetingSoundKey) } }
    /// Due reminders, timers and the end of a focus session or break play a sound.
    @Published var alertSound: Bool { didSet { defaults.set(alertSound, forKey: Self.alertSoundKey) } }
    /// A soft sound at each breath in and out.
    @Published var breathingCues: Bool { didSet { defaults.set(breathingCues, forKey: Self.breathingCuesKey) } }
    /// Breathing opens full screen: the Buddy walks to the middle and the screen dims.
    @Published var breathingFullScreen: Bool { didSet { defaults.set(breathingFullScreen, forKey: Self.breathingFullKey) } }
    /// The pattern the calm panel opens on.
    @Published var lastBreathing: BuddyBreathing { didSet { defaults.set(lastBreathing.rawValue, forKey: Self.lastBreathingKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, default value: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
        }
        assistantTools = bool(Self.toolsKey, default: true)
        focusPlan = defaults.data(forKey: Self.focusPlanKey)
            .flatMap { try? JSONDecoder().decode(BuddyFocusPlan.self, from: $0) } ?? .standard
        waterEnabled = bool(Self.waterKey, default: false)
        var plan = defaults.data(forKey: Self.waterPlanKey)
            .flatMap { try? JSONDecoder().decode(BuddyWaterPlan.self, from: $0) } ?? .standard
        if defaults.data(forKey: Self.waterPlanKey) == nil, defaults.integer(forKey: Self.waterIntervalKey) > 0 {
            plan.every = min(max(defaults.integer(forKey: Self.waterIntervalKey), 10), 240)
        }
        waterPlan = plan
        waterLog = defaults.data(forKey: Self.waterLogKey)
            .flatMap { try? JSONDecoder().decode(BuddyWaterLog.self, from: $0) } ?? BuddyWaterLog()
        launchGreeting = bool(Self.greetingKey, default: true)
        launchGreetingSound = bool(Self.greetingSoundKey, default: false)
        alertSound = bool(Self.alertSoundKey, default: true)
        breathingCues = bool(Self.breathingCuesKey, default: true)
        breathingFullScreen = bool(Self.breathingFullKey, default: true)
        lastBreathing = defaults.string(forKey: Self.lastBreathingKey).flatMap(BuddyBreathing.init(rawValue:)) ?? .calm
    }

    var reminders: [BuddyReminder] {
        get { defaults.data(forKey: Self.remindersKey).flatMap(BuddyReminders.decode) ?? [] }
        set { defaults.set(BuddyReminders.encode(newValue), forKey: Self.remindersKey) }
    }
}
