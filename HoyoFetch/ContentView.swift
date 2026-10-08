import SophonKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.games, selection: $model.selection) { game in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(game.name)
                        if game.branches.preDownload != nil {
                            Text("Pre-download")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .background(.tint.opacity(0.2), in: .capsule)
                        }
                    }
                    Text("\(game.subtitle) · \(game.branches.main.tag)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(game.id)
            }
            .overlay {
                if model.games.isEmpty {
                    if let error = model.loadError {
                        ContentUnavailableView(
                            "Couldn't load games",
                            systemImage: "wifi.exclamationmark",
                            description: Text(error)
                        )
                    } else if model.isLoading {
                        ProgressView()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .disabled(model.isLoading || model.isBusy)
            }
        } detail: {
            if let game = model.game(model.selection) {
                GameDetailView(game: game)
                    .id(game.id)
            } else {
                ContentUnavailableView("Select a game", systemImage: "gamecontroller")
            }
        }
        .task { await model.refresh() }
    }
}

struct GameDetailView: View {
    let game: GameRow
    @Environment(AppModel.self) private var model
    @State private var selectedFields: Set<String> = ["game"]
    @State private var choosingFolder = false

    private var folder: URL? { model.folders[game.id] }
    private var installed: SophonInstallState? { model.installStates[game.id] }
    private var build: SophonBuild? { model.builds[game.id] }
    private var operation: OperationState? { model.operations[game.id] }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Live version", value: game.branches.main.tag)
                if let pre = game.branches.preDownload {
                    LabeledContent("Pre-download", value: pre.tag)
                }
                LabeledContent("Installed") {
                    if let installed {
                        Text(installed.tag + (installed.preDownloadedTag.map { " (\($0) pre-downloaded)" } ?? ""))
                    } else {
                        Text("Not installed").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Folder") {
                    HStack {
                        Text(folder?.path(percentEncoded: false) ?? "None")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(folder == nil ? .secondary : .primary)
                        Button("Choose…") { choosingFolder = true }
                            .disabled(model.isBusy)
                    }
                }
            } header: {
                Text(game.name).font(.title2.bold())
            }

            Section("Packages") {
                if let build {
                    let extras = build.manifests.filter { !Self.isPrimary($0.matchingField) }
                    let primary = build.manifests.filter { Self.isPrimary($0.matchingField) }
                    ForEach(primary, id: \.matchingField, content: packageToggle)
                    if !extras.isEmpty {
                        let selectedExtras = extras.filter { selectedFields.contains($0.matchingField) }.count
                        DisclosureGroup("Extra content (\(selectedExtras) of \(extras.count) selected)") {
                            ForEach(extras, id: \.matchingField, content: packageToggle)
                        }
                    }
                } else if let error = model.buildErrors[game.id] {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }

            Section("Options") {
                Toggle("Use patch builds when available (HDiffPatch)", isOn: $model.usePatches)
                    .disabled(model.isBusy)
            }

            Section {
                actions
            }

            if let operation {
                OperationView(operation: operation)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.setFolder(url, for: game.id) }
        }
        // Keyed on the build so a refresh, which clears it, loads it again.
        .task(id: build == nil) {
            await model.loadBuild(game.id)
            resetFields()
        }
        .onChange(of: installed) { resetFields() }
    }

    private func packageToggle(_ entry: SophonBuildManifest) -> some View {
        Toggle(isOn: fieldBinding(entry.matchingField)) {
            HStack {
                Text(Self.label(for: entry))
                Spacer()
                if let size = entry.stats?.uncompressedSize {
                    Text(size, format: .byteCount(style: .file)).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(entry.matchingField == "game" || model.isBusy)
    }

    @ViewBuilder private var actions: some View {
        let busy = model.isBusy
        let fields = orderedFields
        HStack {
            if let operation, operation.isRunning {
                ProgressView().controlSize(.small)
                Text("\(operation.kind.rawValue) running…")
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel(game.id) }
            } else if folder == nil {
                Text("Choose a folder to install into, or one that already holds an install from HoyoFetch.")
                    .foregroundStyle(.secondary)
            } else if let installed {
                if installed.tag != game.branches.main.tag {
                    Button("Update to \(game.branches.main.tag)") {
                        model.start(.update, game: game, matchingFields: fields)
                    }
                        .buttonStyle(.borderedProminent)
                }
                if let pre = game.branches.preDownload,
                   installed.tag != pre.tag,
                   installed.preDownloadedTag != pre.tag {
                    Button("Pre-download \(pre.tag)") { model.start(.preDownload, game: game, matchingFields: fields) }
                }
                Spacer()
                Button(fields == installed.matchingFields ? "Verify & Repair" : "Apply Package Changes") {
                    model.start(.repair, game: game, matchingFields: fields)
                }
            } else {
                Spacer()
                Button("Install \(game.branches.main.tag)") {
                    model.start(.install, game: game, matchingFields: fields)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(build == nil)
            }
        }
        .disabled(busy && operation?.isRunning != true)
    }

    private var orderedFields: [String] {
        (build?.manifests.map(\.matchingField) ?? ["game"]).filter(selectedFields.contains)
    }

    private func fieldBinding(_ field: String) -> Binding<Bool> {
        Binding {
            selectedFields.contains(field)
        } set: { isOn in
            if isOn { selectedFields.insert(field) } else { selectedFields.remove(field) }
        }
    }

    private func resetFields() {
        if let installed {
            selectedFields = Set(installed.matchingFields)
        } else if let build {
            let available = Set(build.manifests.map(\.matchingField))
            selectedFields = Set(["game"]).union(available.contains("en-us") ? ["en-us"] : [])
        }
    }

    private static let voices = [
        "en-us": "English", "ja-jp": "Japanese", "zh-cn": "Chinese (Simplified)",
        "ko-kr": "Korean", "zh-tw": "Chinese (Traditional)",
    ]

    static func isPrimary(_ field: String) -> Bool {
        field == "game" || voices[field] != nil
    }

    static func label(for entry: SophonBuildManifest) -> String {
        if entry.matchingField == "game" { return "Base game" }
        if let voice = voices[entry.matchingField] { return "Voice pack: \(voice)" }
        // Category names are internal Chinese labels, and sometimes the literal string "null".
        let name = entry.categoryName == "null" ? "" : entry.categoryName
        return name.isEmpty ? entry.matchingField : "\(name) (\(entry.matchingField))"
    }
}

struct OperationView: View {
    let operation: OperationState

    private var title: String {
        let status = if operation.finished {
            operation.error == nil ? "Finished" : "Stopped"
        } else {
            operation.progress.phase.rawValue
        }
        return "\(operation.kind.rawValue) — \(status)"
    }

    var body: some View {
        Section(title) {
            let progress = operation.progress
            ProgressView(value: progress.fraction)
            HStack {
                let completed = progress.completedBytes.formatted(.byteCount(style: .file))
                let total = progress.totalBytes.formatted(.byteCount(style: .file))
                Text("\(completed) of \(total)")
                Spacer()
                if operation.isRunning, operation.speed > 0 {
                    Text("\(Int64(operation.speed).formatted(.byteCount(style: .file)))/s")
                }
                Text("\(progress.completedFiles)/\(progress.totalFiles) files")
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)

            if let error = operation.error {
                Text(error).foregroundStyle(.red)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(operation.log.enumerated()), id: \.offset) { index, line in
                            Text(line).id(index)
                        }
                    }
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .onChange(of: operation.log.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }
}
