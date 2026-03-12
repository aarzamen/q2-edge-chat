import Foundation
import SwiftUI
import Combine

@MainActor
class BrowseModelsViewModel: ObservableObject {
    @Published var localEntries: [ManifestEntry] = []
    // Track progress: ModelID -> Progress (0.0 - 1.0). If entry exists, it's downloading.
    @Published var downloadProgress: [String: Double] = [:]
    @Published var errorMessage: String?

    // Search functionality
    @Published var searchText = ""
    @Published var searchResults: [HFModel] = []
    @Published var isSearching = false

    // Staff picks
    @Published var staffPicks = StaffPickModel.staffPicks

    // Model detail sheet
    @Published var selectedModelDetail: ModelDetail?
    @Published var showingModelDetail = false
    @Published var selectedQuantization: String = "Q4_K_M" // Default preference

    // Local file discovery and import
    @Published var discoveredLocalFiles: [DiscoveredFile] = []
    @Published var showFilePicker = false
    @Published var importProgress: [String: Double] = [:]  // filename -> progress (0.0 - 1.0)
    
    private var cancellables = Set<AnyCancellable>()
    let manager = ModelManager()
    private let store: ManifestStore
    private let downloadService = DownloadService.shared
    
    // Computed property for easy UI access
    var availableQuantizations: [String] {
        selectedModelDetail?.availableQuantizations ?? []
    }
    
    // Smart summary from README
    var modelSummary: String {
        guard let readme = selectedModelDetail?.readme, !readme.isEmpty else { return "No description available." }
        
        // Simple heuristic: Take the first paragraph that isn't a header or badge
        let lines = readme.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.contains("http") && trimmed.count > 50 {
                return trimmed
            }
        }
        
        // Fallback: first 300 chars
        return String(readme.prefix(300)) + "..."
    }
    
    init() {
        self.store = ManifestStore.shared
        store.didChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.loadLocal() } }
            .store(in: &cancellables)
        
        // Setup search debouncing
        $searchText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] searchText in
                Task { await self?.performSearch(query: searchText) }
            }
            .store(in: &cancellables)
        
        // Subscribe to DownloadService updates
        downloadService.$activeDownloads
            .receive(on: RunLoop.main)
            .assign(to: \.downloadProgress, on: self)
            .store(in: &cancellables)
        
        downloadService.downloadComplete
            .receive(on: RunLoop.main)
            .sink { [weak self] (modelId: String, location: URL, filename: String) in
                Task { await self?.handleDownloadComplete(modelId: modelId, location: location, filename: filename) }
            }
            .store(in: &cancellables)
        
        downloadService.downloadError
            .receive(on: RunLoop.main)
            .sink { [weak self] (modelId: String, error: Error) in
                self?.errorMessage = "Download failed for \(modelId): \(error.localizedDescription)"
            }
            .store(in: &cancellables)
    }
    
    func onQuantizationSelected(_ quant: String) {
        selectedQuantization = quant
    }

    func loadLocal() async {
        // First, validate and clean up any entries with missing files
        do {
            let removedIDs = try await store.validateAndCleanup()
            if !removedIDs.isEmpty {
                print("🧹 Cleaned up \(removedIDs.count) invalid model entries")
            }
        } catch {
            print("⚠️ Failed to validate manifest: \(error)")
        }

        localEntries = await store.all()
        refreshDiscoveredFiles()
    }

    /// Scan Documents folder for GGUF files not yet imported
    func refreshDiscoveredFiles() {
        let allDiscovered = store.discoverLocalGGUFFiles()

        // Filter out files that are already in the manifest (by filename match)
        let importedFilenames = Set(localEntries.map { $0.localURL.lastPathComponent })
        discoveredLocalFiles = allDiscovered.filter { !importedFilenames.contains($0.filename) }
    }

    func performSearch(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        defer { isSearching = false }
        errorMessage = nil
        
        do {
            searchResults = try await manager.searchModels(query: query)
        } catch {
            errorMessage = error.localizedDescription
            searchResults = []
        }
    }
    
    func clearSearch() {
        searchText = ""
        searchResults = []
    }
    
    func fetchModelDetail(modelId: String) async {
        do {
            let detail = try await manager.fetchModelDetail(modelId: modelId)
            selectedModelDetail = detail
            
            // Default selection logic: Try Q4_K_M, then Q4_*, then first available
            if let available = detail.availableQuantizations.first(where: { $0.caseInsensitiveCompare("Q4_K_M") == .orderedSame }) {
                selectedQuantization = available
            } else if let q4 = detail.availableQuantizations.first(where: { $0.uppercased().contains("Q4") }) {
                selectedQuantization = q4
            } else {
                selectedQuantization = detail.availableQuantizations.first ?? ""
            }
            
            showingModelDetail = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func downloadStaffPick(_ staffPick: StaffPickModel) async {
        await fetchModelDetail(modelId: staffPick.huggingFaceId)
        if let modelDetail = selectedModelDetail, modelDetail.hasGGUF {
            await download(modelDetail.model)
        }
    }

    func download(_ model: HFModel) async {
        // Prevent duplicate downloads
        guard downloadService.activeDownloads[model.id] == nil else {
            print("⚠️ DOWNLOAD: Already downloading \(model.id)")
            return
        }
        
        // Find the file for the selected quantization
        guard let detail = selectedModelDetail,
              let sibling = detail.quantizedFiles[selectedQuantization] ?? detail.quantizedFiles.values.first else {
            
            // Fallback strategy if we don't have detail loaded (e.g. from staff pick direct download, although we load detail first now)
            // Or if explicit selection failed
            let msg = "No file found for quantization: \(selectedQuantization)"
            print("❌ DOWNLOAD ERROR: \(msg)")
            errorMessage = msg
            return
        }
        
        let encoded = model.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model.id
        guard let url = URL(string: "https://huggingface.co/\(encoded)/resolve/main/\(sibling.rfilename)") else {
            let msg = "Invalid URL for model download"
            errorMessage = msg
            return
        }
        
        print("📥 DOWNLOAD START: \(model.id) (\(selectedQuantization))")
        print("   URL: \(url.absoluteString)")
        print("   File: \(sibling.rfilename)")
        
        // Start background download with filename context
        downloadService.startDownload(url: url, modelId: model.id, filename: sibling.rfilename)
    }
    
    private func handleDownloadComplete(modelId: String, location: URL, filename: String) async {
        print("🎉 ViewModel handling download completion for \(modelId) -> \(filename)")
        
        do {
            let finalURL = try await manager.finalizeDownload(tempURL: location, modelID: modelId, filename: filename)
            
            let entry = ManifestEntry(
                id: modelId,
                localURL: finalURL,
                downloadedAt: Date()
            )
            try await store.add(entry)
            await loadLocal()
            print("   ✅ Manifest updated")
        } catch {
            errorMessage = "Failed to finalize \(modelId): \(error.localizedDescription)"
        }
    }
    
    // Override download to store filename
    func startDownload(model: HFModel, sibling: HFSibling, url: URL) {
        downloadService.startDownload(url: url, modelId: model.id, filename: sibling.rfilename)
    }

    func isDownloading(_ model: HFModel) -> Bool {
        return downloadProgress[model.id] != nil
    }
    
    func isDownloaded(_ model: HFModel) -> Bool {
        return localEntries.contains(where: { $0.id == model.id })
    }
    
    func isStaffPickDownloaded(_ staffPick: StaffPickModel) -> Bool {
        return localEntries.contains(where: { $0.id == staffPick.huggingFaceId })
    }
    
    func isStaffPickDownloading(_ staffPick: StaffPickModel) -> Bool {
        return downloadProgress[staffPick.huggingFaceId] != nil
    }

    func delete(_ entry: ManifestEntry) async {
        do {
            // Remove from file system first
            let fm = FileManager.default
            if fm.fileExists(atPath: entry.localURL.path) {
                try fm.removeItem(at: entry.localURL)
            }
            
            // Then remove from manifest
            try await store.remove(id: entry.id)
            await loadLocal()
        } catch {
            errorMessage = "Failed to delete \(entry.id): \(error.localizedDescription)"
        }
    }
    
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Local File Import

    /// Import a discovered local GGUF file
    func importLocalFile(_ file: DiscoveredFile) async {
        // Prevent duplicate imports
        guard importProgress[file.filename] == nil else { return }

        importProgress[file.filename] = 0.0

        do {
            _ = try await store.importDiscoveredFile(file) { [weak self] progress in
                Task { @MainActor in
                    self?.importProgress[file.filename] = progress
                }
            }

            // Import complete
            importProgress.removeValue(forKey: file.filename)
            await loadLocal()
        } catch {
            importProgress.removeValue(forKey: file.filename)
            errorMessage = "Failed to import \(file.filename): \(error.localizedDescription)"
        }
    }

    /// Import a file selected from the document picker
    func importFromDocumentPicker(url: URL) async {
        let filename = url.lastPathComponent

        // Prevent duplicate imports
        guard importProgress[filename] == nil else { return }

        importProgress[filename] = 0.0

        do {
            _ = try await store.importFromDocumentPicker(url: url) { [weak self] progress in
                Task { @MainActor in
                    self?.importProgress[filename] = progress
                }
            }

            // Import complete
            importProgress.removeValue(forKey: filename)
            await loadLocal()
        } catch {
            importProgress.removeValue(forKey: filename)
            errorMessage = "Failed to import \(filename): \(error.localizedDescription)"
        }
    }

    /// Check if a local file is currently being imported
    func isImporting(_ file: DiscoveredFile) -> Bool {
        importProgress[file.filename] != nil
    }

    /// Get import progress for a file (0.0 - 1.0)
    func importProgressFor(_ file: DiscoveredFile) -> Double {
        importProgress[file.filename] ?? 0.0
    }
}


