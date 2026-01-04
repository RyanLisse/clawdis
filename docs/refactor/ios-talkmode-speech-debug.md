# iOS TalkMode Speech Recognition Debug Guide

## Current Issue (Jan 2026)
Error `kAFAssistantErrorDomain:1110` "No speech detected" on iPhone 16 Pro (iOS 26.3).

## Error Code Reference
- **1110**: No speech detected in audio buffer (buffer received but empty/silent)
- **1101**: No internet connection (for server-based recognition)
- **1107**: Speech recognition request was cancelled
- **203**: Session timeout
- **209**: Rate limit exceeded

## Investigation Summary

### What Works
- Gateway bridge connection ✓
- Node pairing/approval ✓
- Canvas commands ✓
- Audio session configuration (no errors)
- Microphone permission granted

### What Doesn't Work
- SFSpeechRecognizer returns error 1110 immediately after starting
- No transcripts reach the gateway

## Original Implementation Reference
Source: https://github.com/clawdbot/clawdbot

```swift
// Original startRecognition() - KNOWN WORKING
private func startRecognition() throws {
    self.stopRecognition()
    self.speechRecognizer = SFSpeechRecognizer()
    // ...
    let input = self.audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    let tapBlock = Self.makeAudioTapAppendCallback(request: request)
    input.installTap(onBus: 0, bufferSize: 2048, format: format, block: tapBlock)
    
    self.audioEngine.prepare()
    try self.audioEngine.start()
    // ...
}

// Original tap callback - SIMPLE
private nonisolated static func makeAudioTapAppendCallback(request: SpeechRequest) -> AVAudioNodeTapBlock {
    { buffer, _ in
        request.append(buffer)
    }
}

// Original audio session
try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
    .duckOthers,
    .mixWithOthers,
    .allowBluetoothHFP,
    .defaultToSpeaker,
])
```

## Key Differences Found

| Aspect | Original | Our Version | Status |
|--------|----------|-------------|--------|
| Locale | None (device default) | `en-US` explicit | Changed |
| On-device | Not set | Was `requiresOnDeviceRecognition = true` | Removed |
| Format timing | Before prepare() | After prepare() | Need to revert |
| Tap callback | Simple static | Was capturing `[weak self]` | Fixed |
| Mixer node | None | Was using AVAudioMixerNode | Removed |
| removeTap | Yes | Yes | Fixed |
| .mixWithOthers | Yes | Yes | Fixed |

## Debugging Steps

### 1. Verify Audio Format
```swift
let format = input.outputFormat(forBus: 0)
print("Format: \(format.sampleRate)Hz, \(format.channelCount)ch")
guard format.channelCount > 0, format.sampleRate > 0 else {
    throw NSError(domain: "TalkMode", code: 2, userInfo: [...])
}
```

### 2. Check Audio Session Route
```swift
let session = AVAudioSession.sharedInstance()
print("Input available: \(session.isInputAvailable)")
if let input = session.currentRoute.inputs.first {
    print("Port: \(input.portName) (\(input.portType))")
}
```

### 3. Verify Tap is Receiving Audio
Add logging in tap callback:
```swift
{ buffer, _ in
    print("Tap: frames=\(buffer.frameLength)")
    request.append(buffer)
}
```

### 4. Test VoiceWakeManager
If VoiceWake works but TalkMode doesn't, compare implementations.

## File Locations
- **TalkModeManager**: `apps/ios/Sources/Voice/TalkModeManager.swift`
- **VoiceWakeManager**: `apps/ios/Sources/Voice/VoiceWakeManager.swift`
- **TalkOrbOverlay**: `apps/ios/Sources/Voice/TalkOrbOverlay.swift`
- **NodeAppModel**: `apps/ios/Sources/Model/NodeAppModel.swift`

## Build & Deploy Commands
```bash
# Build for device
xcodebuild -project apps/ios/Clawdis.xcodeproj -scheme Clawdis \
  -destination 'platform=iOS,id=DEVICE_UDID' build

# Or use MCP tools:
# xcodebuild_build_device
# xcodebuild_install_app_device
# xcodebuild_start_device_log_cap
```

## Next Investigation Steps
1. Get format BEFORE prepare() (match original exactly)
2. Add format validation (ch > 0, rate > 0)
3. Log tap callback invocations to verify audio flow
4. Test if error appears when user is actively speaking
5. Compare with VoiceWakeManager which uses identical audio setup
