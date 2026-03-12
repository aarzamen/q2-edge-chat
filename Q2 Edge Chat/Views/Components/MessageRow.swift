import SwiftUI

struct MessageRow: View {
    let message: Message
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.speaker == .assistant {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Assistant")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    
                    bubble(
                        color: Color(.systemGray6),
                        textColor: .primary,
                        alignment: .leading
                    )
                }
                .frame(maxWidth: 280, alignment: .leading)
                
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Spacer()
                        Text("You")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Image(systemName: "person.circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    bubble(
                        color: Color.accentColor,
                        textColor: .white,
                        alignment: .trailing
                    )
                }
                .frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func bubble(color: Color, textColor: Color, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            if message.speaker == .assistant {
                MarkdownText(markdown: message.text)
                    .foregroundColor(textColor)
            } else {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(textColor)
            }
            
            // Performance metrics (only for assistant messages)
            if message.speaker == .assistant,
               let ttft = message.timeToFirstToken,
               let tps = message.tokensPerSecond,
               let tokens = message.totalTokens {
                
                HStack(spacing: 6) {
                    // Time to first token
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 7))
                        Text(String(format: "%.2fs", ttft))
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                    }
                    
                    Text("•")
                        .font(.system(size: 7))
                    
                    // Tokens per second
                    HStack(spacing: 2) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 7))
                        Text(String(format: "%.1f t/s", tps))
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                    }
                    
                    Text("•")
                        .font(.system(size: 7))
                    
                    // Total tokens
                    HStack(spacing: 2) {
                        Image(systemName: "number")
                            .font(.system(size: 7))
                        Text("\(tokens)")
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                    }
                }
                .foregroundColor(textColor.opacity(0.5))
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(color)
                .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
        )
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}
// Preview with performance metrics
#Preview("Message with Metrics") {
    VStack(spacing: 16) {
        // User message
        MessageRow(message: Message(
            speaker: .user,
            text: "What is Swift?"
        ))
        
        // Assistant message with metrics
        MessageRow(message: Message(
            speaker: .assistant,
            text: "Swift is a powerful and intuitive programming language created by Apple for iOS, macOS, watchOS, and tvOS development. It's designed to be safe, fast, and expressive.",
            timeToFirstToken: 0.52,
            tokensPerSecond: 28.3,
            totalTokens: 156
        ))
        
        // Fast response
        MessageRow(message: Message(
            speaker: .assistant,
            text: "Yes, it's also open source!",
            timeToFirstToken: 0.12,
            tokensPerSecond: 45.8,
            totalTokens: 42
        ))
        
        Spacer()
    }
    .background(Color(.systemGroupedBackground))
}

