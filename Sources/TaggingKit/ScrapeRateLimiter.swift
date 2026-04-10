import Foundation

/// Phase 3: politeness layer in front of every YouTube scrape.
///
/// Three concerns this addresses:
///
/// 1. **Burst prevention.** Watch refresh + the auto-load-on-first-visit path
///    can fire many channel scrapes back-to-back. The minimum interval below
///    spreads them out so the request pattern looks less like an automated
///    tool to YouTube's behavioral detection.
///
/// 2. **Failure backoff.** When a scrape fails with a pattern that matches
///    YouTube actively rejecting us (HTTP 429, captcha challenge, sign-in
///    challenge, 403), we set a sticky global cooldown so every subsequent
///    scrape waits. Hammering through a block makes things worse.
///
/// 3. **Per-channel cooldown.** A failure on one channel suggests something
///    specific to that channel (broken redirect, region lock, deleted feed).
///    No point retrying it for several minutes.
///
/// The limiter is implemented as an actor so all callers serialize through it.
/// `waitForSlot(channelId:)` is the single entry point — call it before every
/// scrape attempt. After the attempt, call `recordSuccess` or `recordFailure`
/// so the limiter can update its state.
public actor ScrapeRateLimiter {
    public static let shared = ScrapeRateLimiter()

    /// Base interval between any two scrape attempts across the whole app.
    /// 2 seconds is conservative for a personal app — scrapetube and YouTube's
    /// own RSS feeds can sustain much higher rates, but we err polite. The
    /// actual interval per call is `baseInterval + random(0...jitterRange)`,
    /// so the pattern looks less mechanical to behavioral detection.
    private let baseIntervalSeconds: Double = 2.0

    /// Maximum random jitter added on top of the base interval. Each slot
    /// claim picks a fresh random offset in `0..<jitterRangeSeconds`, so the
    /// effective interval is uniformly distributed in `[base, base+jitter)`.
    /// 1.0s gives an average actual interval of 2.5s with a 2.0–3.0s range.
    private let jitterRangeSeconds: Double = 1.0

    /// Cooldown applied to the GLOBAL channel after a blocking-pattern failure
    /// (HTTP 429, captcha, forbidden, sign-in challenge). During this window,
    /// every scrape attempt waits until the cooldown elapses.
    private let blockedGlobalCooldownSeconds: Double = 300 // 5 minutes

    /// Cooldown applied to a SINGLE channel after any failure on that channel.
    /// Doesn't block other channels — just prevents pointless retries on the
    /// one that's broken.
    private let perChannelFailureCooldownSeconds: Double = 600 // 10 minutes

    /// When the next scrape slot opens. Computed at slot-claim time as
    /// `now + base + random(jitter)` so each interval is independently
    /// jittered. nil means "no recent scrape, next call can return immediately."
    private var nextSlotAt: Date?
    private var globalCooldownUntil: Date?
    private var channelCooldowns: [String: Date] = [:]

    public init() {}

    /// Wait until a scrape slot is available for the given channel. Honors the
    /// per-channel cooldown, the global blocked cooldown, and the jittered
    /// minimum interval. Returns when it's safe to proceed.
    public func waitForSlot(channelId: String? = nil) async {
        // Loop until ALL three gates pass — each sleep can be interrupted by
        // a new failure being recorded, so we re-check after every wake.
        while true {
            let now = Date()

            // Gate 1: per-channel cooldown
            if let channelId, let until = channelCooldowns[channelId], until > now {
                let delay = until.timeIntervalSince(now)
                try? await Task.sleep(for: .seconds(delay))
                continue
            }

            // Gate 2: global blocked cooldown
            if let until = globalCooldownUntil, until > now {
                let delay = until.timeIntervalSince(now)
                try? await Task.sleep(for: .seconds(delay))
                continue
            }

            // Gate 3: jittered minimum interval since the last slot opened
            if let next = nextSlotAt, next > now {
                let delay = next.timeIntervalSince(now)
                try? await Task.sleep(for: .seconds(delay))
                continue
            }

            // All gates pass — claim the slot and schedule the next one with
            // a fresh random jitter offset. Each slot independently rolls a
            // jitter value in [0, jitterRange), so the actual interval is
            // uniformly distributed in [base, base+jitter).
            let jitter = Double.random(in: 0..<jitterRangeSeconds)
            nextSlotAt = Date().addingTimeInterval(baseIntervalSeconds + jitter)
            return
        }
    }

    /// Record a successful scrape. Clears the per-channel cooldown for that
    /// channel. Does NOT clear the global cooldown — let it expire naturally,
    /// since one success doesn't mean the block is gone.
    public func recordSuccess(channelId: String? = nil) {
        if let channelId {
            channelCooldowns.removeValue(forKey: channelId)
        }
    }

    /// Record a failed scrape. The reason string (typically the error's
    /// localizedDescription) is pattern-matched to decide whether to set the
    /// global blocked cooldown. The per-channel cooldown is set unconditionally.
    public func recordFailure(channelId: String? = nil, reason: String) {
        let lower = reason.lowercased()
        let isBlocked = lower.contains("429")
            || lower.contains("too many requests")
            || lower.contains("captcha")
            || lower.contains("sign in to confirm")
            || lower.contains("err_blocked")
            || lower.contains("forbidden")
            || lower.contains("403")

        let now = Date()
        if let channelId {
            channelCooldowns[channelId] = now.addingTimeInterval(perChannelFailureCooldownSeconds)
        }
        if isBlocked {
            globalCooldownUntil = now.addingTimeInterval(blockedGlobalCooldownSeconds)
        }
    }

    /// Read-only snapshot of the current cooldown state. Used by the UI to
    /// surface "scrape paused for X minutes" feedback.
    public func currentCooldownState() -> (globalUntil: Date?, channelCount: Int) {
        let now = Date()
        let activeChannels = channelCooldowns.values.filter { $0 > now }.count
        let activeGlobal = (globalCooldownUntil ?? .distantPast) > now ? globalCooldownUntil : nil
        return (activeGlobal, activeChannels)
    }

    /// Manual reset, for testing or for a future "Resume scraping now" button.
    public func clearAllCooldowns() {
        globalCooldownUntil = nil
        channelCooldowns.removeAll()
    }
}
