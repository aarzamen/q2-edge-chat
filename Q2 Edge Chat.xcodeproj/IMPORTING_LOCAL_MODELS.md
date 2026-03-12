# How to Import Your Local LLM Files

This guide explains how to use your existing GGUF model files with Q2 Edge Chat.

## What I've Added

I've added functionality to import local GGUF files you already have on your Mac. Here's what was created:

### 1. **ImportLocalModelView.swift** - A new UI for importing models
- User-friendly interface to select and import GGUF files
- File picker dialog to browse your Mac
- Model ID input to identify your models
- Progress tracking and error handling

### 2. **ManifestStore Extensions** - New functions in `ModelManifest.swift`
- `importLocalModel(from:modelID:)` - Copies your GGUF file to the app's storage
- `exists(id:)` - Checks if a model is already imported

### 3. **UI Integration** - Added to `FrontPageView.swift`
- New "Import Local Model" button on the home screen
- Easy access to import functionality

## How to Use It

### Step 1: Build and Run Your App
After these changes, build and run your app.

### Step 2: Click "Import Local Model"
On the home screen, you'll see a new green button labeled "Import Local Model".

### Step 3: Enter Model Information
- **Model Identifier**: Enter a unique ID for your model
  - If it's from HuggingFace, use the format: `username/model-name`
  - Example: `microsoft/Phi-3-mini-4k-instruct-gguf`
  - Or use any custom name: `my-custom-llama`

### Step 4: Select Your GGUF File
Click "Choose GGUF File" and navigate to where your model files are stored on your Mac.

### Step 5: Start Chatting
Once imported, the model will appear in your model list and you can select it for chatting!

## Where Models Are Stored

The app copies your GGUF files to:
```
~/Library/Application Support/Q2 Edge Chat/Library/Models/
```

This ensures the app always has access to the files, even if you move or delete the original.

## Alternative: Manual Import (Advanced)

If you prefer not to copy the files, you can manually create a symbolic link:

```bash
# Find your app's Library directory (it changes each run in Simulator)
# For device builds, it's consistent

# Create the Models directory
mkdir -p ~/Library/Application\ Support/Q2\ Edge\ Chat/Library/Models/

# Create a symbolic link to your model
ln -s /path/to/your/model.gguf ~/Library/Application\ Support/Q2\ Edge\ Chat/Library/Models/model.gguf
```

Then manually edit the manifest file at:
```
~/Library/Application Support/Q2 Edge Chat/models.json
```

Add an entry like:
```json
{
  "id": "your-model-id",
  "localURL": "/path/to/the/linked/model.gguf",
  "downloadedAt": "2025-12-16T12:00:00Z"
}
```

## Supported File Format

- **GGUF files only** (`.gguf` extension)
- These are quantized LLM files that work with llama.cpp
- Common sources: HuggingFace, local training, converted models

## Tips

1. **Model IDs**: Use descriptive IDs so you can identify models later
2. **File Size**: Large models will take time to copy
3. **Multiple Models**: Import as many as you want
4. **Model Selection**: After importing, select the model in the chat settings

## Troubleshooting

### "Model not found" error
- Make sure the GGUF file is valid and not corrupted
- Check that you have read permissions on the file

### Import button is disabled
- You must enter a Model Identifier first

### Model doesn't appear in the list
- Restart the app
- Check the console for error messages

## Example Models You Might Have

Common GGUF models you might already have:
- Llama 2/3 models
- Mistral models
- Phi models from Microsoft
- Gemma models from Google
- Any custom fine-tuned GGUF models

## Need Help?

If you run into issues, check:
1. The model file is a valid `.gguf` file
2. You have enough disk space
3. The app has file system permissions (macOS Settings → Privacy & Security)
