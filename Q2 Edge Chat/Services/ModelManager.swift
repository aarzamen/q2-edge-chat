import Foundation
import SwiftLlama
import Combine
import os

private let logger = Logger(subsystem: "com.arzamen.q2edgechat", category: "ModelManager")

/// Manages background downloads for model files using URLSession.
class DownloadService: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadService()
    
    @Published var activeDownloads: [String: Double] = [:] // ModelID -> Progress (0.0 - 1.0)
    @Published var completedDownloads: Set<String> = []
    @Published var failedDownloads: [String: String] = [:] // ModelID -> Error Message
    
    private var urlSession: URLSession!
    // Removed fragile in-memory maps in favor of taskDescription + UserDefaults
    
    // Publishers for specific events
    let downloadComplete = PassthroughSubject<(modelId: String, location: URL, filename: String), Never>()
    let downloadError = PassthroughSubject<(modelId: String, error: Error), Never>()
    
    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.arzamen.q2edgechat.backgroundDownload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    /// Starts a download for a given model
    func startDownload(url: URL, modelId: String, filename: String) {
        // Prevent duplicate downloads
        if activeDownloads[modelId] != nil {
            logger.warning("Download already active for \(modelId)")
            return
        }
        
        logger.info("Starting background download for \(modelId) -> \(filename)")
        
        // Persist filename metadata
        UserDefaults.standard.set(filename, forKey: "download_filename_\(modelId)")
        
        let task = urlSession.downloadTask(with: url)
        task.taskDescription = modelId // Robust tracking
        
        DispatchQueue.main.async {
            self.activeDownloads[modelId] = 0.0
            self.failedDownloads.removeValue(forKey: modelId)
        }
        
        task.resume()
    }
    
    /// Checks if a model is currently downloading
    func isDownloading(modelId: String) -> Bool {
        return activeDownloads[modelId] != nil
    }
    
    /// Cancels an active download for a given model
    func cancelDownload(modelId: String) {
        urlSession.getAllTasks { [weak self] tasks in
            for task in tasks where task.taskDescription == modelId {
                task.cancel()
            }
            DispatchQueue.main.async {
                self?.activeDownloads.removeValue(forKey: modelId)
                self?.failedDownloads.removeValue(forKey: modelId)
                UserDefaults.standard.removeObject(forKey: "download_filename_\(modelId)")
            }
        }
    }
    
    /// Configures the session for app relaunch (required for background sessions)
    func restoreSession() {
        // Accessing the session ensures delegate hooks up
        _ = self.urlSession
        
        // Re-populate active downloads from running tasks
        urlSession.getAllTasks { tasks in
            DispatchQueue.main.async {
                for task in tasks {
                    if let modelId = task.taskDescription, task.state == .running {
                        self.activeDownloads[modelId] = 0.0 // Will update on next progress event
                    }
                }
            }
        }
        logger.debug("Session restored")
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let modelId = downloadTask.taskDescription else {
            logger.error("Unknown task finished (no taskDescription)")
            return
        }
        
        // Retrieve persisted filename
        guard let filename = UserDefaults.standard.string(forKey: "download_filename_\(modelId)") else {
            logger.error("Missing filename metadata for \(modelId)")
             DispatchQueue.main.async {
                 self.activeDownloads.removeValue(forKey: modelId)
                 self.failedDownloads[modelId] = "Metadata missing (filename)"
                 self.downloadError.send((modelId: modelId, error: NSError(domain: "DownloadService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing filename metadata"])))
             }
            return
        }
        
        logger.info("Download finished for \(modelId) (\(filename))")
        
        // Move to a temporary location that we can access safely on the main thread/actor
        // The file at `location` is deleted when this method returns.
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(URL(string: filename)?.pathExtension ?? "gguf")
        
        do {
            try FileManager.default.moveItem(at: location, to: tempFile)
            
            // Clean up metadata
            UserDefaults.standard.removeObject(forKey: "download_filename_\(modelId)")
            
            DispatchQueue.main.async {
                self.activeDownloads.removeValue(forKey: modelId)
                self.completedDownloads.insert(modelId)
                self.downloadComplete.send((modelId: modelId, location: tempFile, filename: filename))
            }
        } catch {
            logger.error("Failed to move temp file: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.activeDownloads.removeValue(forKey: modelId)
                self.failedDownloads[modelId] = "Failed to move temp file: \(error.localizedDescription)"
                self.downloadError.send((modelId: modelId, error: error))
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let modelId = downloadTask.taskDescription else { return }
        
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.0
        
        DispatchQueue.main.async {
            self.activeDownloads[modelId] = progress
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let modelId = task.taskDescription else { return }
        
        if let error = error {
            logger.error("Task failed for \(modelId): \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.activeDownloads.removeValue(forKey: modelId)
                self.failedDownloads[modelId] = error.localizedDescription
                self.downloadError.send((modelId: modelId, error: error))
            }
        }
    }
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        logger.debug("All background events finished")
    }
}

struct HFSibling: Codable {
    let rfilename: String
}

struct ModelDetail {
    let model: HFModel
    let readme: String?
    let hasGGUF: Bool
    // Map of quantization label (e.g., "Q4_K_M") to the specific file
    let quantizedFiles: [String: HFSibling]
    let availableQuantizations: [String]
}

struct StaffPickModel {
    let huggingFaceId: String
    let displayName: String
    let description: String
    let parameterCount: String
    let specialty: String
    let category: String
    
    static let staffPicks: [StaffPickModel] = [
        // MARK: - Top Picks (Best Performance)
        StaffPickModel(
            huggingFaceId: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            displayName: "Llama 3.2 3B",
            description: "Meta's latest 3B model with excellent instruction following and reasoning",
            parameterCount: "3.2B",
            specialty: "Best Overall",
            category: "General"
        ),
        StaffPickModel(
            huggingFaceId: "Qwen/Qwen2.5-3B-Instruct-GGUF",
            displayName: "Qwen 2.5 3B",
            description: "Alibaba's powerful multilingual model with 32K context window",
            parameterCount: "3B",
            specialty: "Multilingual",
            category: "General"
        ),
        StaffPickModel(
            huggingFaceId: "bartowski/Phi-3.1-mini-4k-instruct-GGUF",
            displayName: "Phi-3.1 Mini",
            description: "Microsoft's excellent reasoning model, punches above its weight",
            parameterCount: "3.8B",
            specialty: "Reasoning",
            category: "General"
        ),

        // MARK: - Compact Models (Fast & Efficient)
        StaffPickModel(
            huggingFaceId: "bartowski/gemma-2-2b-it-GGUF",
            displayName: "Gemma 2 2B",
            description: "Google's efficient instruction model with strong safety features",
            parameterCount: "2.6B",
            specialty: "Safe AI",
            category: "General"
        ),
        StaffPickModel(
            huggingFaceId: "HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF",
            displayName: "SmolLM2 1.7B",
            description: "HuggingFace's optimized model trained on 11T tokens",
            parameterCount: "1.7B",
            specialty: "Efficient",
            category: "General"
        ),
        StaffPickModel(
            huggingFaceId: "brittlewis12/stablelm-2-zephyr-1_6b-GGUF",
            displayName: "StableLM 2 Zephyr",
            description: "Stability AI's chat-tuned model with balanced performance",
            parameterCount: "1.6B",
            specialty: "Chat",
            category: "General"
        ),

        // MARK: - Ultra-Lightweight (Instant Response)
        StaffPickModel(
            huggingFaceId: "hugging-quants/Llama-3.2-1B-Instruct-Q4_K_M-GGUF",
            displayName: "Llama 3.2 1B",
            description: "Meta's smallest Llama, perfect for quick responses",
            parameterCount: "1.2B",
            specialty: "Lightweight",
            category: "General"
        ),
        StaffPickModel(
            huggingFaceId: "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
            displayName: "TinyLlama 1.1B",
            description: "Ultra-compact model for testing and fast interactions",
            parameterCount: "1.1B",
            specialty: "Ultra-Light",
            category: "General"
        ),

        // MARK: - Coding Models
        StaffPickModel(
            huggingFaceId: "Qwen/Qwen2.5-Coder-3B-Instruct-GGUF",
            displayName: "Qwen 2.5 Coder 3B",
            description: "Best-in-class coding model trained on 5.5T tokens of code",
            parameterCount: "3B",
            specialty: "Code Generation",
            category: "Coding"
        ),
        StaffPickModel(
            huggingFaceId: "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF",
            displayName: "Qwen 2.5 Coder 1.5B",
            description: "Compact coding assistant for quick programming help",
            parameterCount: "1.5B",
            specialty: "Code Generation",
            category: "Coding"
        ),

        // MARK: - Specialized
        StaffPickModel(
            huggingFaceId: "Qwen/Qwen3-4B-GGUF",
            displayName: "Qwen 3 4B",
            description: "Latest Qwen3 with advanced reasoning and 32K context",
            parameterCount: "4B",
            specialty: "Advanced",
            category: "General"
        ),
        StaffPickModel(
            huggingFaceId: "microsoft/Phi-3-mini-4k-instruct-gguf",
            displayName: "Phi-3 Mini",
            description: "Microsoft's proven reasoning model, great for complex tasks",
            parameterCount: "3.8B",
            specialty: "Reasoning",
            category: "General"
        )
    ]
}

struct HFModel: Codable {
    let _id: String?
    let id: String
    let author: String?
    let gated: Bool?
    let lastModified: String?
    let likes: Int?
    let trendingScore: Int?
    let isPrivate: Bool?
    let sha: String?
    let downloads: Int?
    let tags: [String]?
    let pipelineTag: String?
    let libraryName: String?
    let createdAt: String?
    let modelId: String?
    let siblings: [HFSibling]
    
    enum CodingKeys: String, CodingKey {
        case _id, id, author, lastModified, likes, trendingScore, downloads, tags, siblings, createdAt, sha, modelId
        case isPrivate = "private"
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
        case gated
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        _id = try container.decodeIfPresent(String.self, forKey: ._id)
        id = try container.decode(String.self, forKey: .id)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        likes = try container.decodeIfPresent(Int.self, forKey: .likes)
        trendingScore = try container.decodeIfPresent(Int.self, forKey: .trendingScore)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate)
        sha = try container.decodeIfPresent(String.self, forKey: .sha)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        pipelineTag = try container.decodeIfPresent(String.self, forKey: .pipelineTag)
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        siblings = try container.decode([HFSibling].self, forKey: .siblings)
        
        // Handle gated field that can be either Bool or String
        if let gatedBool = try? container.decodeIfPresent(Bool.self, forKey: .gated) {
            gated = gatedBool
        } else if let gatedString = try? container.decodeIfPresent(String.self, forKey: .gated) {
            gated = gatedString.lowercased() == "true"
        } else {
            gated = nil
        }
    }
}

actor ModelManager {
    private let pageSize = 20
    
    enum ModelManagerError: Error {
        case fileSystemError(String)
        case downloadError(String)
        case networkError(String)
        
        var localizedDescription: String {
            switch self {
            case .fileSystemError(let message):
                return "File system error: \(message)"
            case .downloadError(let message):
                return "Download error: \(message)"
            case .networkError(let message):
                return "Network error: \(message)"
            }
        }
    }
    
    func fetchModels(search: String? = nil) async throws -> [HFModel] {
        var urlString = "https://huggingface.co/api/models?full=true&limit=\(pageSize)"
        if let search = search {
            urlString += "&search=\(search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        
        guard let url = URL(string: urlString) else {
            throw ModelManagerError.networkError("Invalid API URL")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        do {
            return try JSONDecoder().decode([HFModel].self, from: data)
        } catch {
            logger.error("JSON Decoding Error: \(error.localizedDescription)")
            throw error
        }
    }
    
    func fetchModelInfo(modelID: String) async throws -> HFModel {
        
        let urlString = "https://huggingface.co/api/models/\(modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        return try JSONDecoder().decode(HFModel.self, from: data)
    }
    
    func searchModels(query: String) async throws -> [HFModel] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://huggingface.co/api/models?search=\(encodedQuery)&full=true&limit=20") else {
            throw ModelManagerError.networkError("Invalid search URL")
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([HFModel].self, from: data)
    }
    
    func fetchModelREADME(modelId: String) async throws -> String {
        let encodedModelId = modelId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "https://huggingface.co/\(encodedModelId)/raw/main/README.md") else {
            throw ModelManagerError.networkError("Invalid README URL")
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
            return "" // No README available
        }
        
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    nonisolated func checkGGUFFiles(model: HFModel) -> (hasGGUF: Bool, ggufFiles: [HFSibling]) {
        let ggufFiles = model.siblings.filter { $0.rfilename.hasSuffix(".gguf") }
        return (hasGGUF: !ggufFiles.isEmpty, ggufFiles: ggufFiles)
    }
    
    // Helper to extract quantization from filename
    nonisolated func parseQuantization(from filename: String) -> String {
        // Common patterns: q4_k_m, q8_0, Q4_K_M, etc.
        // We look for parts starting with q or Q followed by digits/letters
        let lower = filename.lowercased()
        
        // Regex for Q4_K_M, Q8_0, IQ3_XS etc
        // Matches "q" or "iq" followed by digit, then optional underscores and letters
        let patterns = [
            "(iq|q)[0-9]+_[0-9a-z_]+", // matches q4_k_m, iq3_xs
            "(iq|q)[0-9]+"             // matches q4, q8
        ]
        
        for pattern in patterns {
            if let range = lower.range(of: pattern, options: .regularExpression) {
                return String(filename[range]).uppercased()
            }
        }
        
        return "Unknown"
    }
    
    func fetchModelDetail(modelId: String) async throws -> ModelDetail {
        let model = try await fetchModelInfo(modelID: modelId)
        let readme = try? await fetchModelREADME(modelId: modelId)
        let ggufInfo = checkGGUFFiles(model: model)
        
        var quantizedFiles: [String: HFSibling] = [:]
        
        for file in ggufInfo.ggufFiles {
            let quant = parseQuantization(from: file.rfilename)
            // If multiple files map to same quantization (e.g. split files), we might overwrite.
            // For now, simpler models usually have 1 file per quant.
            // Prefer keeping the first one or logic to handle splits could be added here.
            if quantizedFiles[quant] == nil {
                quantizedFiles[quant] = file
            }
        }
        
        // Sort for predictable UI order: Q2 -> Q3 -> Q4 ... -> Q8
        let availableQuantizations = quantizedFiles.keys.sorted { q1, q2 in
            // Custom sort to handle numbers correctly (Q4 < Q8)
            return q1.localizedStandardCompare(q2) == .orderedAscending
        }
        
        return ModelDetail(
            model: model,
            readme: readme,
            hasGGUF: ggufInfo.hasGGUF,
            quantizedFiles: quantizedFiles,
            availableQuantizations: availableQuantizations
        )
    }

    func buildLocalModelURL(modelID: String, filename: String) throws -> URL {
        let sanitizedModelID = modelID.replacingOccurrences(of: "/", with: "_")
        
        guard let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            throw ModelManagerError.fileSystemError("Unable to access library directory")
        }
        
        let filePath = libraryURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(sanitizedModelID, isDirectory: true)
            .appendingPathComponent(filename)
        
        return filePath
    }
    
    /// Finalizes a download by moving the temp file to the permanent location
    func finalizeDownload(tempURL: URL, modelID: String, filename: String) throws -> URL {
        logger.info("finalizeDownload: modelID=\(modelID), tempURL=\(tempURL.lastPathComponent)")
        
        let fm = FileManager.default
        let destURL = try buildLocalModelURL(modelID: modelID, filename: filename)
        let destDir = destURL.deletingLastPathComponent()
        
        // Create destination directory
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        // Remove existing file if it exists
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        
        // Move file to destination
        try fm.moveItem(at: tempURL, to: destURL)
        logger.info("File finalized successfully at \(destURL.lastPathComponent)")
        
        return destURL
    }
}
