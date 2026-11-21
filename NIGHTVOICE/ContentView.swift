import SwiftUI

struct ContentView: View {
    @StateObject private var speech = SpeechController()
    @State private var showingSettings = false
    @State private var serverDraft = ""

    private func waveformHeight(for index: Int) -> CGFloat {
        let value = (index * 17 + index * index * 7) % 35
        return CGFloat(6 + value)
    }

    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.045, blue: 0.055).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        Text("BLACK ROSE SOCIETY").font(.caption2).tracking(3).foregroundStyle(.gray)
                        Spacer()
                        Button { serverDraft = speech.serverURL; showingSettings = true } label: {
                            Image(systemName: "gearshape.fill").foregroundStyle(.white)
                        }.accessibilityLabel("Settings")
                    }
                    VStack(spacing: 4) {
                        Text("NIGHTVOICE").font(.system(size: 37, weight: .black, design: .rounded)).tracking(2)
                        Text("SPIRIT BOX").font(.caption).tracking(5).foregroundStyle(.gray)
                    }.padding(.top, 16)
                    ZStack {
                        RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.055))
                        VStack(spacing: 16) {
                            HStack(spacing: 8) {
                                Circle().fill(speech.listening ? Color.red : Color.gray).frame(width: 9, height: 9)
                                Text(speech.status.uppercased()).font(.caption2).tracking(2).foregroundStyle(.gray)
                            }
                            Text(speech.reply).font(.system(size: 42, weight: .black, design: .rounded))
                                .foregroundStyle(Color(red: 0.98, green: 0.23, blue: 0.3))
                                .minimumScaleFactor(0.5).lineLimit(1).frame(minHeight: 80)
                            HStack(alignment: .center, spacing: 3) {
                                ForEach(0..<45, id: \.self) { i in
                                    Capsule()
                                        .fill(Color.red.opacity(0.65))
                                        .frame(width: 3, height: waveformHeight(for: i))
                                }
                            }.frame(height: 45)
                        }.padding(18)
                    }.frame(height: 240)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("HEARD QUESTION").font(.caption2).tracking(2).foregroundStyle(.gray)
                        Text(speech.transcript.isEmpty ? "Waiting for a question…" : speech.transcript)
                            .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.padding().background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15))
                    HStack(spacing: 12) {
                        Button { if speech.armed { speech.disarm() } else { Task { await speech.arm() } } } label: {
                            Label(speech.armed ? "DISARM" : "ARM", systemImage: speech.armed ? "stop.fill" : "mic.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                        }.buttonStyle(.borderedProminent).tint(.red)
                        Button { Task { await speech.manualAnswer() } } label: {
                            Text("ANSWER NOW").frame(maxWidth: .infinity).padding(.vertical, 11)
                        }.buttonStyle(.bordered).disabled(!speech.armed || speech.paused)
                    }
                    Button {
                        if speech.paused {
                            Task { await speech.resume() }
                        } else {
                            speech.pause()
                        }
                    } label: {
                        Label(speech.paused ? "RESUME LISTENING" : "PAUSE LISTENING",
                              systemImage: speech.paused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(speech.paused ? .green : .gray)
                    .disabled(!speech.armed)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("SESSION HISTORY").font(.caption2).tracking(2).foregroundStyle(.gray)
                        if speech.history.isEmpty { Text("No responses yet").foregroundStyle(.gray) }
                        ForEach(Array(speech.history.enumerated()), id: \.offset) { _, entry in
                            Text(entry).font(.footnote).foregroundStyle(.white.opacity(0.8))
                            Divider().overlay(Color.gray.opacity(0.2))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(22)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                Form {
                    Section("Listening") {
                        VStack(alignment: .leading) {
                            Text("Response delay: random 3–15 seconds after each question")
                            Text("Listening resumes immediately after each spoken answer.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Text("End-of-question silence: \(speech.silenceSeconds, specifier: "%.1f") seconds")
                            Slider(value: $speech.silenceSeconds, in: 1...3, step: 0.2)
                        }
                    }
                    Section("Optional online response service") {
                        TextField("https://your-server.example", text: $serverDraft)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL)
                        Text("Leave blank to use offline responses. Use a trusted HTTPS service; questions and recent conversation context are sent to it when enabled.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("About") {
                        Text("NIGHTVOICE is a simulated spirit-box experience. Its generated replies do not establish paranormal communication.")
                            .font(.footnote)
                    }
                }
                .navigationTitle("Settings")
                .toolbar { Button("Done") { speech.updateServerURL(serverDraft); showingSettings = false } }
            }.preferredColorScheme(.dark)
        }
    }
}
