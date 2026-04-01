import Foundation

/// Loads video items from an inventory JSON snapshot.
public enum InventoryLoader {
    public struct Snapshot: Codable {
        public let total: Int
        public let items: [VideoItem]
        public let capturedAt: String?
    }

    public static func load(from url: URL) throws -> Snapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(Snapshot.self, from: data)
    }

    /// Scan the runs directory and return the most recent inventory.json path.
    public static func findLatestInventory(in runsDirectory: URL) throws -> URL? {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        // Sort by name descending (ISO timestamp prefix = chronological order)
        let sorted = entries.sorted { $0.lastPathComponent > $1.lastPathComponent }

        for dir in sorted {
            let inventoryUrl = dir.appendingPathComponent("inventory.json")
            if fm.fileExists(atPath: inventoryUrl.path) {
                return inventoryUrl
            }
        }

        return nil
    }
}
