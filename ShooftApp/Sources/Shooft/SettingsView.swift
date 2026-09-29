import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            permissionSection
            Divider()
            pedalSection
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: Permission

    private var permissionSection: some View {
        HStack(spacing: 10) {
            Image(systemName: model.engineRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.engineRunning ? .green : .orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                if model.engineRunning {
                    Text("동작 중").font(.headline)
                    Text(heldText).font(.caption).foregroundStyle(.secondary)
                } else if model.accessibilityGranted {
                    Text("권한은 있지만 키 입력을 가로채지 못합니다").font(.headline)
                    Text("이벤트 탭을 만들지 못했습니다. 앱을 종료했다가 다시 실행해 보세요.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("손쉬움(Accessibility) 권한이 필요합니다").font(.headline)
                    Text("키 입력에 Shift를 붙이려면 이 권한이 있어야 합니다. 허용하면 자동으로 시작합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("설정에서 이미 켜져 있는데도 이 표시가 남아 있으면, 스위치를 껐다가 다시 켜거나 목록에서 지우고 앱을 다시 추가하세요. (앱 서명이 바뀌면 이전 항목이 무효가 됩니다.)")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if !model.engineRunning {
                Button("권한 열기") { model.requestAccessibility(); model.openAccessibilitySettings() }
            }
        }
    }

    private var heldText: String {
        if model.heldModifiers.isEmpty { return "페달을 밟은 채 키보드를 치면 조합키가 붙습니다." }
        return "밟는 중: " + model.heldModifiers.map(\.label).sorted().joined(separator: " ")
    }

    // MARK: Pedals

    private var pedalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("페달 설정").font(.headline)
                Spacer()
                if model.pedalConnected {
                    Label("연결됨", systemImage: "cable.connector").font(.caption).foregroundStyle(.green)
                } else {
                    Label("페달 없음", systemImage: "cable.connector.slash").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.pedalConnected {
                ForEach(0..<3, id: \.self) { index in
                    PedalRowView(index: index, row: $model.rows[index], model: model)
                }
                HStack {
                    Spacer()
                    if model.hasUnsavedChanges {
                        Button("되돌리기") { model.discardChanges() }
                            .disabled(model.busy)
                    }
                    Button("페달에 저장") { model.applyRows() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.busy || !model.hasUnsavedChanges)
                }
                Text("칸을 클릭한 뒤 원하는 키를 누르세요. Shift 같은 조합키만 눌렀다 떼면 \"밟는 동안 유지\"가 되고, ⌘Z처럼 같이 누르면 그 조합을 한 번 칩니다. 설정은 페달 안에 저장되어 다른 컴퓨터에서도 유지되지만, \"밟는 동안 유지\"는 이 앱이 켜져 있을 때만 동작합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("PCsensor 풋스위치를 USB로 연결하면 여기에서 세 페달의 동작을 바꿀 수 있습니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !model.status.isEmpty {
                HStack(spacing: 6) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Toggle("로그인할 때 자동으로 실행", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
            Spacer()
            Button("종료") { NSApp.terminate(nil) }
        }
    }
}

struct PedalRowView: View {
    let index: Int
    @Binding var row: PedalRow
    @ObservedObject var model: AppModel

    private var recording: Bool { model.recordingRow == index }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("페달 \(index + 1)").frame(width: 50, alignment: .leading)

            // The shortcut field: click, then press the key you want.
            Button {
                if recording { model.stopRecording() } else { model.startRecording(row: index) }
            } label: {
                HStack {
                    if recording {
                        Text("키를 누르세요").foregroundStyle(.tint)
                    } else {
                        Text(row.setting.summary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 200)
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(model.busy)

            // Keys this keyboard may not have.
            Menu {
                Section("밟는 동안 유지") {
                    ForEach(FootModifier.allCases) { m in
                        Button(m.label) { row = PedalRow(.foot(m)) }
                    }
                }
                Section("키") {
                    ForEach(PlainKey.all) { key in
                        Button(key.label) { row = PedalRow(.key(usage: key.usage, modifiers: row.setting.modifiers)) }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.busy || recording)

            Spacer()
        }
        .overlay(alignment: .bottomLeading) {
            if let other = row.other {
                Text("현재 페달에는 편집할 수 없는 \(other) 설정이 있습니다. 저장하면 덮어씁니다.")
                    .font(.caption2).foregroundStyle(.orange).offset(y: 16)
            }
        }
        .padding(.bottom, row.other == nil ? 0 : 14)
    }
}
