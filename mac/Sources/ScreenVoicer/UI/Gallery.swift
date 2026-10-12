import AppKit
import SwiftUI

/// Gallery state (GalleryWindow.xaml.cs).
@MainActor
final class GalleryModel: ObservableObject {
    @Published var all: [ScreenshotHistoryItem] = []
    @Published var filtered: [ScreenshotHistoryItem] = []
    @Published var query = "" {
        didSet { scheduleFilter() }
    }
    @Published var selected: Set<String> = []
    @Published var snackbar: String?
    @Published var sharing = false
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var loaded = false

    let history: HistoryService
    var hotkeyText: () -> String = { "" }
    var startCapture: () -> Void = {}
    var share: (([ScreenshotHistoryItem]) async -> ShareResult?)?
    var unshare: ((ScreenshotHistoryItem) async -> Bool)?
    var openFolder: () -> Void = {}
    var closeWindow: () -> Void = {}

    private var loadVersion = 0
    private var filterTask: Task<Void, Never>?
    private var snackbarTask: Task<Void, Never>?
    private var thumbnailKeys: [String: String] = [:] // id → path|mtime of the cached thumbnail

    init(history: HistoryService) {
        self.history = history
    }

    func load() async {
        loadVersion += 1
        let version = loadVersion
        let items = await history.all()
        guard version == loadVersion else { return } // a newer refresh is already running
        all = items
        selected = selected.filter { id in items.contains { $0.id == id } }
        loaded = true
        applyFilter()
    }

    private func scheduleFilter() {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            self?.applyFilter()
        }
    }

    func applyFilter() {
        let q = query.trimmingCharacters(in: .whitespaces)
        filtered = q.isEmpty ? all : all.filter { item in
            item.transcribedText.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || item.displayDate.contains(q)
                || item.fileName.range(of: q, options: .caseInsensitive) != nil
        }
        for item in filtered { loadThumbnail(item) }
    }

    var countText: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !loaded { return "…" }
        return q.isEmpty ? Formats.plural(all.count, "скриншот", "скриншоти", "скриншотів") : "Знайдено \(filtered.count) з \(all.count)"
    }

    private func loadThumbnail(_ item: ScreenshotHistoryItem) {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: item.imagePath)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(item.imagePath)|\(mtime)"
        if thumbnailKeys[item.id] == key { return }
        thumbnailKeys[item.id] = key
        let path = item.imagePath
        let id = item.id
        Task.detached(priority: .utility) {
            let image = Thumbnails.load(path: path, maxPixels: 640) // 2× the card width: crisp on Retina
            await MainActor.run { [weak self] in self?.thumbnails[id] = image }
        }
    }

    func showSnackbar(_ text: String) {
        snackbarTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { snackbar = text }
        snackbarTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeIn(duration: 0.3)) { self?.snackbar = nil }
        }
    }

    // MARK: card actions

    func open(_ item: ScreenshotHistoryItem) {
        if !NSWorkspace.shared.open(URL(fileURLWithPath: item.imagePath)) {
            showSnackbar("Не вдалося відкрити файл")
        }
    }

    func showInFinder(_ item: ScreenshotHistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.imagePath)])
    }

    func copyMarkdown(_ item: ScreenshotHistoryItem) {
        let markdown = Clipboard.formatMarkdown(imagePath: item.imagePath, comment: item.transcribedText)
        showSnackbar(Clipboard.copy(markdown, imagePath: item.imagePath)
            ? "✓ Markdown і картинку скопійовано"
            : "Буфер обміну зайнятий іншою програмою — спробуйте ще раз")
    }

    func copyText(_ item: ScreenshotHistoryItem) {
        guard item.hasVoiceComment else { return }
        showSnackbar(Clipboard.copy(item.transcribedText)
            ? "✓ Текст коментаря скопійовано"
            : "Буфер обміну зайнятий іншою програмою — спробуйте ще раз")
    }

    func delete(_ item: ScreenshotHistoryItem) {
        let alert = NSAlert()
        alert.messageText = "Видалення"
        alert.informativeText = "Видалити цей скриншот разом із файлом?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Ні")
        alert.addButton(withTitle: "Так").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task {
            do {
                try await history.delete(id: item.id)
                showSnackbar("Скриншот видалено")
            } catch {
                Log.warn("[Gallery] Could not delete '\(item.imagePath)'", error)
                showSnackbar("Не вдалося видалити файл — можливо, він відкритий в іншій програмі")
            }
        }
    }

    // MARK: share links

    var selectionText: String {
        selected.count > ShareService.maxImages
            ? "Вибрано \(selected.count) — для посилання не більше \(ShareService.maxImages)"
            : "Вибрано: \(Formats.plural(selected.count, "знімок", "знімки", "знімків"))"
    }

    var canShareSelected: Bool { (1...ShareService.maxImages).contains(selected.count) && !sharing }

    func toggleSelected(_ item: ScreenshotHistoryItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func shareSelected() {
        let items = all.filter { selected.contains($0.id) }
        Task {
            if await createLink(items) { selected.removeAll() }
        }
    }

    /// The link button on a card: copies the existing link, or creates one for this screenshot.
    func shareItem(_ item: ScreenshotHistoryItem) {
        if item.hasActiveShare {
            copyLink(item)
        } else {
            Task { await createLink([item]) }
        }
    }

    func copyLink(_ item: ScreenshotHistoryItem) {
        guard let url = item.shareUrl, let until = item.shareExpiresAt else { return }
        showSnackbar(Clipboard.copy(url) ? "Посилання скопійовано · діє до \(Formats.dayMonth.string(from: until))" : "Буфер обміну зайнятий іншою програмою")
    }

    func deleteLink(_ item: ScreenshotHistoryItem) {
        guard let unshare else { return }
        Task {
            if await unshare(item) {
                showSnackbar("Посилання видалено — за ним більше нічого не відкриється")
            }
        }
    }

    @discardableResult
    private func createLink(_ items: [ScreenshotHistoryItem]) async -> Bool {
        guard let share, !sharing, !items.isEmpty else { return false }
        sharing = true
        defer { sharing = false }
        showSnackbar(items.count > 1 ? "Завантажую \(items.count) знімки…" : "Створюю посилання…")
        guard let result = await share(items) else { return false } // the app already explained what went wrong
        showSnackbar("Посилання скопійовано · діє до \(Formats.dayMonth.string(from: result.expiresAt))")
        return true
    }
}

struct GalleryView: View {
    @ObservedObject var model: GalleryModel
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 342, maximum: 342), spacing: 0, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ZStack(alignment: .bottom) {
                if model.filtered.isEmpty && model.loaded {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if RenderMode.snapshot {
                    grid.frame(maxHeight: .infinity, alignment: .top) // offscreen rendering can't draw a scroll view
                } else {
                    ScrollView { grid }
                }

                if !model.selected.isEmpty { selectionBar.padding(.bottom, 22) }
                if let text = model.snackbar {
                    Text(text)
                        .font(Theme.font(13, .semibold))
                        .foregroundColor(Theme.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(argb: 0xF21E1E25)))
                        .shadow(color: .black.opacity(0.45), radius: 15, y: 6)
                        .padding(.bottom, model.selected.isEmpty ? 22 : 96)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Theme.window)
        .foregroundColor(Theme.ink)
        .background(
            Button("") {
                searchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .onExitCommand {
            if !model.query.isEmpty { model.query = "" } else { model.closeWindow() }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            ForEach(model.filtered) { item in
                GalleryCard(item: item, model: model).padding(8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 90)
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                BrandMark(size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Wordmark(size: 17)
                    Text(model.countText).font(Theme.font(12)).foregroundColor(Theme.muted)
                }
            }
            .frame(minWidth: 200, alignment: .leading)
            Spacer(minLength: 20)
            HStack(spacing: 9) {
                GlyphIcon(icon: .search, size: 15, weight: 2).foregroundColor(Theme.muted)
                ZStack(alignment: .leading) {
                    if model.query.isEmpty {
                        Text("Пошук за коментарем або датою (⌘F)")
                            .font(Theme.font(13))
                            .foregroundColor(Theme.faint)
                            .allowsHitTesting(false)
                    }
                    if !RenderMode.snapshot {
                        TextField("", text: $model.query)
                            .textFieldStyle(.plain)
                            .font(Theme.font(13))
                            .foregroundColor(Theme.ink)
                            .focused($searchFocused)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 360, height: 38)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtle))
            Spacer(minLength: 20)
            HStack(spacing: 0) {
                Button(action: model.openFolder) {
                    HStack(spacing: 7) {
                        GlyphIcon(icon: .folder, size: 15, weight: 2)
                        Text("Папка")
                    }
                }
                .buttonStyle(OutlineButtonStyle())
                .help("Відкрити папку зі скриншотами")
                .padding(.trailing, 10)

                Button(action: model.startCapture) {
                    HStack(spacing: 7) {
                        GlyphIcon(icon: .camera, size: 15, weight: 2).foregroundColor(Theme.accent)
                        Text("Новий знімок")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Сховати галерею і зробити знімок")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        let searching = !model.all.isEmpty
        return VStack(spacing: 0) {
            BrandMark(size: 88).padding(.bottom, 18)
            Text(searching ? "Нічого не знайдено за «\(model.query.trimmingCharacters(in: .whitespaces))»" : "Ще немає скриншотів")
                .font(Theme.font(20, .semibold))
            Text(searching
                 ? "Спробуйте інше слово з коментаря або дату у форматі 09.10.2026."
                 : "Натисніть \(model.hotkeyText()) у будь-якій програмі, виділіть область, затисніть Пробіл і розкажіть, що не так.")
                .font(Theme.font(13.5))
                .foregroundColor(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .padding(.top, 7)
                .padding(.bottom, 20)
            if !searching {
                Button(action: model.startCapture) {
                    HStack(spacing: 8) {
                        GlyphIcon(icon: .camera, size: 15, weight: 2).foregroundColor(Theme.accent)
                        Text("Зробити перший знімок")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(height: 38, horizontalPadding: 16))
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 0) {
            Text(model.selectionText)
                .font(Theme.font(13.5, .semibold))
                .foregroundColor(Theme.ink)
                .padding(.leading, 10)
                .padding(.trailing, 16)
            Button(action: model.shareSelected) {
                HStack(spacing: 8) {
                    GlyphIcon(icon: .link, size: 15, weight: 2).foregroundColor(Theme.accent)
                    Text("Створити посилання")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canShareSelected)
            Button("Зняти вибір") { model.selected.removeAll() }
                .buttonStyle(TextPillButtonStyle())
                .padding(.leading, 6)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(argb: 0xF51C1C22)))
        .shadow(color: .black.opacity(0.45), radius: 15, y: 6)
    }
}

private struct GalleryCard: View {
    let item: ScreenshotHistoryItem
    @ObservedObject var model: GalleryModel
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            // the comment is a caption under the picture: plain text, no icon
            Text(item.hasVoiceComment ? item.transcribedText : "Без коментаря")
                .font(Theme.font(13))
                .lineSpacing(3)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.hasVoiceComment ? item.transcribedText : "")
            .foregroundColor(item.hasVoiceComment ? Color(rgb: 0xE6E6EC) : Color(rgb: 0x6B6B78))
            .frame(minHeight: 38, alignment: .top)
            .padding(.horizontal, 2)
            .padding(.top, 11)
            .padding(.bottom, 9)
            HStack(spacing: 6) {
                Button { model.copyMarkdown(item) } label: {
                    HStack(spacing: 6) {
                        GlyphIcon(icon: .copy, size: 14, weight: 2)
                        Text("Копіювати")
                    }
                }
                .buttonStyle(ChipButtonStyle())
                .help("Скопіювати Markdown і картинку")
                if item.hasVoiceComment {
                    Button("Текст") { model.copyText(item) }
                        .buttonStyle(ChipButtonStyle())
                        .help("Скопіювати лише текст коментаря")
                }
                Button { model.shareItem(item) } label: { GlyphIcon(icon: .link, size: 14, weight: 2) }
                    .buttonStyle(ChipButtonStyle())
                    .help(item.hasActiveShare ? "Копіювати посилання на цей знімок" : "Створити посилання на цей знімок (діє 30 днів)")
                Button { model.showInFinder(item) } label: { GlyphIcon(icon: .folder, size: 14, weight: 2) }
                    .buttonStyle(ChipButtonStyle())
                    .help("Показати у Finder")
                Button { model.delete(item) } label: { GlyphIcon(icon: .trash, size: 14, weight: 2) }
                    .buttonStyle(ChipButtonStyle(danger: true))
                    .help("Видалити")
            }
        }
        .padding(10)
        .frame(width: 326)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hover ? Color(rgb: 0x202028) : Color(rgb: 0x19191F)))
        .onHover { hover = $0 }
    }

    private var thumbnail: some View {
        ZStack {
            Color(argb: 0x0DFFFFFF)
            if let image = model.thumbnails[item.id] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 306, height: 184, alignment: .top)
                    .clipped()
            }
        }
        .frame(width: 306, height: 184)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) { badge(sizeText).padding(8) }
        .overlay(alignment: .bottomTrailing) { badge(item.displayDate, bold: true).padding(8) }
        .overlay(alignment: .topLeading) { selectBox.padding(8) }
        .overlay(alignment: .topTrailing) {
            if item.hasActiveShare { shareBadge.padding(8) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.open(item) }
        .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: item.imagePath)) ?? NSItemProvider() }
        .help("Клацніть — відкрити, перетягніть — вкласти у чат")
    }

    private var sizeText: String {
        if item.width > 0 && item.height > 0 { return "\(item.width)×\(item.height)" }
        let bytes = item.fileSizeBytes
        if bytes <= 0 { return "PNG" }
        if bytes < 1_048_576 { return "\(bytes / 1024) КБ" }
        return String(format: "%.1f МБ", Double(bytes) / 1_048_576).replacingOccurrences(of: ".", with: ",")
    }

    private func badge(_ text: String, bold: Bool = false) -> some View {
        Text(text)
            .font(Theme.font(11, bold ? .semibold : .regular))
            .foregroundColor(bold ? .white : Color(rgb: 0xE6E6EC))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(argb: 0xC70F0F13)))
    }

    private var selectBox: some View {
        let on = model.selected.contains(item.id)
        return Button { model.toggleSelected(item) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.accent : Color(argb: 0xA6101014))
                if !on {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(argb: 0x99FFFFFF), lineWidth: 1.5)
                }
                if on {
                    GlyphIcon(icon: .check, size: 16, weight: 3.2).foregroundColor(.white)
                }
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help("Вибрати — кілька знімків можна віддати одним посиланням")
    }

    private var shareBadge: some View {
        HStack(spacing: 0) {
            Button { model.copyLink(item) } label: {
                HStack(spacing: 5) {
                    GlyphIcon(icon: .link, size: 13, weight: 2.2).foregroundColor(Theme.accentLight)
                    Text(item.shareExpiresAt.map { "до \(Formats.dayMonthShort.string(from: $0))" } ?? "").font(Theme.font(11))
                }
            }
            .buttonStyle(TextPillButtonStyle(height: 26, horizontalPadding: 7, fontSize: 11))
            .help("Копіювати посилання\n\(item.shareUrl ?? "")")
            Button { model.deleteLink(item) } label: { GlyphIcon(icon: .close, size: 11, weight: 2.6) }
                .buttonStyle(GlassIconButtonStyle(width: 24, height: 26, cornerRadius: 8))
                .help("Видалити посилання: за ним більше нічого не відкриється")
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(argb: 0xD90F0F13)))
    }
}

/// The gallery window; while it is open the app shows in the Dock (like the window in the Windows taskbar).
@MainActor
final class GalleryWindowController: NSObject, NSWindowDelegate {
    let model: GalleryModel
    private(set) var window: NSWindow!
    var onClosed: (() -> Void)?

    init(model: GalleryModel) {
        self.model = model
        super.init()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "ScreenVoicer — Галерея"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(rgb: 0x0F0F13)
        window.minSize = CGSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: GalleryView(model: model).padding(.top, 22).background(Theme.window))
        window.center()
        window.setFrameAutosaveName("ScreenVoicerGallery")
        self.window = window
        model.closeWindow = { [weak window] in window?.performClose(nil) }
    }

    func bringToFront() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.load() }
    }

    func hide() { window.orderOut(nil) }
    func show() { window.orderFront(nil) }
    var isVisible: Bool { window.isVisible }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClosed?()
    }
}
