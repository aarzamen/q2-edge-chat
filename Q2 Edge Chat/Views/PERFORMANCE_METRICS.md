# Performance Metrics in Chat Interface

I've added discreet performance metrics to the chat interface that appear below each AI assistant response.

## 📊 What's Displayed

Each assistant message now shows three key performance metrics:

### ⚡ Time to First Token (TTFT)
- **Icon**: Bolt (⚡)
- **Format**: `0.52s`
- **What it means**: How long it took before the model started generating a response
- **Lower is better**: Indicates how "snappy" the model feels

### 🏎️ Tokens per Second
- **Icon**: Speedometer
- **Format**: `28.3 t/s`
- **What it means**: How many tokens (words/word pieces) the model generates per second
- **Higher is better**: Shows the generation speed

### 🔢 Total Tokens
- **Icon**: Number symbol
- **Format**: `156`
- **What it means**: Total number of tokens generated in the response
- **Informational**: Helps understand response length and costs

## 🎨 Design

The metrics are displayed in a **small, discreet** format:
- Tiny font size (9pt)
- Slightly transparent (60% opacity)
- Separated by bullet points
- Only shown on assistant messages
- Positioned below the message text

### Example appearance:
```
⚡ 0.52s • 🏎️ 28.3 t/s • 🔢 156
```

## 🔧 Technical Details

### Data Structure
Added to `Message` struct:
```swift
var timeToFirstToken: TimeInterval?
var tokensPerSecond: Double?
var totalTokens: Int?
```

### Tracking Logic
In `ChatManager.send()`:
1. **Start Time**: Recorded when generation begins
2. **First Token Time**: Recorded when first non-whitespace token arrives
3. **Token Count**: Incremented with each token
4. **Metrics Calculation**: Performed after generation completes
   - TTFT = firstTokenTime - startTime
   - Tokens/sec = totalTokens / totalTime

### Display Logic
In `MessageRow.swift`:
- Metrics only shown when all three values are present
- Formatted for readability
- Styled to be subtle and non-intrusive

## 💡 Use Cases

### Performance Testing
Compare different models:
- Which model responds fastest?
- Which generates tokens most quickly?
- How does quantization affect speed?

### Model Selection
Choose the right model for your needs:
- **Fast TTFT**: Better for interactive chat
- **High t/s**: Better for long-form content
- **Balance**: Consider both metrics

### Troubleshooting
Identify performance issues:
- Slow TTFT might indicate model loading issues
- Low t/s might suggest CPU/memory constraints
- Compare metrics across different prompts

## 🎯 Future Enhancements

Possible additions:
- [ ] Toggle to show/hide metrics
- [ ] Color coding (green = fast, yellow = medium, red = slow)
- [ ] Historical averages per model
- [ ] Export metrics with chat history
- [ ] Memory usage tracking
- [ ] Prompt token count

## 📝 Notes

- Metrics are saved with the chat history
- Only appears on new messages (old messages won't have metrics)
- Cancelled messages won't have complete metrics
- Error messages won't have metrics
