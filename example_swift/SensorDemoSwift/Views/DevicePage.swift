import SwiftUI
import UniformTypeIdentifiers

/// Device page.
struct DevicePage: View {
    @EnvironmentObject var model: AppModel
    @State private var showBinPicker = false
    @State private var parseInsteadOfReplay = false
    @State private var multiReplayPicker = false

    var body: some View {
        Form {
            Section("Scan") {
                HStack {
                    Button(model.scanning ? "Stop Scan" : "Start Scan") {
                        model.toggleScan()
                    }
                    .disabled(model.replaying)
                    Spacer()
                }
                HStack {
                    Button("Multi Start") { model.multiStart() }
                        .disabled(model.connectedMacs.isEmpty || model.replaying)
                    Spacer()
                }
                if model.devices.isEmpty && !model.replaying {
                    Text("No devices yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.devices, id: \.mac) { d in
                        HStack {
                            Text(d.name.isEmpty ? "(unknown)" : d.name)
                                .foregroundStyle(model.currentMac == d.mac
                                    ? Color.accentColor : Color.primary)
                            Spacer()
                            Text("\(d.mac)  rssi=\(d.rssi)")
                                .foregroundStyle(.secondary)
                            if model.connectedMacs.contains(d.mac) {
                                if model.streamingMacs.contains(d.mac) {
                                    Text("Streaming")
                                        .foregroundStyle(Color.accentColor)
                                }
                                Text(model.stateText(for: d.mac))
                                    .foregroundStyle(.secondary)
                                Button("Disconnect") {
                                    model.toggleConnect(mac: d.mac)
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.disconnectingMacs.contains(d.mac))
                            } else {
                                Button("Connect") {
                                    model.toggleConnect(mac: d.mac)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectedMac = d.mac
                        }
                        .listRowBackground(model.currentMac == d.mac
                            ? Color.accentColor.opacity(0.15) : nil)
                    }
                    .disabled(model.replaying)
                    // Replay session rows.
                    ForEach(model.replayMacs, id: \.self) { rmac in
                        HStack {
                            Text((model.streamingMacs.contains(rmac) ? "[Streaming] " : "") +
                                 "[Replay] \(model.replayNames[rmac] ?? "")")
                                .foregroundStyle(model.currentMac == rmac
                                    ? Color.accentColor : Color.primary)
                            Spacer()
                            Text("Address: \(rmac)")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectedMac = rmac
                        }
                        .listRowBackground(model.currentMac == rmac
                            ? Color.accentColor.opacity(0.15) : nil)
                    }
                }
            }

            Section("Status") {
                Text("SensorSDK \(model.sdkVersion), demo v\(AppModel.demoVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.statusText)
                if !model.rateText.isEmpty {
                    Text(model.rateText).font(.caption)
                }
                Text("State: \(model.connectionText)")
                Text(model.countersText).font(.caption)
                Text(model.lostPacketText).font(.caption)
            }

            Section("Device Info") {
                Text(model.modelText)
                Text(model.hwText)
                Text(model.fwText)
                Text(model.batteryText)
                Text(model.linkText)
                Text(model.mtuText)
            }

            Section("Options") {
                Toggle("Auto Reconnect", isOn: $model.autoReconnect)
                Toggle("Clone Data", isOn: $model.cloneData)
                Toggle("Enable SDK Debug Log", isOn: $model.debugLogEnabled)
                    .disabled(model.replaying)
                Toggle("Enable Debug Bin Data", isOn: $model.debugBinEnabled)
                    .disabled(model.replaying)
                if !model.storageText.isEmpty {
                    Text(model.storageText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Data Notification") {
                ForEach(AppModel.ntfKeys.filter { model.isParamVisible($0) }, id: \.self) { key in
                    Toggle(AppModel.ntfLabels[key] ?? key, isOn: Binding(
                        get: { model.ntfStates[key] ?? false },
                        set: { model.setParamToggle(key: key, on: $0) }))
                        .disabled(!model.controlsEnabled)
                }
            }

            Section("Filters") {
                ForEach(AppModel.filterKeys.filter { model.isParamVisible($0) }, id: \.self) { key in
                    Toggle(AppModel.filterLabels[key] ?? key, isOn: Binding(
                        get: { model.filterStates[key] ?? false },
                        set: { model.setParamToggle(key: key, on: $0) }))
                        .disabled(!model.controlsEnabled)
                }
            }

            Section("EEG Sample Rate") {
                HStack {
                    ForEach(AppModel.sampleRateCandidates, id: \.self) { rate in
                        rateButton(rate)
                    }
                }
            }

            Section("Gesture") {
                Text(model.gestureText).font(.caption)
            }

            Section("Bin Replay") {
                Text(model.replayText).font(.caption)
                HStack {
                    Button("Replay Bin...") {
                        parseInsteadOfReplay = false
                        multiReplayPicker = false
                        showBinPicker = true
                    }
                    .disabled(model.replaying)
                    Button("Multi Replay Bin...") {
                        parseInsteadOfReplay = false
                        multiReplayPicker = true
                        showBinPicker = true
                    }
                    .disabled(model.replaying)
                    Button("Parse to CSV...") {
                        parseInsteadOfReplay = true
                        multiReplayPicker = false
                        showBinPicker = true
                    }
                    .disabled(model.analyzing)
                }
                HStack {
                    Button(model.replayPaused ? "Resume Replay" : "Pause Replay") {
                        model.toggleReplayPause()
                    }
                    .disabled(!model.replaying || model.replayStopRequested)
                    Button("Stop Replay") { model.stopReplay() }
                        .disabled(!model.replaying || model.replayStopRequested)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showBinPicker,
                      allowedContentTypes: [.sensorBin],
                      allowsMultipleSelection: multiReplayPicker) { result in
            guard case .success(let urls) = result else { return }
            if parseInsteadOfReplay {
                if let url = urls.first {
                    model.parseBinToCsv(url: url)
                }
            } else if multiReplayPicker {
                model.replayBinGroup(urls: urls)
            } else if let url = urls.first {
                model.replayBin(url: url)
            }
        }
    }

    /// One sample-rate radio.
    @ViewBuilder
    private func rateButton(_ rate: Int) -> some View {
        let enabled = model.controlsEnabled && model.eegSampleRateOptions.contains(rate)
        if model.eegSampleRate == rate {
            Button("\(rate) Hz") { model.setEegSampleRate(rate) }
                .buttonStyle(.borderedProminent)
                .disabled(!enabled)
        } else {
            Button("\(rate) Hz") { model.setEegSampleRate(rate) }
                .buttonStyle(.bordered)
                .disabled(!enabled)
        }
    }
}

extension UTType {
    /// Raw BLE bin capture files (.bin).
    static let sensorBin = UTType(filenameExtension: "bin") ?? .data
}
