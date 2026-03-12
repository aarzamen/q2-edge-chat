import Foundation
import Combine

// MARK: - Discovered Local File

/// Represents a GGUF file found in the Documents folder that hasn't been imported yet
struct DiscoveredFile: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String
    let fileSize: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

// MARK: - GGUF Validation

enum GGUFValidationError: LocalizedError {
    case notGGUF
    case fileTooSmall
    case invalidMagic
    case readError(String)

    var errorDescription: String? {
        switch self {
        case .notGGUF:
            return "File is not a GGUF model file"
        case .fileTooSmall:
            return "File is too small to be a valid GGUF model (minimum 1MB)"
        case .invalidMagic:
            return "File does not have valid GGUF format header"
        case .readError(let message):
            return "Could not read file: \(message)"
        }
    }
}

// MARK: - Manifest Entry

struct ManifestEntry: Codable, Identifiable {
    let id: String
    let localURL: URL
    let downloadedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, localURL, downloadedAt
    }
    
    init(id: String, localURL: URL, downloadedAt: Date) {
        self.id = id
        self.localURL = localURL
        self.downloadedAt = downloadedAt
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        downloadedAt = try container.decode(Date.self, forKey: .downloadedAt)
        
        let urlString = try container.decode(String.self, forKey: .localURL)
        
        if urlString.hasPrefix("file://") {
            // Full file URL - check if it's an old container path
            if let url = URL(string: urlString) {
                let originalPath = url.path
                if FileManager.default.fileExists(atPath: originalPath) {
                    localURL = url
                } else {
                    // File doesn't exist at old path - try to find it in current container
                    // Extract the relative path from the old absolute path
                    // Example: /var/mobile/.../Library/Models/... -> Models/...
                    if let libraryRange = originalPath.range(of: "/Library/") {
                        let relativePath = String(originalPath[libraryRange.upperBound...])
                        
                        guard let currentLibraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
                            throw DecodingError.dataCorrupted(DecodingError.Context(
                                codingPath: decoder.codingPath,
                                debugDescription: "Unable to access current library directory"
                            ))
                        }
                        
                        let newURL = currentLibraryURL.appendingPathComponent(relativePath)
                        
                        if FileManager.default.fileExists(atPath: newURL.path) {
                            localURL = newURL
                        } else {
                            localURL = url // Keep original URL for error reporting
                        }
                    } else {
                        localURL = url // Keep original URL
                    }
                }
            } else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid file URL: \(urlString)"
                ))
            }
        } else if urlString.hasPrefix("/") {
            // Absolute path - check if it exists or needs migration
            let originalPath = urlString
            
            if FileManager.default.fileExists(atPath: originalPath) {
                localURL = URL(fileURLWithPath: originalPath)
            } else {
                // File doesn't exist at old path - try to find it in current container
                
                // Extract the relative path from the old absolute path
                if let libraryRange = originalPath.range(of: "/Library/") {
                    let relativePath = String(originalPath[libraryRange.upperBound...])
                    
                    guard let currentLibraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
                        throw DecodingError.dataCorrupted(DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "Unable to access current library directory"
                        ))
                    }
                    
                    let newURL = currentLibraryURL.appendingPathComponent(relativePath)
                    
                    if FileManager.default.fileExists(atPath: newURL.path) {
                        localURL = newURL
                    } else {
                        // Try to find the model file in any simulator container
                        if let foundPath = Self.findModelInSimulator(filename: URL(fileURLWithPath: originalPath).lastPathComponent) {
                            localURL = foundPath
                        } else {
                            localURL = URL(fileURLWithPath: originalPath) // Keep original for error reporting
                        }
                    }
                } else {
                    localURL = URL(fileURLWithPath: originalPath) // Keep original
                }
            }
        } else {
            // Relative path - convert to absolute using Library directory
            guard let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unable to access library directory"
                ))
            }
            localURL = libraryURL.appendingPathComponent(urlString)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(downloadedAt, forKey: .downloadedAt)
        // Always store absolute path
        try container.encode(localURL.path, forKey: .localURL)
    }
    
    private static func findModelInSimulator(filename: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let simulatorBasePaths = [
            "\(home)/Library/Developer/CoreSimulator/Devices",
            "\(home)/Library/Developer/Xcode/UserData/Previews/Simulator Devices"
        ]
        
        for basePath in simulatorBasePaths {
            do {
                let deviceDirs = try FileManager.default.contentsOfDirectory(atPath: basePath)
                for deviceID in deviceDirs {
                    let appsPath = "\(basePath)/\(deviceID)/data/Containers/Data/Application"
                    if FileManager.default.fileExists(atPath: appsPath) {
                        let appDirs = try FileManager.default.contentsOfDirectory(atPath: appsPath)
                        for appID in appDirs {
                            let modelsPath = "\(appsPath)/\(appID)/Library/Models"
                            if let foundURL = Self.searchForModel(in: modelsPath, filename: filename) {
                                return foundURL
                            }
                        }
                    }
                }
            } catch {
                continue
            }
        }
        return nil
    }
    
    private static func searchForModel(in directory: String, filename: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return nil }
        
        while let file = enumerator.nextObject() as? String {
            if file.hasSuffix(filename) {
                let fullPath = "\(directory)/\(file)"
                if FileManager.default.fileExists(atPath: fullPath) {
                    return URL(fileURLWithPath: fullPath)
                }
            }
        }
        return nil
    }
}

actor ManifestStore {
    /// Shared singleton — all callers must use this to avoid stale in-memory state
    static let shared: ManifestStore = {
        do {
            return try ManifestStore()
        } catch {
            fatalError("Failed to initialize ManifestStore: \(error.localizedDescription)")
        }
    }()

    private let fileURL: URL
    private var entries: [ManifestEntry] = []
    nonisolated let didChange = PassthroughSubject<Void, Never>() 

    private init() throws {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        fileURL = support.appendingPathComponent("models.json")
        if fm.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode([ManifestEntry].self, from: data)
        }
    }

    func all() -> [ManifestEntry] { entries }

    func add(_ entry: ManifestEntry) throws {
        entries.append(entry)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
        didChange.send()
    }

    func remove(id: String) throws {
        entries.removeAll { $0.id == id }
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
        didChange.send()                                   
    }
    
    /// Import a local GGUF file from anywhere on the Mac
    func importLocalModel(from sourceURL: URL, modelID: String) throws {
        let fm = FileManager.default
        
        // Create Models directory in Library if it doesn't exist
        guard let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "ManifestStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not access Library directory"])
        }
        
        let modelsDir = libraryURL.appendingPathComponent("Models", isDirectory: true)
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        
        // Copy the file to the Models directory
        let filename = sourceURL.lastPathComponent
        let destinationURL = modelsDir.appendingPathComponent(filename)
        
        // Check if file already exists
        if fm.fileExists(atPath: destinationURL.path) {
            // If it exists, use it directly without copying
            let entry = ManifestEntry(
                id: modelID,
                localURL: destinationURL,
                downloadedAt: Date()
            )
            try add(entry)
            return
        }
        
        // Copy the file
        try fm.copyItem(at: sourceURL, to: destinationURL)
        
        // Create manifest entry
        let entry = ManifestEntry(
            id: modelID,
            localURL: destinationURL,
            downloadedAt: Date()
        )
        
        try add(entry)
    }
    
    /// Check if a model with this ID already exists
    func exists(id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    /// Validate all manifest entries and remove those with missing files
    /// Returns the IDs of removed entries
    @discardableResult
    func validateAndCleanup() throws -> [String] {
        let fm = FileManager.default
        var removedIDs: [String] = []

        let validEntries = entries.filter { entry in
            let exists = fm.fileExists(atPath: entry.localURL.path)
            if !exists {
                removedIDs.append(entry.id)
                print("⚠️ Removing invalid manifest entry: \(entry.id) - file not found at \(entry.localURL.path)")
            }
            return exists
        }

        if removedIDs.count > 0 {
            entries = validEntries
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            didChange.send()
        }

        return removedIDs
    }

    /// Check if a specific model file exists on disk
    func modelFileExists(id: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return false
        }
        return FileManager.default.fileExists(atPath: entry.localURL.path)
    }

    // MARK: - Local File Discovery

    /// Scan the Documents folder for GGUF files that haven't been imported yet
    nonisolated func discoverLocalGGUFFiles() -> [DiscoveredFile] {
        let fm = FileManager.default

        guard let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }

        do {
            let contents = try fm.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            return contents.compactMap { url -> DiscoveredFile? in
                // Only include .gguf files
                guard url.pathExtension.lowercased() == "gguf" else { return nil }

                // Get file size
                guard let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      resourceValues.isRegularFile == true,
                      let fileSize = resourceValues.fileSize else {
                    return nil
                }

                return DiscoveredFile(
                    url: url,
                    filename: url.lastPathComponent,
                    fileSize: Int64(fileSize)
                )
            }
        } catch {
            print("Error scanning Documents folder: \(error)")
            return []
        }
    }

    // MARK: - GGUF Validation

    /// Validate that a file is a valid GGUF model file
    nonisolated func validateGGUFFile(at url: URL) throws {
        let fm = FileManager.default

        // Check file exists and get size
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            throw GGUFValidationError.readError("Could not read file attributes")
        }

        // Minimum size check (1MB)
        guard size > 1_000_000 else {
            throw GGUFValidationError.fileTooSmall
        }

        // Check GGUF magic bytes: 0x46554747 = "GGUF" in little-endian
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            guard let data = try handle.read(upToCount: 4), data.count == 4 else {
                throw GGUFValidationError.readError("Could not read file header")
            }

            let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            guard magic == 0x46554747 else {
                throw GGUFValidationError.invalidMagic
            }
        } catch let error as GGUFValidationError {
            throw error
        } catch {
            throw GGUFValidationError.readError(error.localizedDescription)
        }
    }

    // MARK: - Import with Progress

    /// Import a local GGUF file with progress tracking
    func importDiscoveredFile(
        _ file: DiscoveredFile,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ManifestEntry {
        // Validate the file first
        try validateGGUFFile(at: file.url)

        let fm = FileManager.default

        // Create Models directory in Library
        guard let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "ManifestStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not access Library directory"])
        }

        // Generate model ID from filename (remove .gguf extension)
        let baseName = file.filename.replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
        let modelID = "local/\(baseName)"

        // Sanitize the model ID for use as a directory name
        let sanitizedID = modelID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        let modelsDir = libraryURL.appendingPathComponent("Models", isDirectory: true)
        let modelDir = modelsDir.appendingPathComponent(sanitizedID, isDirectory: true)

        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let destinationURL = modelDir.appendingPathComponent(file.filename)

        // Check if file already exists at destination
        if fm.fileExists(atPath: destinationURL.path) {
            // File already exists, just create the manifest entry
            let entry = ManifestEntry(
                id: modelID,
                localURL: destinationURL,
                downloadedAt: Date()
            )
            try add(entry)
            return entry
        }

        // Copy file with progress tracking
        try await copyFileWithProgress(
            from: file.url,
            to: destinationURL,
            totalSize: file.fileSize,
            progress: progress
        )

        // Create manifest entry
        let entry = ManifestEntry(
            id: modelID,
            localURL: destinationURL,
            downloadedAt: Date()
        )
        try add(entry)

        return entry
    }

    /// Import a file from document picker (security-scoped URL)
    func importFromDocumentPicker(
        url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ManifestEntry {
        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "ManifestStore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not access file. Please try selecting it again."])
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // Get file size
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            throw GGUFValidationError.readError("Could not read file attributes")
        }

        let discoveredFile = DiscoveredFile(
            url: url,
            filename: url.lastPathComponent,
            fileSize: size
        )

        return try await importDiscoveredFile(discoveredFile, progress: progress)
    }

    // MARK: - File Copy with Progress

    private func copyFileWithProgress(
        from sourceURL: URL,
        to destinationURL: URL,
        totalSize: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
                    defer { try? sourceHandle.close() }

                    FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
                    let destinationHandle = try FileHandle(forWritingTo: destinationURL)
                    defer { try? destinationHandle.close() }

                    let bufferSize = 1024 * 1024 // 1MB chunks
                    var bytesWritten: Int64 = 0

                    while true {
                        autoreleasepool {
                            guard let data = try? sourceHandle.read(upToCount: bufferSize),
                                  !data.isEmpty else {
                                return
                            }

                            try? destinationHandle.write(contentsOf: data)
                            bytesWritten += Int64(data.count)

                            let progressValue = Double(bytesWritten) / Double(totalSize)
                            DispatchQueue.main.async {
                                progress(min(progressValue, 1.0))
                            }
                        }

                        // Check if we've read all bytes
                        if bytesWritten >= totalSize {
                            break
                        }
                    }

                    continuation.resume()
                } catch {
                    // Clean up partial file on error
                    try? FileManager.default.removeItem(at: destinationURL)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
