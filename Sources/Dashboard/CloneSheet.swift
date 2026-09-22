import SwiftUI
import Glyph

/// Feuille « cloner » : URL ou `owner/repo` direct, sinon recherche GitHub.
/// Aucun réseau tant que l'utilisateur ne tape pas.
struct CloneSheet: View {
    @Environment(\.glyph) private var t
    let providers: DashboardProviders
    let onDone: (String?) -> Void

    @State private var input = ""
    @State private var results: [RemoteRepo] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var destination: URL
    @State private var chosen: String?
    @State private var cloning = false
    @State private var progress = ""
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(providers: DashboardProviders, onDone: @escaping (String?) -> Void) {
        self.providers = providers
        self.onDone = onDone
        _destination = State(initialValue: providers.defaultCloneDirectory)
    }

    private var directURL: String? { providers.normalizeCloneInput(input) }
    private var target: String? { chosen ?? directURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "clone a repository").uppercased()).font(t.smallFont).tracking(1.5).foregroundStyle(t.muted)
                Spacer()
                Text("⌘⇧O").font(t.smallFont).foregroundStyle(t.faint)
            }
            HStack(spacing: 6) {
                Text(">").foregroundStyle(t.muted)
                TextField("URL, owner/repo, or GitHub keywords", text: $input)
                    .textFieldStyle(.plain).focused($focused)
                    .onSubmit { if target != nil { startClone() } }
                if searching { ProgressView().controlSize(.small) }
            }
            .font(t.font).padding(8)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(t.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .onChange(of: input) { _, new in scheduleSearch(new) }

            if let d = directURL, chosen == nil {
                Leader(String(localized: "will clone"), d, emphasis: true)
            }
            if let searchError { Text(searchError).font(t.smallFont).foregroundStyle(.red) }
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(results) { r in
                        let sel = chosen == r.cloneURL
                        Button { chosen = sel ? nil : r.cloneURL } label: {
                            HStack(spacing: 8) {
                                Text(r.fullName).foregroundStyle(sel ? t.accent : t.ink).lineLimit(1)
                                Text(r.description).font(t.smallFont).foregroundStyle(t.muted).lineLimit(1)
                                Spacer(minLength: 4)
                                if let l = r.language { Text(l).font(t.smallFont).foregroundStyle(t.accent2) }
                                Text("★ \(Tabular.int(r.stars))").font(t.smallFont).foregroundStyle(t.muted).monospacedDigit()
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(sel ? t.accent.opacity(0.12) : .clear)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .font(t.font)
            }

            HStack(spacing: 6) {
                Text("into").foregroundStyle(t.muted)
                Text(destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).foregroundStyle(t.ink).lineLimit(1).truncationMode(.middle)
                if let tg = target { Text("/" + lastComponent(tg)).foregroundStyle(t.accent) }
                Spacer()
                Button("choose…") { Task { if let d = await providers.chooseDirectory(destination) { destination = d } } }
                    .buttonStyle(.plain).foregroundStyle(t.accent)
            }
            .font(t.font)

            if cloning || !progress.isEmpty {
                HStack(spacing: 8) {
                    if cloning { ProgressView().controlSize(.small) }
                    Text(progress).font(t.smallFont).foregroundStyle(t.muted).lineLimit(1).truncationMode(.head)
                }
            }
            if let error { Text(error).font(t.smallFont).foregroundStyle(.red).lineLimit(3) }

            HStack {
                Spacer()
                Button("cancel") { onDone(nil) }.buttonStyle(.plain).foregroundStyle(t.muted).keyboardShortcut(.cancelAction)
                Button(cloning ? String(localized: "cloning…") : String(localized: "clone")) { startClone() }
                    .buttonStyle(.plain).foregroundStyle(target == nil || cloning ? t.faint : t.accent)
                    .disabled(target == nil || cloning)
                    .keyboardShortcut(.defaultAction)
            }
            .font(t.font)
        }
        .padding(18)
        .frame(width: 620)
        .background(t.paper)
        .onAppear { focused = true }
    }

    private func lastComponent(_ url: String) -> String {
        var s = url; while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        chosen = nil
        searchError = nil
        let query = q.trimmingCharacters(in: .whitespaces)
        guard query.count >= 3, providers.normalizeCloneInput(query) == nil else { results = []; searching = false; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            do {
                let r = try await providers.searchRemote(query)
                guard !Task.isCancelled else { return }
                results = r
            } catch {
                if !Task.isCancelled { searchError = "\(error.localizedDescription)"; results = [] }
            }
            searching = false
        }
    }

    private func startClone() {
        guard let url = target, !cloning else { return }
        cloning = true; error = nil; progress = String(localized: "starting…")
        let dest = destination
        let cloneFn = providers.clone
        Task {
            do {
                let path = try await cloneFn(url, dest) { chunk in
                    let line = chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last.map(String.init) ?? chunk
                    Task { @MainActor in progress = line }
                }
                cloning = false
                onDone(path)
            } catch {
                cloning = false
                self.error = "\(error)"
            }
        }
    }
}
