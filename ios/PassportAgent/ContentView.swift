import SwiftUI

struct ContentView: View {
    @Environment(AgentSession.self) private var session
    @State private var task = ""
    @State private var showingSettings = false

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("例如：打开设置并查看电池用量", text: $task, axis: .vertical)
                        .lineLimit(3...6)
                    Button(session.isRunning ? "停止任务" : "开始任务") {
                        if session.isRunning { session.stop() }
                        else { Task { await session.start(task: task) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(session.isRunning ? .red : .blue)
                    .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isRunning)
                }

                Section("连接状态") {
                    LabeledContent("Passport", value: session.passportStatus)
                    LabeledContent("屏幕共享", value: session.captureStatus)
                    LabeledContent("任务", value: session.status)
                }

                if !session.events.isEmpty {
                    Section("最近操作") {
                        ForEach(session.events.suffix(8).reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
            }
            .navigationTitle("Passport Agent")
            .toolbar {
                Button("设置", systemImage: "gear") { showingSettings = true }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
        .task { session.connectPassport() }
    }
}

private struct SettingsView: View {
    @Environment(AgentSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var model = ""
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("API 地址", text: $endpoint)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("模型", text: $model).textInputAutocapitalization(.never)
                SecureField("API Key", text: $apiKey)
                Text("兼容 OpenAI Chat Completions 图像输入。密钥保存在系统钥匙串中。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("模型设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        session.saveSettings(endpoint: endpoint, model: model, apiKey: apiKey)
                        dismiss()
                    }
                }
            }
            .onAppear {
                endpoint = session.settings.endpoint
                model = session.settings.model
                apiKey = session.currentAPIKey
            }
        }
    }
}
