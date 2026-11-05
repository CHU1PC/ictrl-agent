#!/bin/sh
# Pure Swift checks for the voice agent; no signing or iPhone required.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ictrl-voice-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
swiftc -module-cache-path "$tmp/module-cache" \
    "$root/iCTRLKit/RPCMethod.swift" \
    "$root/iCTRLKit/BuildStamp.swift" \
    "$root/iCTRLApp/Agent/SpeechText.swift" \
    "$root/iCTRLApp/Agent/AgentTools.swift" \
    "$root/iCTRLApp/Agent/ApprovalMode.swift" \
    "$root/iCTRLApp/Agent/AgentMemory.swift" \
    "$root/Tests/VoiceAgent/main.swift" \
    -o "$tmp/voice-agent-tests"
"$tmp/voice-agent-tests"

# The parsers are only useful if the app calls them; a refactor that drops a call still builds.
wired() {
    grep -qF -- "$2" "$root/$1" || { echo "❌ not wired: $1 lacks $2" >&2; exit 1; }
}
wired iCTRLApp/Agent/GeminiTTS.swift 'try parser.feed(line)'
wired iCTRLApp/Agent/SpeechOutput.swift 'decoder.samples(chunk)'
wired iCTRLApp/Agent/SpeechOutput.swift 'SpeechText.sentences(text)'
wired iCTRLApp/Agent/AgentSession.swift 'ConfirmationAnswer.interpret(text)'
wired iCTRLApp/Agent/AgentSession.swift 'approval.needsUser(summary)'
wired iCTRLApp/Agent/AgentSession.swift 'AgentMemory.execute(name, input: input)'
echo "VoiceAgent: call sites wired"
