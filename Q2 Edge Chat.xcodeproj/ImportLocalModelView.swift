import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ImportLocalModelView: View {
    @State private var isImporting = false
    @State private var modelID = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var alertTitle = "Success"
    
    let manifestStore: ManifestStore
    let onSuccess: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)
                
                Text("Import Local Model")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Import GGUF models you already have on your Mac")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Model Identifier")
                    .font(.headline)
                
                TextField("e.g., microsoft/Phi-3-mini-4k-instruct-gguf", text: $modelID)
                    .textFieldStyle(.roundedBorder)
                
                Text("This identifier helps you recognize the model. Use the HuggingFace model ID if applicable.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button(action: selectFile) {
                Label("Choose GGUF File", systemImage: "folder")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(modelID.isEmpty ? Color.gray.opacity(0.3) : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(modelID.isEmpty)
            
            if isImporting {
                ProgressView("Importing model...")
            }
            
            Spacer()
        }
        .padding()
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK") {
                if alertTitle == "Success" {
                    onSuccess()
                }
            }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.message = "Select a GGUF model file to import"
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importModel(from: url)
        }
    }
    
    private func importModel(from url: URL) {
        isImporting = true
        
        Task {
            do {
                // Check if model already exists
                let exists = await manifestStore.exists(id: modelID)
                if exists {
                    await MainActor.run {
                        alertTitle = "Model Already Exists"
                        alertMessage = "A model with ID '\(modelID)' is already imported."
                        showAlert = true
                        isImporting = false
                    }
                    return
                }
                
                // Import the model
                try await manifestStore.importLocalModel(from: url, modelID: modelID)
                
                await MainActor.run {
                    alertTitle = "Success"
                    alertMessage = "Model '\(url.lastPathComponent)' has been imported successfully!"
                    showAlert = true
                    isImporting = false
                    modelID = ""
                }
            } catch {
                await MainActor.run {
                    alertTitle = "Import Failed"
                    alertMessage = error.localizedDescription
                    showAlert = true
                    isImporting = false
                }
            }
        }
    }
}

// Preview provider for development
#Preview {
    do {
        let manifest = try ManifestStore()
        return ImportLocalModelView(manifestStore: manifest) {
            print("Import successful")
        }
    } catch {
        return Text("Failed to initialize preview: \(error.localizedDescription)")
    }
}
