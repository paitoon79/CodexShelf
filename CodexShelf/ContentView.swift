//
//  ContentView.swift
//  CodexShelf
//
//  Created by Paitoon Wannanad on 13/6/2569 BE.
//

import SwiftUI
import SwiftData
import Foundation
import PDFKit
import Translation
import _Translation_SwiftUI
import UniformTypeIdentifiers
import WebKit
import NaturalLanguage
import AppKit

// MARK: - View Implementation
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Bookcase.name) private var bookcases: [Bookcase]
    @State private var selectedShelf: Shelf?
    @State private var selectedBookcaseName: String?
    @State private var librarySearchText = ""
    @AppStorage("systemLanguage") private var systemLanguage: SystemLanguage = .th
    @AppStorage("librarySortMode") private var librarySortMode: LibrarySortMode = .title
    @AppStorage("librarySortAscending") private var librarySortAscending = true

    private var orderedBookcases: [Bookcase] {
        bookcases.sorted {
            bookcaseIndex(for: $0.name) < bookcaseIndex(for: $1.name)
        }
    }

    private var visibleBookcases: [Bookcase] {
        if let selectedBookcaseName,
           let selectedBookcase = orderedBookcases.first(where: { $0.name == selectedBookcaseName }) {
            return [selectedBookcase]
        }

        return orderedBookcases.prefix(1).map { $0 }
    }

    private var continueReadingBooks: [Book] {
        let books = orderedBookcases
            .flatMap { $0.shelves }
            .flatMap { $0.importedBooks }
            .filter { $0.lastReadPage > 0 }

        let filteredBooks = librarySearchQuery.isEmpty ? books : books.filter(matchesLibrarySearch)

        return librarySortMode.sort(filteredBooks, ascending: librarySortAscending)
    }

    private var allImportedBooks: [Book] {
        orderedBookcases
            .flatMap { $0.shelves }
            .flatMap { $0.importedBooks }
    }

    private var filteredLibraryBookCount: Int {
        guard !librarySearchQuery.isEmpty else { return allImportedBooks.count }
        return allImportedBooks.filter(matchesLibrarySearch).count
    }

    private var librarySearchQuery: String {
        librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .acceptsFirstMouse()
        .onAppear {
            syncRequiredBookcases()
            purgeMockBooks()
            selectedBookcaseName = selectedBookcaseName ?? orderedBookcases.first?.name
            selectedShelf = selectedShelf ?? orderedBookcases.first.flatMap { orderedShelves(for: $0).first }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("หมวด")
                .font(.title.bold())
                .padding(.horizontal, 18)
                .padding(.top, 18)

            List(selection: $selectedBookcaseName) {
                ForEach(orderedBookcases) { bookcase in
                    Button {
                        selectedBookcaseName = bookcase.name
                        selectedShelf = orderedShelves(for: bookcase).first
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: bookcase.icon)
                                .foregroundStyle(bookcase.accentColor)

                            Text(sidebarTitle(for: bookcase))
                                .fontWeight(.medium)

                            Spacer()

                            Text("\(bookcase.shelves.reduce(0) { $0 + $1.importedBooks.count })")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                    .buttonStyle(ImmediatePlainButtonStyle())
                    .tag(bookcase.name)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    }

    private func sidebarTitle(for bookcase: Bookcase) -> String {
        L10n.text(bookcase.name, systemLanguage)
            .replacingOccurrences(of: "หมวดหมู่", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var detailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HeaderView(
                    language: $systemLanguage,
                    searchText: $librarySearchText,
                    sortMode: $librarySortMode,
                    sortAscending: $librarySortAscending,
                    resultCount: filteredLibraryBookCount,
                    totalCount: allImportedBooks.count
                )

                if !continueReadingBooks.isEmpty {
                    ContinueReadingView(
                        books: Array(continueReadingBooks.prefix(10)),
                        language: systemLanguage
                    )
                }

                ForEach(visibleBookcases) { bookcase in
                    BookcaseView(
                        bookcase: bookcase,
                        shelves: orderedShelves(for: bookcase),
                        language: systemLanguage,
                        selectedShelf: selectedShelf,
                        selectShelf: {
                            selectedBookcaseName = bookcase.name
                            selectedShelf = $0
                        },
                        importBook: { url, shelf in importBook(from: url, to: shelf) },
                        deleteBook: deleteBook,
                        searchText: librarySearchText,
                        sortMode: librarySortMode,
                        sortAscending: librarySortAscending
                    )
                }
            }
            .padding(24)
        }
        .background(
            LinearGradient(
                colors: [Color.black, Color(red: 0.10, green: 0.12, blue: 0.13)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func orderedShelves(for bookcase: Bookcase) -> [Shelf] {
        bookcase.shelves.sorted {
            shelfIndex($0.name, in: bookcase.name) < shelfIndex($1.name, in: bookcase.name)
        }
    }

    private func bookcaseIndex(for name: String) -> Int {
        BookcaseSeed.required.firstIndex { $0.name == name } ?? Int.max
    }

    private func shelfIndex(_ shelfName: String, in bookcaseName: String) -> Int {
        guard let seed = BookcaseSeed.required.first(where: { $0.name == bookcaseName }) else { return Int.max }
        return seed.shelves.firstIndex(of: shelfName) ?? Int.max
    }

    private func syncRequiredBookcases() {
        let requiredNames = Set(BookcaseSeed.required.map(\.name))
        for bookcase in bookcases where !requiredNames.contains(bookcase.name) {
            for shelf in bookcase.shelves {
                for book in shelf.books {
                    BookFileStore.removeStoredFiles(for: book)
                }
            }
            modelContext.delete(bookcase)
        }

        for seed in BookcaseSeed.required {
            let bookcase = bookcases.first { $0.name == seed.name } ?? {
                let newBookcase = Bookcase(name: seed.name, icon: seed.icon, accentHex: seed.accentHex, shelves: [])
                modelContext.insert(newBookcase)
                return newBookcase
            }()

            bookcase.icon = seed.icon
            bookcase.accentHex = seed.accentHex

            for shelfName in seed.shelves where !bookcase.shelves.contains(where: { $0.name == shelfName }) {
                bookcase.shelves.append(Shelf(name: shelfName))
            }
        }
    }

    private func purgeMockBooks() {
        for bookcase in bookcases {
            for shelf in bookcase.shelves {
                let mockBooks = shelf.books.filter { !$0.isReadableImport }
                for book in mockBooks {
                    modelContext.delete(book)
                }
            }
        }
    }

    private func importBook(from sourceURL: URL, to shelf: Shelf) {
        guard let format = EBookFormat(fileExtension: sourceURL.pathExtension) else { return }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let storedURL = try BookFileStore.copyIntoLibrary(sourceURL)
            let coverURL = try? CoverImageStore.createCover(for: storedURL, format: format)
            let colors = ["#D95D39", "#2A9D8F", "#4F6F52", "#577590", "#8E6BBE", "#C77D3B", "#3B7A9E"]
            let imported = Book(
                title: storedURL.deletingPathExtension().lastPathComponent,
                author: format.displayName,
                colorHex: colors.randomElement() ?? "#577590",
                filePath: storedURL.path,
                fileFormat: format.rawValue,
                coverImagePath: coverURL?.path
            )
            shelf.books.append(imported)
        } catch {
            print("Import failed: \(error)")
        }
    }

    private func deleteBook(_ book: Book) {
        BookFileStore.removeStoredFiles(for: book)
        modelContext.delete(book)
    }

    private func matchesLibrarySearch(_ book: Book) -> Bool {
        book.title.localizedCaseInsensitiveContains(librarySearchQuery)
            || book.author.localizedCaseInsensitiveContains(librarySearchQuery)
            || book.displayFormat.localizedCaseInsensitiveContains(librarySearchQuery)
    }

}

private struct HeaderView: View {
    @Binding var language: SystemLanguage
    @Binding var searchText: String
    @Binding var sortMode: LibrarySortMode
    @Binding var sortAscending: Bool
    let resultCount: Int
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 18) {
                Label("Codex Shelf", systemImage: "books.vertical.fill")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                Spacer()

                Picker(L10n.text("translate_to", language), selection: $language) {
                    ForEach(SystemLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 230)
            }

            Text(L10n.text("app_subtitle", language))
                .font(.headline)
                .foregroundStyle(.white.opacity(0.72))

            HStack(spacing: 12) {
                LibrarySearchField(
                    text: $searchText,
                    placeholder: L10n.text("library_search", language)
                )
                .frame(width: 420, height: 34)

                Picker(L10n.text("sort_by", language), selection: $sortMode) {
                    ForEach(LibrarySortMode.allCases) { mode in
                        Label("\(L10n.text("sort_by", language)): \(mode.title(language))", systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 240)

                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(ImmediatePlainButtonStyle())
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                .help(sortAscending ? L10n.text("sort_ascending", language) : L10n.text("sort_descending", language))

                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(searchResultText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.68))
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchResultText: String {
        L10n.text("search_results", language)
            .replacingOccurrences(of: "%d", with: "\(resultCount)", options: [], range: nil)
            .replacingOccurrences(of: "%t", with: "\(totalCount)", options: [], range: nil)
    }
}

private struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.textColor = .white
        field.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        field.backgroundColor = NSColor.white.withAlphaComponent(0.10)
        (field.cell as? NSSearchFieldCell)?.backgroundColor = NSColor.white.withAlphaComponent(0.10)
        field.cell?.isScrollable = true
        field.bezelStyle = .roundedBezel
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text = field.stringValue
        }
    }
}

private enum LibrarySortMode: String, CaseIterable, Identifiable {
    case title
    case format
    case progress

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .title:
            return "textformat.abc"
        case .format:
            return "doc.on.doc"
        case .progress:
            return "chart.line.uptrend.xyaxis"
        }
    }

    func title(_ language: SystemLanguage) -> String {
        switch self {
        case .title:
            return L10n.text("sort_title", language)
        case .format:
            return L10n.text("sort_format", language)
        case .progress:
            return L10n.text("sort_progress", language)
        }
    }

    func sort(_ books: [Book], ascending: Bool) -> [Book] {
        let sortedBooks = books.sorted { first, second in
            switch self {
            case .title:
                return first.title.localizedStandardCompare(second.title) == .orderedAscending
            case .format:
                let formatOrder = first.displayFormat.localizedStandardCompare(second.displayFormat)
                if formatOrder != .orderedSame {
                    return formatOrder == .orderedAscending
                }
                return first.title.localizedStandardCompare(second.title) == .orderedAscending
            case .progress:
                if first.lastReadPage != second.lastReadPage {
                    return first.lastReadPage > second.lastReadPage
                }
                return first.title.localizedStandardCompare(second.title) == .orderedAscending
            }
        }

        return ascending ? sortedBooks : Array(sortedBooks.reversed())
    }
}

private struct ContinueReadingView: View {
    let books: [Book]
    let language: SystemLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text("continue_reading", language), systemImage: "play.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(books) { book in
                        ContinueReadingBookView(book: book, language: language)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ContinueReadingBookView: View {
    let book: Book
    let language: SystemLanguage
    @State private var isRenaming = false
    @State private var draftTitle = ""

    var body: some View {
        NavigationLink {
            BookReaderView(book: book, language: language)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                BookSpineView(book: book)
                    .frame(width: 64, height: 92, alignment: .bottomLeading)

                Text(book.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(width: 110, alignment: .leading)

                Text("\(L10n.text("page", language)) \(book.lastReadPage + 1)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(12)
            .frame(width: 132, height: 166, alignment: .topLeading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(ImmediatePlainButtonStyle())
        .contextMenu {
            BookFileContextActions(book: book, language: language)

            Divider()

            Button {
                draftTitle = book.title
                isRenaming = true
            } label: {
                Label(L10n.text("rename_book", language), systemImage: "pencil")
            }

            Button {
                book.lastReadPage = 0
            } label: {
                Label(L10n.text("reset_reading_progress", language), systemImage: "arrow.counterclockwise")
            }
        }
        .alert(L10n.text("rename_book", language), isPresented: $isRenaming) {
            TextField(L10n.text("book_title", language), text: $draftTitle)
            Button(L10n.text("save", language)) {
                saveTitle()
            }
            Button(L10n.text("cancel", language), role: .cancel) {}
        }
    }

    private func saveTitle() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        book.title = title
    }
}

private struct BookFileContextActions: View {
    let book: Book
    let language: SystemLanguage

    var body: some View {
        if book.fileURL != nil {
            Button {
                BookFileActions.revealInFinder(book)
            } label: {
                Label(L10n.text("show_in_finder", language), systemImage: "folder")
            }

            Button {
                BookFileActions.copyPath(book)
            } label: {
                Label(L10n.text("copy_file_path", language), systemImage: "doc.on.doc")
            }
        }
    }
}

private enum BookFileActions {
    static func revealInFinder(_ book: Book) {
        guard let url = book.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyPath(_ book: Book) {
        guard let path = book.fileURL?.path else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}

private struct BookcaseView: View {
    let bookcase: Bookcase
    let shelves: [Shelf]
    let language: SystemLanguage
    let selectedShelf: Shelf?
    let selectShelf: (Shelf) -> Void
    let importBook: (URL, Shelf) -> Void
    let deleteBook: (Book) -> Void
    let searchText: String
    let sortMode: LibrarySortMode
    let sortAscending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: bookcase.icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(bookcase.accentColor, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(bookcase.name, language))
                        .font(.title2.bold())
                    Text("\(shelves.count) \(L10n.text("shelves_unit", language))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background {
                WoodTextureBackground(tint: Color(red: 0.42, green: 0.22, blue: 0.10), darken: 0.34)
            }
            .foregroundStyle(.white)

            VStack(spacing: 0) {
                ForEach(shelves) { shelf in
                    ShelfRowView(
                        shelf: shelf,
                        accentColor: bookcase.accentColor,
                        language: language,
                        isSelected: shelf.persistentModelID == selectedShelf?.persistentModelID,
                        selectShelf: { selectShelf(shelf) },
                        importBook: { importBook($0, shelf) },
                        deleteBook: deleteBook,
                        searchText: searchText,
                        sortMode: sortMode,
                        sortAscending: sortAscending
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .background {
                WoodTextureBackground(tint: Color(red: 0.58, green: 0.34, blue: 0.16), darken: 0.08)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 10)
    }
}

private struct ShelfRowView: View {
    let shelf: Shelf
    let accentColor: Color
    let language: SystemLanguage
    let isSelected: Bool
    let selectShelf: () -> Void
    let importBook: (URL) -> Void
    let deleteBook: (Book) -> Void
    let searchText: String
    let sortMode: LibrarySortMode
    let sortAscending: Bool
    @State private var isImporting = false
    @State private var shelfScrollIndex = 0

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedBooks: [Book] {
        let books = normalizedSearchText.isEmpty ? shelf.importedBooks : shelf.importedBooks.filter { book in
            book.title.localizedCaseInsensitiveContains(normalizedSearchText)
                || book.author.localizedCaseInsensitiveContains(normalizedSearchText)
                || book.displayFormat.localizedCaseInsensitiveContains(normalizedSearchText)
        }

        return sortMode.sort(books, ascending: sortAscending)
    }

    private var showsShelfScrollButtons: Bool {
        displayedBooks.count > 5
    }

    private var shelfCountText: String {
        if normalizedSearchText.isEmpty {
            return "\(shelf.importedBooks.count) \(L10n.text("books_unit", language))"
        }

        return "\(displayedBooks.count)/\(shelf.importedBooks.count) \(L10n.text("books_unit", language))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 14) {
                Button(action: selectShelf) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text(shelf.name, language))
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(shelfCountText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 128, alignment: .leading)
                    .padding(.vertical, 12)
                }
                .buttonStyle(ImmediatePlainButtonStyle())

                ScrollViewReader { proxy in
                    HStack(alignment: .center, spacing: 8) {
                        if showsShelfScrollButtons {
                            shelfScrollButton(systemName: "chevron.left") {
                                scrollShelf(by: -4, proxy: proxy)
                            }
                            .disabled(shelfScrollIndex == 0)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .bottom, spacing: 8) {
                                ForEach(Array(displayedBooks.enumerated()), id: \.element.persistentModelID) { index, book in
                                    BookShelfItemView(book: book, language: language, deleteBook: { deleteBook(book) })
                                        .id(index)
                                }

                                AddBookCoverButton(
                                    shelfName: shelf.name,
                                    accentColor: accentColor,
                                    language: language,
                                    isImporting: $isImporting
                                )
                                .id(displayedBooks.count)
                            }
                            .frame(minHeight: 88, alignment: .bottom)
                        }

                        if showsShelfScrollButtons {
                            shelfScrollButton(systemName: "chevron.right") {
                                scrollShelf(by: 4, proxy: proxy)
                            }
                            .disabled(shelfScrollIndex >= displayedBooks.count)
                        }
                    }
                    .onChange(of: displayedBooks.count) { _, count in
                        shelfScrollIndex = min(shelfScrollIndex, count)
                    }
                    .onChange(of: normalizedSearchText) { _, _ in
                        shelfScrollIndex = 0
                        proxy.scrollTo(0, anchor: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: EBookFormat.allowedContentTypes,
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result {
                    urls.forEach(importBook)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .background {
                ZStack {
                    WoodTextureBackground(tint: Color(red: 0.72, green: 0.52, blue: 0.28), darken: 0.0)
                    Color(red: 0.98, green: 0.91, blue: 0.74).opacity(0.42)
                    if isSelected {
                        accentColor.opacity(0.22)
                    }
                }
            }

            RoundedRectangle(cornerRadius: 4)
                .fill(ImagePaint(image: Image("WoodTexture"), sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 0.18))
                .overlay(Color(red: 0.22, green: 0.11, blue: 0.05).opacity(0.55))
                .frame(height: 12)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
    }

    private func shelfScrollButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 54)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
        }
        .buttonStyle(ImmediatePlainButtonStyle())
    }

    private func scrollShelf(by offset: Int, proxy: ScrollViewProxy) {
        let maxIndex = displayedBooks.count
        let nextIndex = min(max(shelfScrollIndex + offset, 0), maxIndex)
        shelfScrollIndex = nextIndex

        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(nextIndex, anchor: .leading)
        }
    }
}

private struct WoodTextureBackground: View {
    let tint: Color
    let darken: Double

    var body: some View {
        GeometryReader { proxy in
            Image("WoodTexture")
                .resizable(resizingMode: .tile)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay(tint.opacity(0.34).blendMode(.multiply))
                .overlay(Color.black.opacity(darken))
                .clipped()
        }
    }
}

private struct BookSpineView: View {
    let book: Book

    var body: some View {
        if let coverImage = book.coverImage {
            Image(nsImage: coverImage)
                .resizable()
                .scaledToFill()
                .frame(width: 54, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.black.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
        } else {
            VStack(spacing: 5) {
                Image(systemName: book.formatIconName)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(book.displayFormat)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                Text(book.title)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .padding(5)
            .frame(width: 54, height: 82)
            .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.black.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
        }
    }
}

private struct BookShelfItemView: View {
    let book: Book
    let language: SystemLanguage
    let deleteBook: () -> Void
    @State private var isConfirmingDelete = false
    @State private var isRenaming = false
    @State private var draftTitle = ""

    var body: some View {
        NavigationLink {
            BookReaderView(book: book, language: language)
        } label: {
            BookSpineView(book: book)
        }
        .buttonStyle(ImmediatePlainButtonStyle())
        .contextMenu {
            BookFileContextActions(book: book, language: language)

            Divider()

            Button {
                draftTitle = book.title
                isRenaming = true
            } label: {
                Label(L10n.text("rename_book", language), systemImage: "pencil")
            }

            if book.lastReadPage > 0 {
                Divider()

                Button {
                    book.lastReadPage = 0
                } label: {
                    Label(L10n.text("reset_reading_progress", language), systemImage: "arrow.counterclockwise")
                }

                Divider()
            }

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label(L10n.text("delete_from_shelf", language), systemImage: "trash")
            }
        }
        .confirmationDialog(
            L10n.text("delete_confirm", language),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.text("delete_from_shelf", language), role: .destructive) {
                deleteBook()
            }
            Button(L10n.text("cancel", language), role: .cancel) {}
        } message: {
            Text(book.title)
        }
        .alert(L10n.text("rename_book", language), isPresented: $isRenaming) {
            TextField(L10n.text("book_title", language), text: $draftTitle)
            Button(L10n.text("save", language)) {
                saveTitle()
            }
            Button(L10n.text("cancel", language), role: .cancel) {}
        }
    }

    private func saveTitle() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        book.title = title
    }
}

private struct AddBookCoverButton: View {
    let shelfName: String
    let accentColor: Color
    let language: SystemLanguage
    @Binding var isImporting: Bool

    var body: some View {
        Button(action: { isImporting = true }) {
            VStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(accentColor, in: Circle())

                Text(L10n.text("add", language))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color(red: 0.35, green: 0.25, blue: 0.06))
            }
            .frame(width: 54, height: 82)
            .background(
                LinearGradient(
                    colors: [Color(red: 1.0, green: 0.83, blue: 0.25), Color(red: 0.92, green: 0.62, blue: 0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 6)
                    .padding(.vertical, 5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.black.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
        }
        .buttonStyle(ImmediatePlainButtonStyle())
        .help(L10n.importHelp(shelfName: L10n.text(shelfName, language), language))
    }
}

private struct BookReaderView: View {
    let book: Book
    let language: SystemLanguage
    @State private var selectedText = ""
    @State private var sourceText = ""
    @State private var translatedText = ""
    @State private var translationError: String?
    @State private var translationStatusMessage: String?
    @State private var isTranslationPresented = false
    @State private var isTranslating = false
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var autoTranslationTask: Task<Void, Never>?
    @State private var readerPageIndex = 0
    @State private var readerPageCount = 0
    @State private var readerZoomScale = 1.0
    @State private var readerSearchText = ""
    @State private var readerSearchStatus: String?
    @State private var readerPageInput = ""
    @State private var readerCommand: ReaderCommand?
    @State private var isTOCPresented = false
    @State private var isBookmarksPresented = false
    @State private var readerTOCItems: [ReaderTOCItem] = []
    @State private var bookmarkedPages: Set<Int> = []
    @State private var didCopySelection = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var isReadingSettingsPresented = false
    @State private var readerTheme: ReaderTheme = .dark
    @State private var readerContentWidth = 800.0
    @FocusState private var focusedReaderField: ReaderFocusField?
    @Environment(\.dismiss) private var dismiss

    private var format: EBookFormat? {
        EBookFormat(rawValue: book.fileFormat)
    }

    private var supportsReaderToolbar: Bool {
        format != nil
    }

    private var supportsTextTools: Bool {
        format == .pdf || format == .epub
    }

    var body: some View {
        VStack(spacing: 0) {
            if supportsReaderToolbar {
                readerToolbar
                Divider()
            }

            Group {
                if let url = book.fileURL, let format {
                    switch format {
                    case .pdf:
                        PDFReaderView(
                            url: url,
                            selectedText: $selectedText,
                            pageIndex: $readerPageIndex,
                            pageCount: $readerPageCount,
                            zoomScale: $readerZoomScale,
                            searchText: $readerSearchText,
                            searchStatus: $readerSearchStatus,
                            command: $readerCommand,
                            tocItems: $readerTOCItems,
                            readingTheme: readerTheme,
                            onTranslate: startTranslation
                        )
                    case .cbz:
                        CBZReaderView(
                            url: url,
                            language: language,
                            pageIndex: $readerPageIndex,
                            pageCount: $readerPageCount,
                            zoomScale: $readerZoomScale,
                            readingTheme: readerTheme,
                            command: $readerCommand
                        )
                    case .epub:
                        EPUBReaderView(
                            url: url,
                            language: language,
                            selectedText: $selectedText,
                            pageIndex: $readerPageIndex,
                            pageCount: $readerPageCount,
                            zoomScale: $readerZoomScale,
                            searchText: $readerSearchText,
                            searchStatus: $readerSearchStatus,
                            command: $readerCommand,
                            tocItems: $readerTOCItems,
                            readingTheme: readerTheme,
                            contentWidth: readerContentWidth,
                            onTranslate: startTranslation
                        )
                    }
                } else {
                    ContentUnavailableView(
                        L10n.text("no_file_title", language),
                        systemImage: "book.closed",
                        description: Text(L10n.text("no_file_description", language))
                    )
                }
            }
        }
        .navigationTitle(book.title)
        .translationTask(translationConfiguration) { session in
            await translateSelection(using: session)
        }
        .onChange(of: selectedText) { _, newValue in
            scheduleAutoTranslation(for: newValue)
        }
        .onChange(of: readerPageIndex) { _, newValue in
            book.lastReadPage = newValue
            syncReaderPageInput()
        }
        .onChange(of: readerZoomScale) { _, _ in
            saveZoomScale()
        }
        .onChange(of: readerTheme) { _, _ in
            saveReaderAppearance()
        }
        .onChange(of: readerContentWidth) { _, _ in
            saveReaderAppearance()
        }
        .onChange(of: readerPageCount) { _, _ in
            syncReaderPageInput()
        }
        .onChange(of: readerSearchText) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                readerSearchStatus = nil
            }
        }
        .onChange(of: bookmarkedPages) { _, _ in
            saveBookmarks()
        }
        .onAppear {
            readerPageIndex = max(book.lastReadPage, 0)
            loadZoomScale()
            loadReaderAppearance()
            readerTOCItems = []
            loadBookmarks()
            syncReaderPageInput()
        }
        .onDisappear {
            autoTranslationTask?.cancel()
            copyFeedbackTask?.cancel()
        }
        .sheet(isPresented: $isTranslationPresented) {
            TranslationResultView(
                language: language,
                sourceText: sourceText,
                translatedText: translatedText,
                errorMessage: translationError,
                statusMessage: translationStatusMessage,
                isTranslating: isTranslating
            )
        }
    }

    private var readerToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
            readerIconButton("chevron.left", help: "Back") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])

            readerIconButton("list.bullet", help: "Table of contents") {
                isTOCPresented.toggle()
            }
            .popover(isPresented: $isTOCPresented, arrowEdge: .bottom) {
                ReaderTOCView(
                    pageCount: readerPageCount,
                    currentPageIndex: readerPageIndex,
                    items: readerTOCItems,
                    language: language
                ) { page in
                    readerPageIndex = page
                    sendReaderCommand(.goToPage(page))
                    isTOCPresented = false
                }
                .frame(width: 260, height: 360)
            }

            Divider().frame(height: 24)

            readerIconButton("chevron.left", help: L10n.text("previous", language)) {
                sendReaderCommand(.previousPage)
            }
            .disabled(readerPageIndex <= 0)
            .keyboardShortcut(.leftArrow, modifiers: [.command])

            Text(readerPageCount > 0 ? "\(readerPageIndex + 1) / \(readerPageCount)" : "- / -")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 78)

            Text(readingProgressText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48)

            HStack(spacing: 5) {
                TextField("", text: $readerPageInput)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(width: 42)
                    .onSubmit(goToTypedPage)

                Text("/")
                    .foregroundStyle(.secondary)

                Text("\(max(readerPageCount, 0))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .disabled(readerPageCount <= 0)

            readerIconButton("chevron.right", help: L10n.text("next", language)) {
                sendReaderCommand(.nextPage)
            }
            .disabled(readerPageCount == 0 || readerPageIndex >= readerPageCount - 1)
            .keyboardShortcut(.rightArrow, modifiers: [.command])

            if readerPageCount > 1 {
                Slider(
                    value: Binding(
                        get: { Double(min(readerPageIndex + 1, readerPageCount)) },
                        set: { value in
                            let page = min(max(Int(value.rounded()) - 1, 0), readerPageCount - 1)
                            guard page != readerPageIndex else { return }
                            readerPageIndex = page
                            sendReaderCommand(.goToPage(page))
                        }
                    ),
                    in: 1...Double(readerPageCount),
                    step: 1
                )
                .frame(width: 130)
            } else {
                Capsule()
                    .fill(.secondary.opacity(0.14))
                    .frame(width: 130, height: 6)
            }

            Divider().frame(height: 24)

            HStack(spacing: 6) {
                readerIconButton("magnifyingglass", help: L10n.text("search", language)) {
                    focusedReaderField = .search
                }
                .keyboardShortcut("f", modifiers: [.command])

                TextField(L10n.text("search", language), text: $readerSearchText)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
                    .focused($focusedReaderField, equals: .search)
                    .onSubmit {
                        sendReaderCommand(.search)
                    }
                if !readerSearchText.isEmpty {
                    readerIconButton("chevron.up", help: L10n.text("find_previous", language)) {
                        sendReaderCommand(.previousSearchResult)
                    }

                    readerIconButton("chevron.down", help: L10n.text("find_next", language)) {
                        sendReaderCommand(.nextSearchResult)
                    }

                    readerIconButton("xmark.circle.fill", help: L10n.text("clear_search", language)) {
                        readerSearchText = ""
                        readerSearchStatus = nil
                        sendReaderCommand(.clearSearch)
                    }
                }
                if let readerSearchStatus {
                    Text(readerSearchStatus)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .disabled(!supportsTextTools)
            .help(supportsTextTools ? L10n.text("search", language) : L10n.text("text_tools_unavailable", language))

            Divider().frame(height: 24)

            readerIconButton("textformat.size.smaller", help: L10n.text("zoom_out", language)) {
                readerZoomScale = max(0.8, readerZoomScale - 0.1)
                sendReaderCommand(.setZoom(readerZoomScale))
            }
            .keyboardShortcut("-", modifiers: [.command])

            readerIconButton("textformat.size.larger", help: L10n.text("zoom_in", language)) {
                readerZoomScale = min(1.8, readerZoomScale + 0.1)
                sendReaderCommand(.setZoom(readerZoomScale))
            }
            .keyboardShortcut("=", modifiers: [.command])

            Text("\(Int(readerZoomScale * 100))%")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42)

            readerIconButton("arrow.counterclockwise", help: L10n.text("reset_zoom", language)) {
                readerZoomScale = 1.0
                sendReaderCommand(.setZoom(readerZoomScale))
            }
            .keyboardShortcut("0", modifiers: [.command])

            Divider().frame(height: 24)

            readerIconButton("textformat", help: L10n.text("reading_settings", language)) {
                isReadingSettingsPresented.toggle()
            }
            .popover(isPresented: $isReadingSettingsPresented, arrowEdge: .bottom) {
                ReaderSettingsView(
                    language: language,
                    theme: $readerTheme,
                    contentWidth: $readerContentWidth
                )
                .frame(width: 300)
            }

            Divider().frame(height: 24)

            readerIconButton(bookmarkedPages.contains(readerPageIndex) ? "bookmark.fill" : "bookmark", help: L10n.text("bookmark", language)) {
                if bookmarkedPages.contains(readerPageIndex) {
                    bookmarkedPages.remove(readerPageIndex)
                } else {
                    bookmarkedPages.insert(readerPageIndex)
                }
                book.lastReadPage = readerPageIndex
            }
            .keyboardShortcut("d", modifiers: [.command])

            readerIconButton("bookmark.square", help: L10n.text("bookmarks", language)) {
                isBookmarksPresented.toggle()
            }
            .popover(isPresented: $isBookmarksPresented, arrowEdge: .bottom) {
                ReaderBookmarksView(
                    bookmarkedPages: bookmarkedPages,
                    currentPageIndex: readerPageIndex,
                    tocItems: readerTOCItems,
                    language: language
                ) { page in
                    readerPageIndex = page
                    sendReaderCommand(.goToPage(page))
                    isBookmarksPresented = false
                }
                .frame(width: 240, height: 300)
            }

            Spacer()

            readerIconButton(didCopySelection ? "checkmark" : "doc.on.doc", help: L10n.text("copy_selection", language)) {
                copySelectedText()
            }
            .disabled(selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button {
                startTranslation()
            } label: {
                Label(L10n.text("translate_selection", language), systemImage: "character.bubble")
            }
            .disabled(!supportsTextTools || selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(ImmediatePlainButtonStyle())
            .keyboardShortcut("t", modifiers: [.command])
            .help(supportsTextTools ? L10n.text("translate_selection", language) : L10n.text("text_tools_unavailable", language))
        }
        .frame(minWidth: 980, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(Color(red: 0.10, green: 0.13, blue: 0.14))
    }

    private func readerIconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(ImmediatePlainButtonStyle())
        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .help(help)
    }

    private func sendReaderCommand(_ kind: ReaderCommand.Kind) {
        readerCommand = ReaderCommand(kind: kind)
    }

    private var bookmarkStorageKey: String {
        let identity = book.filePath ?? book.title
        return "CodexShelf.bookmarks.\(identity)"
    }

    private var zoomStorageKey: String {
        let identity = book.filePath ?? book.title
        return "CodexShelf.zoom.\(identity)"
    }

    private var appearanceStorageKey: String {
        let identity = book.filePath ?? book.title
        return "CodexShelf.appearance.\(identity)"
    }

    private var readingProgressText: String {
        guard readerPageCount > 0 else { return "0%" }
        let progress = Double(readerPageIndex + 1) / Double(readerPageCount)
        return "\(Int((progress * 100).rounded()))%"
    }

    private func syncReaderPageInput() {
        readerPageInput = readerPageCount > 0 ? "\(min(readerPageIndex + 1, readerPageCount))" : ""
    }

    private func goToTypedPage() {
        guard readerPageCount > 0,
              let typedPage = Int(readerPageInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            syncReaderPageInput()
            return
        }

        let page = min(max(typedPage - 1, 0), readerPageCount - 1)
        readerPageIndex = page
        sendReaderCommand(.goToPage(page))
        syncReaderPageInput()
    }

    private func copySelectedText() {
        let text = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopySelection = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                didCopySelection = false
            }
        }
    }

    private func loadBookmarks() {
        bookmarkedPages = Set(UserDefaults.standard.array(forKey: bookmarkStorageKey) as? [Int] ?? [])
    }

    private func saveBookmarks() {
        UserDefaults.standard.set(bookmarkedPages.sorted(), forKey: bookmarkStorageKey)
    }

    private func loadZoomScale() {
        let savedZoom = UserDefaults.standard.double(forKey: zoomStorageKey)
        if savedZoom > 0 {
            readerZoomScale = min(max(savedZoom, 0.8), 1.8)
            sendReaderCommand(.setZoom(readerZoomScale))
        }
    }

    private func saveZoomScale() {
        UserDefaults.standard.set(readerZoomScale, forKey: zoomStorageKey)
    }

    private func loadReaderAppearance() {
        guard let data = UserDefaults.standard.dictionary(forKey: appearanceStorageKey) else { return }

        if let rawTheme = data["theme"] as? String,
           let savedTheme = ReaderTheme(rawValue: rawTheme) {
            readerTheme = savedTheme
        }

        if let width = data["contentWidth"] as? Double, width > 0 {
            readerContentWidth = min(max(width, 560), 1100)
        }
    }

    private func saveReaderAppearance() {
        UserDefaults.standard.set(
            [
                "theme": readerTheme.rawValue,
                "contentWidth": readerContentWidth
            ],
            forKey: appearanceStorageKey
        )
    }

    private func scheduleAutoTranslation(for text: String) {
        autoTranslationTask?.cancel()

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard format == .pdf || format == .epub, !trimmedText.isEmpty else { return }

        autoTranslationTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard currentText == trimmedText else { return }
                guard sourceText != trimmedText || !isTranslationPresented else { return }
                startTranslation()
            }
        }
    }

    private func startTranslation() {
        let trimmedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        sourceText = trimmedText
        translatedText = ""
        translationError = nil
        translationStatusMessage = language == .cn ? "กำลังดาวน์โหลดโมเดลภาษาจีน..." : nil
        isTranslating = true
        isTranslationPresented = true

        // Try to detect source language locally to avoid relying on remote LID preflight.
        var detectedSource: Locale.Language? = nil
        if #available(macOS 12.0, *) {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(trimmedText)
            if let nl = recognizer.dominantLanguage {
                detectedSource = Locale.Language(languageCode: Locale.LanguageCode(nl.rawValue))
            }
        }

        if translationConfiguration == nil || translationConfiguration?.target != language.translationLanguage {
            translationConfiguration = TranslationSession.Configuration(source: detectedSource, target: language.translationLanguage)
        } else if translationConfiguration?.source == nil, let detected = detectedSource {
            // fill in detected source when configuration exists without source
            translationConfiguration = TranslationSession.Configuration(source: detected, target: language.translationLanguage)
        }
        translationConfiguration?.invalidate()
    }

    private func translateSelection(using session: TranslationSession) async {
        guard !sourceText.isEmpty else { return }

        do {
            try await session.prepareTranslation()
            let response = try await session.translate(sourceText)
            await MainActor.run {
                translatedText = response.targetText
                translationError = nil
                translationStatusMessage = nil
                isTranslating = false
            }
        } catch {
            await MainActor.run {
                translationError = (language == .cn && error.localizedDescription.contains("preflight")) ? "ไม่สามารถแปลภาษาจีนได้ในขณะนี้ อาจต้องดาวน์โหลดโมเดลก่อน" : error.localizedDescription
                translationStatusMessage = nil
                isTranslating = false
            }
        }
    }
}

private struct ReaderCommand: Equatable {
    enum Kind: Equatable {
        case previousPage
        case nextPage
        case goToPage(Int)
        case search
        case previousSearchResult
        case nextSearchResult
        case clearSearch
        case setZoom(Double)
    }

    let id = UUID()
    let kind: Kind
}

private enum ReaderFocusField: Hashable {
    case search
}

private enum ReaderTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light
    case sepia

    var id: String { rawValue }

    func title(_ language: SystemLanguage) -> String {
        switch self {
        case .system:
            return L10n.text("theme_system", language)
        case .dark:
            return L10n.text("theme_dark", language)
        case .light:
            return L10n.text("theme_light", language)
        case .sepia:
            return L10n.text("theme_sepia", language)
        }
    }

    var backgroundColor: Color {
        switch self {
        case .system, .dark:
            return Color(red: 0.09, green: 0.10, blue: 0.10)
        case .light:
            return Color(red: 0.92, green: 0.93, blue: 0.92)
        case .sepia:
            return Color(red: 0.78, green: 0.68, blue: 0.53)
        }
    }

    var cssBackground: String {
        switch self {
        case .system, .dark:
            return "#141617"
        case .light:
            return "#f2f3f1"
        case .sepia:
            return "#d9c59f"
        }
    }

    var cssPage: String {
        switch self {
        case .system, .dark:
            return "#181b1c"
        case .light:
            return "#ffffff"
        case .sepia:
            return "#f3e5c7"
        }
    }

    var cssText: String {
        switch self {
        case .system, .dark:
            return "#e8eceb"
        case .light:
            return "#1d2224"
        case .sepia:
            return "#33261b"
        }
    }

    var cssColorScheme: String {
        switch self {
        case .system:
            return "light dark"
        case .dark:
            return "dark"
        case .light, .sepia:
            return "light"
        }
    }

    var nsBackgroundColor: NSColor {
        switch self {
        case .system, .dark:
            return NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.10, alpha: 1)
        case .light:
            return NSColor(calibratedRed: 0.92, green: 0.93, blue: 0.92, alpha: 1)
        case .sepia:
            return NSColor(calibratedRed: 0.78, green: 0.68, blue: 0.53, alpha: 1)
        }
    }
}

private struct ReaderSettingsView: View {
    let language: SystemLanguage
    @Binding var theme: ReaderTheme
    @Binding var contentWidth: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.text("reading_settings", language), systemImage: "textformat")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("theme", language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker(L10n.text("theme", language), selection: $theme) {
                    ForEach(ReaderTheme.allCases) { theme in
                        Text(theme.title(language)).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.text("page_width", language))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(Int(contentWidth)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(value: $contentWidth, in: 560...1100, step: 20)
            }
        }
        .padding(16)
    }
}

private struct ReaderTOCItem: Identifiable, Equatable {
    let id: String
    let title: String
    let pageIndex: Int
    let level: Int

    init(title: String, pageIndex: Int, level: Int) {
        self.title = title
        self.pageIndex = pageIndex
        self.level = level
        self.id = "\(level)-\(pageIndex)-\(title)"
    }
}

private struct ReaderTOCView: View {
    let pageCount: Int
    let currentPageIndex: Int
    let items: [ReaderTOCItem]
    let language: SystemLanguage
    let selectPage: (Int) -> Void

    var body: some View {
        List {
            if pageCount == 0 {
                Text(L10n.text("no_pages", language))
                    .foregroundStyle(.secondary)
            } else if !items.isEmpty {
                ForEach(items) { item in
                    Button {
                        selectPage(item.pageIndex)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.pageIndex == currentPageIndex ? "bookmark.fill" : "list.bullet.indent")
                                .foregroundStyle(item.pageIndex == currentPageIndex ? .yellow : .secondary)
                            Text(item.title)
                                .lineLimit(1)
                            Spacer()
                            Text("\(item.pageIndex + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, CGFloat(max(item.level, 0) * 14))
                    }
                    .buttonStyle(ImmediatePlainButtonStyle())
                }
            } else {
                ForEach(0..<pageCount, id: \.self) { page in
                    Button {
                        selectPage(page)
                    } label: {
                        HStack {
                            Image(systemName: page == currentPageIndex ? "bookmark.fill" : "doc.text")
                                .foregroundStyle(page == currentPageIndex ? .yellow : .secondary)
                            Text("\(L10n.text("page", language)) \(page + 1)")
                            Spacer()
                        }
                    }
                    .buttonStyle(ImmediatePlainButtonStyle())
                }
            }
        }
    }
}

private struct ReaderBookmarksView: View {
    let bookmarkedPages: Set<Int>
    let currentPageIndex: Int
    let tocItems: [ReaderTOCItem]
    let language: SystemLanguage
    let selectPage: (Int) -> Void

    var body: some View {
        List {
            if bookmarkedPages.isEmpty {
                Text(L10n.text("no_bookmarks", language))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bookmarkedPages.sorted(), id: \.self) { page in
                    Button {
                        selectPage(page)
                    } label: {
                        HStack {
                            Image(systemName: page == currentPageIndex ? "bookmark.fill" : "bookmark")
                                .foregroundStyle(page == currentPageIndex ? .yellow : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(for: page))
                                    .lineLimit(1)
                                Text("\(L10n.text("page", language)) \(page + 1)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(ImmediatePlainButtonStyle())
                }
            }
        }
    }

    private func title(for page: Int) -> String {
        tocItems
            .last { $0.pageIndex <= page }
            .map(\.title) ?? "\(L10n.text("page", language)) \(page + 1)"
    }
}

private struct PDFReaderView: NSViewRepresentable {
    let url: URL
    @Binding var selectedText: String
    @Binding var pageIndex: Int
    @Binding var pageCount: Int
    @Binding var zoomScale: Double
    @Binding var searchText: String
    @Binding var searchStatus: String?
    @Binding var command: ReaderCommand?
    @Binding var tocItems: [ReaderTOCItem]
    let readingTheme: ReaderTheme
    var onTranslate: () -> Void

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        view.backgroundColor = readingTheme.nsBackgroundColor
        context.coordinator.observeSelection(in: view)
        
        let doubleClickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handleDoubleClick(_:)))
        doubleClickGesture.numberOfClicksRequired = 2
        doubleClickGesture.delegate = context.coordinator
        view.addGestureRecognizer(doubleClickGesture)
        
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        view.backgroundColor = readingTheme.nsBackgroundColor

        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            let loadedPageCount = view.document?.pageCount ?? 0
            if let targetPage = view.document?.page(at: min(max(pageIndex, 0), max(loadedPageCount - 1, 0))) {
                view.go(to: targetPage)
            }
            if let page = view.currentPage, let index = view.document?.index(for: page) {
                context.coordinator.syncPageState(pageIndex: index, pageCount: loadedPageCount)
            } else {
                context.coordinator.syncPageState(pageIndex: nil, pageCount: loadedPageCount)
            }
            context.coordinator.syncTOCItems(Self.outlineItems(from: view.document))
        }

        context.coordinator.apply(
            command,
            to: view,
            pageIndex: $pageIndex,
            pageCount: $pageCount,
            zoomScale: $zoomScale,
            searchText: $searchText,
            searchStatus: $searchStatus
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedText: $selectedText,
            pageIndex: $pageIndex,
            pageCount: $pageCount,
            searchStatus: $searchStatus,
            tocItems: $tocItems,
            onTranslate: onTranslate
        )
    }

    private static func outlineItems(from document: PDFDocument?) -> [ReaderTOCItem] {
        guard let document, let root = document.outlineRoot else { return [] }

        func collect(_ outline: PDFOutline, level: Int) -> [ReaderTOCItem] {
            var items: [ReaderTOCItem] = []
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let destination = child.destination,
                   let page = destination.page,
                   let label,
                   !label.isEmpty {
                    let pageIndex = document.index(for: page)
                    items.append(ReaderTOCItem(title: label, pageIndex: pageIndex, level: level))
                }
                items.append(contentsOf: collect(child, level: level + 1))
            }
            return items
        }

        return collect(root, level: 0)
    }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        @Binding private var selectedText: String
        @Binding private var pageIndex: Int
        @Binding private var pageCount: Int
        @Binding private var searchStatus: String?
        @Binding private var tocItems: [ReaderTOCItem]
        let onTranslate: () -> Void
        private weak var observedView: PDFView?
        private var timer: Timer?
        private var lastCommandID: UUID?
        private var searchResults: [PDFSelection] = []
        private var searchQuery = ""
        private var searchIndex = -1

        init(
            selectedText: Binding<String>,
            pageIndex: Binding<Int>,
            pageCount: Binding<Int>,
            searchStatus: Binding<String?>,
            tocItems: Binding<[ReaderTOCItem]>,
            onTranslate: @escaping () -> Void
        ) {
            _selectedText = selectedText
            _pageIndex = pageIndex
            _pageCount = pageCount
            _searchStatus = searchStatus
            _tocItems = tocItems
            self.onTranslate = onTranslate
        }

        func syncPageState(pageIndex newPageIndex: Int?, pageCount newPageCount: Int) {
            DispatchQueue.main.async {
                if self.pageCount != newPageCount {
                    self.pageCount = newPageCount
                }
                if let newPageIndex, self.pageIndex != newPageIndex {
                    self.pageIndex = newPageIndex
                }
            }
        }

        func syncZoomScale(_ scale: Double, zoomScale: Binding<Double>) {
            DispatchQueue.main.async {
                if zoomScale.wrappedValue != scale {
                    zoomScale.wrappedValue = scale
                }
            }
        }

        func syncSelectedText(_ text: String) {
            DispatchQueue.main.async {
                if self.selectedText != text {
                    self.selectedText = text
                }
            }
        }

        func syncSearchStatus(_ text: String?) {
            DispatchQueue.main.async {
                if self.searchStatus != text {
                    self.searchStatus = text
                }
            }
        }

        func syncTOCItems(_ items: [ReaderTOCItem]) {
            DispatchQueue.main.async {
                if self.tocItems != items {
                    self.tocItems = items
                }
            }
        }

        func observeSelection(in view: PDFView) {
            observedView = view
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                guard let self, let observedView else { return }
                let latestText = observedView.currentSelection?.string ?? ""
                if latestText != self.selectedText {
                    self.syncSelectedText(latestText)
                }
                let latestPageCount = observedView.document?.pageCount ?? 0
                if let page = observedView.currentPage,
                   let latestPageIndex = observedView.document?.index(for: page),
                   latestPageIndex != self.pageIndex {
                    self.syncPageState(pageIndex: latestPageIndex, pageCount: latestPageCount)
                } else if latestPageCount != self.pageCount {
                    self.syncPageState(pageIndex: nil, pageCount: latestPageCount)
                }
            }
        }

        func apply(
            _ command: ReaderCommand?,
            to view: PDFView,
            pageIndex: Binding<Int>,
            pageCount: Binding<Int>,
            zoomScale: Binding<Double>,
            searchText: Binding<String>,
            searchStatus: Binding<String?>
        ) {
            guard let command, command.id != lastCommandID else { return }

            switch command.kind {
            case .previousPage:
                lastCommandID = command.id
                view.goToPreviousPage(nil)
            case .nextPage:
                lastCommandID = command.id
                view.goToNextPage(nil)
            case .goToPage(let index):
                if let page = view.document?.page(at: index) {
                    lastCommandID = command.id
                    view.go(to: page)
                }
            case .search:
                if selectSearchResult(in: view, searchText: searchText.wrappedValue, direction: 1, reset: true) {
                    lastCommandID = command.id
                } else {
                    syncSearchStatus(searchText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "0")
                }
            case .previousSearchResult:
                if selectSearchResult(in: view, searchText: searchText.wrappedValue, direction: -1, reset: false) {
                    lastCommandID = command.id
                } else {
                    syncSearchStatus(searchText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "0")
                }
            case .nextSearchResult:
                if selectSearchResult(in: view, searchText: searchText.wrappedValue, direction: 1, reset: false) {
                    lastCommandID = command.id
                } else {
                    syncSearchStatus(searchText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "0")
                }
            case .clearSearch:
                lastCommandID = command.id
                view.clearSelection()
                searchResults = []
                searchQuery = ""
                searchIndex = -1
                syncSelectedText("")
                syncSearchStatus(nil)
            case .setZoom(let scale):
                lastCommandID = command.id
                view.autoScales = false
                view.scaleFactor = CGFloat(scale)
            }

            let latestPageCount = view.document?.pageCount ?? 0
            if let page = view.currentPage, let index = view.document?.index(for: page) {
                syncPageState(pageIndex: index, pageCount: latestPageCount)
            } else {
                syncPageState(pageIndex: nil, pageCount: latestPageCount)
            }
            syncZoomScale(Double(view.scaleFactor), zoomScale: zoomScale)
        }

        deinit {
            timer?.invalidate()
        }

        private func selectSearchResult(in view: PDFView, searchText: String, direction: Int, reset: Bool) -> Bool {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, let document = view.document else { return false }

            if reset || query != searchQuery {
                searchResults = document.findString(query, withOptions: .caseInsensitive)
                searchQuery = query
                searchIndex = -1
            }

            guard !searchResults.isEmpty else { return false }
            searchIndex = (searchIndex + direction + searchResults.count) % searchResults.count
            let selection = searchResults[searchIndex]
            view.setCurrentSelection(selection, animate: true)
            view.go(to: selection)
            syncSelectedText(selection.string ?? query)
            syncSearchStatus("\(searchIndex + 1)/\(searchResults.count)")
            return true
        }
        
        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            guard gesture.state == .ended, let pdfView = observedView else { return }

            let viewPoint = gesture.location(in: pdfView)
            if let page = pdfView.page(for: viewPoint, nearest: true) {
                let pagePoint = pdfView.convert(viewPoint, to: page)
                if let wordSelection = page.selectionForWord(at: pagePoint),
                   let word = wordSelection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !word.isEmpty {
                    pdfView.setCurrentSelection(wordSelection, animate: true)
                    syncSelectedText(word)
                    onTranslate()
                    return
                }
            }

            // Fallback for PDFs where PDFKit already created a text selection.
            let latestText = pdfView.currentSelection?.string ?? ""
            if !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                syncSelectedText(latestText)
                onTranslate()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
            true
        }
    }
}

private struct CBZReaderView: View {
    let url: URL
    let language: SystemLanguage
    @Binding var pageIndex: Int
    @Binding var pageCount: Int
    @Binding var zoomScale: Double
    let readingTheme: ReaderTheme
    @Binding var command: ReaderCommand?
    @State private var pageURLs: [URL] = []
    @State private var errorMessage: String?
    @State private var lastCommandID: UUID?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView(L10n.text("cbz_open_failed", language), systemImage: "photo.on.rectangle.angled", description: Text(errorMessage))
            } else if pageURLs.isEmpty {
                ProgressView(L10n.text("loading_cbz", language))
                    .task { loadPages() }
            } else if let image = currentImage {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: image.size.width * CGFloat(zoomScale),
                            height: image.size.height * CGFloat(zoomScale)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                        .padding(22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(readingTheme.backgroundColor)
            } else {
                ContentUnavailableView(L10n.text("no_images_cbz", language), systemImage: "photo.on.rectangle.angled")
            }
        }
        .onChange(of: command) { _, newCommand in
            apply(newCommand)
        }
        .onChange(of: pageURLs.count) { _, count in
            syncPageState(pageIndex: min(pageIndex, max(count - 1, 0)), pageCount: count)
        }
    }

    private var currentImage: NSImage? {
        guard let pageURL = pageURLs[safe: pageIndex] else { return nil }
        return NSImage(contentsOf: pageURL)
    }

    private func apply(_ command: ReaderCommand?) {
        guard let command, command.id != lastCommandID else { return }
        lastCommandID = command.id

        switch command.kind {
        case .previousPage:
            syncPageState(pageIndex: max(0, pageIndex - 1), pageCount: pageURLs.count)
        case .nextPage:
            syncPageState(pageIndex: min(max(pageURLs.count - 1, 0), pageIndex + 1), pageCount: pageURLs.count)
        case .goToPage(let index):
            syncPageState(pageIndex: min(max(index, 0), max(pageURLs.count - 1, 0)), pageCount: pageURLs.count)
        case .setZoom(let scale):
            syncZoomScale(min(max(scale, 0.8), 1.8))
        case .search, .previousSearchResult, .nextSearchResult, .clearSearch:
            break
        }
    }

    private func syncPageState(pageIndex newPageIndex: Int, pageCount newPageCount: Int) {
        DispatchQueue.main.async {
            if pageCount != newPageCount {
                pageCount = newPageCount
            }
            if pageIndex != newPageIndex {
                pageIndex = newPageIndex
            }
        }
    }

    private func syncZoomScale(_ scale: Double) {
        DispatchQueue.main.async {
            if zoomScale != scale {
                zoomScale = scale
            }
        }
    }

    private func loadPages() {
        do {
            let extractedURL = try ArchiveExtractor.extract(url)
            pageURLs = try FileManager.default
                .subpathsOfDirectory(atPath: extractedURL.path)
                .map { extractedURL.appending(path: $0) }
                .filter { ["jpg", "jpeg", "png", "webp", "gif"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            syncPageState(pageIndex: min(pageIndex, max(pageURLs.count - 1, 0)), pageCount: pageURLs.count)

            if pageURLs.isEmpty {
                errorMessage = L10n.text("no_images_cbz", language)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EPUBReaderView: View {
    let url: URL
    let language: SystemLanguage
    @Binding var selectedText: String
    @Binding var pageIndex: Int
    @Binding var pageCount: Int
    @Binding var zoomScale: Double
    @Binding var searchText: String
    @Binding var searchStatus: String?
    @Binding var command: ReaderCommand?
    @Binding var tocItems: [ReaderTOCItem]
    let readingTheme: ReaderTheme
    let contentWidth: Double
    var onTranslate: () -> Void
    @State private var spinePages: [URL] = []
    @State private var readAccessURL: URL?
    @State private var errorMessage: String?
    @State private var lastCommandID: UUID?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView(L10n.text("epub_open_failed", language), systemImage: "doc.richtext", description: Text(errorMessage))
            } else if let readAccessURL, let currentPage = spinePages[safe: pageIndex] {
                WebReaderView(
                    pageURL: currentPage,
                    readAccessURL: readAccessURL,
                    selectedText: $selectedText,
                    zoomScale: zoomScale,
                    searchText: searchText,
                    searchStatus: $searchStatus,
                    command: command,
                    readingTheme: readingTheme,
                    contentWidth: contentWidth,
                    onTranslate: onTranslate
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView(L10n.text("loading_epub", language))
                    .task { loadEPUB() }
            }
        }
        .onChange(of: command) { _, newCommand in
            apply(newCommand)
        }
        .onChange(of: spinePages.count) { _, count in
            syncPageState(pageIndex: min(pageIndex, max(count - 1, 0)), pageCount: count)
        }
    }

    private func loadEPUB() {
        do {
            let extractedURL = try ArchiveExtractor.extract(url)
            let containerURL = extractedURL.appendingPathComponent("META-INF").appendingPathComponent("container.xml")
            let opfPath = try EPUBContainerParser.rootFilePath(from: containerURL)
            let opfURL = extractedURL.appending(path: opfPath)
            let opf = try EPUBPackageParser.package(from: opfURL)
            let opfDirectory = opfURL.deletingLastPathComponent()

            let fileManager = FileManager.default
            spinePages = opf.spineHrefs.compactMap { href in
                let expectedURL = opfDirectory.appending(path: href)
                if fileManager.fileExists(atPath: expectedURL.path) {
                    return expectedURL
                }

                let fallbackName = URL(fileURLWithPath: href).lastPathComponent
                return Self.findFile(named: fallbackName, under: opfDirectory)
                    ?? Self.findFile(named: fallbackName, under: extractedURL)
            }
            readAccessURL = extractedURL
            syncPageState(
                pageIndex: min(bookSafePageIndex(pageIndex, count: spinePages.count), max(spinePages.count - 1, 0)),
                pageCount: spinePages.count
            )
            let tocItems = makeNavigationTOCItems(
                package: opf,
                opfDirectory: opfDirectory,
                fallbackPages: spinePages
            )
            syncTOCItems(tocItems)

            if spinePages.isEmpty {
                errorMessage = L10n.text("no_spine_epub", language)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func findFile(named fileName: String, under directory: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            let candidateName = fileURL.lastPathComponent
            if candidateName == fileName || candidateName.lowercased() == fileName.lowercased() {
                return fileURL
            }
        }

        return nil
    }

    private func apply(_ command: ReaderCommand?) {
        guard let command, command.id != lastCommandID else { return }
        lastCommandID = command.id

        switch command.kind {
        case .previousPage:
            syncPageState(pageIndex: max(0, pageIndex - 1), pageCount: spinePages.count)
        case .nextPage:
            syncPageState(pageIndex: min(max(spinePages.count - 1, 0), pageIndex + 1), pageCount: spinePages.count)
        case .goToPage(let index):
            syncPageState(pageIndex: bookSafePageIndex(index, count: spinePages.count), pageCount: spinePages.count)
        case .search, .previousSearchResult, .nextSearchResult, .clearSearch, .setZoom:
            break
        }
    }

    private func syncPageState(pageIndex newPageIndex: Int, pageCount newPageCount: Int) {
        DispatchQueue.main.async {
            if pageCount != newPageCount {
                pageCount = newPageCount
            }
            if pageIndex != newPageIndex {
                pageIndex = newPageIndex
            }
        }
    }

    private func syncTOCItems(_ items: [ReaderTOCItem]) {
        DispatchQueue.main.async {
            if tocItems != items {
                tocItems = items
            }
        }
    }

    private func makeTOCItems(from pages: [URL]) -> [ReaderTOCItem] {
        pages.enumerated().map { index, pageURL in
            ReaderTOCItem(title: chapterTitle(for: pageURL), pageIndex: index, level: 0)
        }
    }

    private func makeNavigationTOCItems(package: EPUBPackage, opfDirectory: URL, fallbackPages: [URL]) -> [ReaderTOCItem] {
        var spineLookup: [String: Int] = [:]
        for (index, url) in fallbackPages.enumerated() {
            let relativePath = url.path.replacingOccurrences(of: opfDirectory.path + "/", with: "")
            spineLookup[normalizedEPUBPath(relativePath)] = index
            spineLookup[url.deletingPathExtension().lastPathComponent.lowercased()] = index
        }

        if let navHref = package.navHref {
            let navURL = opfDirectory.appending(path: navHref)
            let items = navTOCItems(from: navURL, spineLookup: spineLookup)
            if !items.isEmpty {
                return items
            }
        }

        if let ncxHref = package.ncxHref {
            let ncxURL = opfDirectory.appending(path: ncxHref)
            let items = ncxTOCItems(from: ncxURL, spineLookup: spineLookup)
            if !items.isEmpty {
                return items
            }
        }

        return makeTOCItems(from: fallbackPages)
    }

    private func navTOCItems(from navURL: URL, spineLookup: [String: Int]) -> [ReaderTOCItem] {
        guard let html = try? String(contentsOf: navURL, encoding: .utf8) else { return [] }
        let navContent = html.firstMatch(for: #"<nav[^>]*(?:epub:type|type)=["']toc["'][^>]*>(.*?)</nav>"#) ?? html
        return linkTOCItems(from: navContent, spineLookup: spineLookup)
    }

    private func ncxTOCItems(from ncxURL: URL, spineLookup: [String: Int]) -> [ReaderTOCItem] {
        guard let xml = try? String(contentsOf: ncxURL, encoding: .utf8) else { return [] }
        var items: [ReaderTOCItem] = []
        let navPointPattern = #"<navPoint\b[^>]*>(.*?)</navPoint>"#
        for rawPoint in xml.matches(for: navPointPattern) {
            let title = rawPoint.firstMatch(for: #"<text[^>]*>(.*?)</text>"#)?.decodedHTMLText ?? ""
            let src = rawPoint.firstMatch(for: #"<content[^>]*src=["']([^"']+)["'][^>]*/?>"#) ?? ""
            let pageIndex = pageIndex(for: src, spineLookup: spineLookup)
            if !title.isEmpty, let pageIndex {
                let level = max(rawPoint.components(separatedBy: "<navPoint").count - 2, 0)
                items.append(ReaderTOCItem(title: title, pageIndex: pageIndex, level: level))
            }
        }
        return items
    }

    private func linkTOCItems(from html: String, spineLookup: [String: Int]) -> [ReaderTOCItem] {
        var items: [ReaderTOCItem] = []
        let linkPattern = #"<a\b[^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#
        for rawLink in html.fullMatches(for: linkPattern) {
            guard let href = rawLink.firstMatch(for: #"href=["']([^"']+)["']"#),
                  let titleHTML = rawLink.firstMatch(for: #">(.*?)</a>"#) else {
                continue
            }
            let title = titleHTML.decodedHTMLText
            let level = max(rawLink.prefix { $0 != "<" }.filter { $0 == "\t" }.count, 0)
            if let pageIndex = pageIndex(for: href, spineLookup: spineLookup), !title.isEmpty {
                items.append(ReaderTOCItem(title: title, pageIndex: pageIndex, level: level))
            }
        }
        return items
    }

    private func pageIndex(for href: String, spineLookup: [String: Int]) -> Int? {
        let cleanHref = href.components(separatedBy: "#")[0]
        let normalized = normalizedEPUBPath(cleanHref)
        if let pageIndex = spineLookup[normalized] {
            return pageIndex
        }

        let fileName = URL(fileURLWithPath: cleanHref).deletingPathExtension().lastPathComponent.lowercased()
        return spineLookup[fileName]
    }

    private func normalizedEPUBPath(_ path: String) -> String {
        (path.removingPercentEncoding ?? path)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private func chapterTitle(for pageURL: URL) -> String {
        guard let html = try? String(contentsOf: pageURL, encoding: .utf8) else {
            return pageURL.deletingPathExtension().lastPathComponent
        }

        for pattern in [
            #"<title[^>]*>(.*?)</title>"#,
            #"<h1[^>]*>(.*?)</h1>"#,
            #"<h2[^>]*>(.*?)</h2>"#
        ] {
            if let match = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let raw = String(html[match])
                let cleaned = raw
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        return pageURL.deletingPathExtension().lastPathComponent
    }

    private func bookSafePageIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }
}


private struct WebReaderView: NSViewRepresentable {
    let pageURL: URL
    let readAccessURL: URL?
    @Binding var selectedText: String
    let zoomScale: Double
    let searchText: String
    @Binding var searchStatus: String?
    let command: ReaderCommand?
    let readingTheme: ReaderTheme
    let contentWidth: Double
    var onTranslate: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "selectionObserver")
        userContentController.add(context.coordinator, name: "doubleClickObserver")
        userContentController.addUserScript(
            WKUserScript(
                source: """
                document.addEventListener('selectionchange', function() {
                    window.webkit.messageHandlers.selectionObserver.postMessage(window.getSelection().toString());
                });
                document.addEventListener('dblclick', function() {
                    let text = window.getSelection().toString();
                    if (text.trim().length > 0) {
                        window.webkit.messageHandlers.doubleClickObserver.postMessage(text);
                    }
                });
                try {
                    var style = document.createElementNS ? document.createElementNS('http://www.w3.org/1999/xhtml', 'style') : document.createElement('style');
                    style.innerHTML = ':root { color-scheme: dark; --codex-reader-zoom: 1; --codex-reader-bg: #141617; --codex-reader-page: #181b1c; --codex-reader-fg: #e8eceb; --codex-reader-width: 800px; } html { background: var(--codex-reader-bg) !important; } body { color: var(--codex-reader-fg) !important; background: var(--codex-reader-page) !important; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif !important; font-size: calc(1.15em * var(--codex-reader-zoom)) !important; line-height: 1.6 !important; padding: 2% 6% !important; margin: 0 auto !important; max-width: var(--codex-reader-width) !important; min-height: 100vh !important; word-wrap: break-word !important; } img { max-width: 100% !important; height: auto !important; } a { color: #4da3ff !important; }';
                    var target = document.head || document.documentElement || document.body;
                    if (target) { target.appendChild(style); }
                } catch(e) { console.error("CSS Injection failed:", e); }
                """,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedURL != pageURL {
            context.coordinator.lastLoadedURL = pageURL
            context.coordinator.isLoading = true
            let fileManager = FileManager.default

            // Prefer to let WebKit load the file with a sandbox read-access folder when available.
            if let access = readAccessURL, fileManager.isReadableFile(atPath: pageURL.path) {
                webView.loadFileURL(pageURL, allowingReadAccessTo: access)
            } else {
                // Fallback: read file contents and load as HTML string (sanitized) to avoid sandbox extension issues.
                do {
                    var htmlContent = try String(contentsOf: pageURL, encoding: .utf8)

                    // Remove external resource references to prevent network calls
                    htmlContent = htmlContent.replacingOccurrences(
                        of: #"<link[^>]*href=["'](?!data:)[^"']*["'][^>]*>"#,
                        with: "",
                        options: .regularExpression
                    )
                    htmlContent = htmlContent.replacingOccurrences(
                        of: #"<img[^>]*src=["'](?!data:)[^"']*["'][^>]*>"#,
                        with: "",
                        options: .regularExpression
                    )

                    let baseURL = pageURL.deletingLastPathComponent()
                    webView.loadHTMLString(htmlContent, baseURL: baseURL)
                } catch {
                    let errorHTML = """
                    <html><body style="font-family: -apple-system, sans-serif; padding: 20px;">
                        <h1>Error Loading File</h1>
                        <p>\(error.localizedDescription)</p>
                    </body></html>
                    """
                    webView.loadHTMLString(errorHTML, baseURL: nil)
                }
            }
        }

        context.coordinator.applyReaderStyle(zoomScale: zoomScale, theme: readingTheme, contentWidth: contentWidth, in: webView)
        context.coordinator.apply(command, searchText: searchText, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "selectionObserver")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "doubleClickObserver")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedText: $selectedText, searchStatus: $searchStatus, onTranslate: onTranslate)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        @Binding private var selectedText: String
        @Binding private var searchStatus: String?
        let onTranslate: () -> Void
        var lastLoadedURL: URL?
        var isLoading = false
        private var lastCommandID: UUID?
        private var pendingCommand: ReaderCommand?
        private var pendingSearchText = ""
        private var lastZoomScale = 1.0
        private var lastTheme: ReaderTheme = .dark
        private var lastContentWidth = 800.0
        private var webSearchQuery = ""
        private var webSearchIndex = 0

        init(selectedText: Binding<String>, searchStatus: Binding<String?>, onTranslate: @escaping () -> Void) {
            _selectedText = selectedText
            _searchStatus = searchStatus
            self.onTranslate = onTranslate
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "selectionObserver", let text = message.body as? String {
                syncSelectedText(text)
            } else if message.name == "doubleClickObserver", let text = message.body as? String {
                syncSelectedText(text)
                onTranslate() // ทำงานทันทีเมื่อเกิดเหตุการณ์ดับเบิ้ลคลิก
            }
        }

        private func syncSelectedText(_ text: String) {
            DispatchQueue.main.async {
                if self.selectedText != text {
                    self.selectedText = text
                }
            }
        }

        private func syncSearchStatus(_ text: String?) {
            DispatchQueue.main.async {
                if self.searchStatus != text {
                    self.searchStatus = text
                }
            }
        }

        func applyReaderStyle(zoomScale: Double, theme: ReaderTheme, contentWidth: Double, in webView: WKWebView) {
            let scale = min(max(zoomScale, 0.8), 1.8)
            let width = min(max(contentWidth, 560), 1100)
            lastZoomScale = scale
            lastTheme = theme
            lastContentWidth = width

            let script = """
            document.documentElement.style.setProperty('color-scheme', '\(theme.cssColorScheme)');
            document.documentElement.style.setProperty('--codex-reader-zoom', '\(scale)');
            document.documentElement.style.setProperty('--codex-reader-bg', '\(theme.cssBackground)');
            document.documentElement.style.setProperty('--codex-reader-page', '\(theme.cssPage)');
            document.documentElement.style.setProperty('--codex-reader-fg', '\(theme.cssText)');
            document.documentElement.style.setProperty('--codex-reader-width', '\(Int(width))px');
            """
            webView.evaluateJavaScript(script)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            applyReaderStyle(zoomScale: lastZoomScale, theme: lastTheme, contentWidth: lastContentWidth, in: webView)
            if let commandToApply = pendingCommand {
                let searchTextToApply = pendingSearchText
                self.pendingCommand = nil
                self.pendingSearchText = ""
                apply(commandToApply, searchText: searchTextToApply, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func apply(_ command: ReaderCommand?, searchText: String, in webView: WKWebView) {
            guard let command, command.id != lastCommandID else { return }

            if isLoading {
                pendingCommand = command
                pendingSearchText = searchText
                return
            }

            switch command.kind {
            case .search:
                if find(searchText, backwards: false, in: webView) {
                    lastCommandID = command.id
                }
            case .previousSearchResult:
                if find(searchText, backwards: true, in: webView) {
                    lastCommandID = command.id
                }
            case .nextSearchResult:
                if find(searchText, backwards: false, in: webView) {
                    lastCommandID = command.id
                }
            case .clearSearch:
                lastCommandID = command.id
                webView.evaluateJavaScript("window.getSelection().removeAllRanges();")
                webSearchQuery = ""
                webSearchIndex = 0
                syncSelectedText("")
                syncSearchStatus(nil)
            case .setZoom(let scale):
                lastCommandID = command.id
                applyReaderStyle(zoomScale: scale, theme: lastTheme, contentWidth: lastContentWidth, in: webView)
            case .previousPage, .nextPage, .goToPage:
                lastCommandID = command.id
                break
            }
        }

        private func find(_ searchText: String, backwards: Bool, in webView: WKWebView) -> Bool {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return false }

            let literal = javaScriptStringLiteral(query)
            let script = #"""
            (() => {
                const query = \#(literal);
                const text = document.body ? document.body.innerText : "";
                const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
                const count = escaped.length ? (text.match(new RegExp(escaped, "gi")) || []).length : 0;
                const found = window.find(query, false, \#(backwards ? "true" : "false"), true, false, false, false);
                return { found, count };
            })();
            """#

            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                let dictionary = result as? [String: Any]
                let count = dictionary?["count"] as? Int ?? 0
                let found = dictionary?["found"] as? Bool ?? false

                guard found, count > 0 else {
                    self.webSearchQuery = query
                    self.webSearchIndex = 0
                    self.syncSearchStatus("0")
                    return
                }

                if self.webSearchQuery != query || self.webSearchIndex == 0 {
                    self.webSearchQuery = query
                    self.webSearchIndex = backwards ? count : 1
                } else if backwards {
                    self.webSearchIndex = self.webSearchIndex <= 1 ? count : self.webSearchIndex - 1
                } else {
                    self.webSearchIndex = self.webSearchIndex >= count ? 1 : self.webSearchIndex + 1
                }

                self.syncSearchStatus("\(self.webSearchIndex)/\(count)")
            }
            return true
        }

        private func javaScriptStringLiteral(_ text: String) -> String {
            if let data = try? JSONSerialization.data(withJSONObject: [text]),
               let json = String(data: data, encoding: .utf8),
               json.hasPrefix("["),
               json.hasSuffix("]") {
                return String(json.dropFirst().dropLast())
            }

            return "\"\""
        }
    }
}

private struct TranslationResultView: View {
    let language: SystemLanguage
    let sourceText: String
    let translatedText: String
    let errorMessage: String?
    let statusMessage: String?
    let isTranslating: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(L10n.text("translation_title", language), systemImage: "character.bubble")
                    .font(.title2.bold())

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(ImmediatePlainButtonStyle())
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("selected_text", language))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(sourceText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("translated_text", language))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                if isTranslating {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(L10n.text("translating", language))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let statusMessage {
                            Text(statusMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(translatedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 520)
        .frame(minHeight: 360)
    }
}

// MARK: - Data Models
private enum SystemLanguage: String, CaseIterable, Identifiable {
    case en = "EN"
    case th = "TH"
    case cn = "CN"
    case zhTW = "ZH_TW"
    case it = "IT"
    case jp = "JP"
    case ar = "AR"
    case nl = "NL"
    case fr = "FR"
    case de = "DE"
    case hi = "HI"
    case id = "ID"
    case ko = "KO"
    case pl = "PL"
    case pt = "PT"
    case ru = "RU"
    case es = "ES"
    case tr = "TR"
    case uk = "UK"
    case vi = "VI"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .en:
            return "English"
        case .th:
            return "Thai"
        case .cn:
            return "Chinese (Simplified)"
        case .zhTW:
            return "Chinese (Traditional)"
        case .it:
            return "Italian"
        case .jp:
            return "Japanese"
        case .ar:
            return "Arabic"
        case .nl:
            return "Dutch"
        case .fr:
            return "French"
        case .de:
            return "German"
        case .hi:
            return "Hindi"
        case .id:
            return "Indonesian"
        case .ko:
            return "Korean"
        case .pl:
            return "Polish"
        case .pt:
            return "Portuguese"
        case .ru:
            return "Russian"
        case .es:
            return "Spanish"
        case .tr:
            return "Turkish"
        case .uk:
            return "Ukrainian"
        case .vi:
            return "Vietnamese"
        }
    }

    var translationLanguage: Locale.Language {
        switch self {
        case .en:
            return Locale.Language(languageCode: "en")
        case .th:
            return Locale.Language(languageCode: "th")
        case .cn:
            return Locale.Language(languageCode: "zh", script: "Hans")
        case .zhTW:
            return Locale.Language(languageCode: "zh", script: "Hant")
        case .it:
            return Locale.Language(languageCode: "it")
        case .jp:
            return Locale.Language(languageCode: "ja")
        case .ar:
            return Locale.Language(languageCode: "ar")
        case .nl:
            return Locale.Language(languageCode: "nl")
        case .fr:
            return Locale.Language(languageCode: "fr")
        case .de:
            return Locale.Language(languageCode: "de")
        case .hi:
            return Locale.Language(languageCode: "hi")
        case .id:
            return Locale.Language(languageCode: "id")
        case .ko:
            return Locale.Language(languageCode: "ko")
        case .pl:
            return Locale.Language(languageCode: "pl")
        case .pt:
            return Locale.Language(languageCode: "pt")
        case .ru:
            return Locale.Language(languageCode: "ru")
        case .es:
            return Locale.Language(languageCode: "es")
        case .tr:
            return Locale.Language(languageCode: "tr")
        case .uk:
            return Locale.Language(languageCode: "uk")
        case .vi:
            return Locale.Language(languageCode: "vi")
        }
    }
}

private enum L10n {
    static func text(_ key: String, _ language: SystemLanguage) -> String {
        translations[key]?[language] ?? extraTranslations[language]?[key] ?? translations[key]?[.th] ?? key
    }

    static func importHelp(shelfName: String, _ language: SystemLanguage) -> String {
        if let template = extraTranslations[language]?["import_help"] {
            return template.replacingOccurrences(of: "%@", with: shelfName)
        }

        switch language {
        case .en:
            return "Import EPUB, PDF, or CBZ into \(shelfName)"
        case .th:
            return "นำเข้า EPUB, PDF หรือ CBZ ในชั้น \(shelfName)"
        case .cn:
            return "将 EPUB、PDF 或 CBZ 导入 \(shelfName)"
        case .it:
            return "Importa EPUB, PDF o CBZ nello scaffale \(shelfName)"
        case .jp:
            return "\(shelfName) に EPUB、PDF、CBZ を追加"
        default:
            return "นำเข้า EPUB, PDF หรือ CBZ ในชั้น \(shelfName)"
        }
    }

    private static let translations: [String: [SystemLanguage: String]] = [
        "app_subtitle": [
            .en: "An eBook bookshelf organized like a personal library.",
            .th: "ตู้หนังสือ eBook จัดหมวดหมู่แบบห้องสมุดส่วนตัว",
            .cn: "像个人图书馆一样整理的电子书架。",
            .zhTW: "像個人圖書館一樣整理的電子書架。",
            .it: "Una libreria eBook organizzata come una biblioteca personale.",
            .jp: "個人図書館のように整理した電子書籍本棚。",
            .ar: "رف كتب إلكترونية منظم مثل مكتبة شخصية.",
            .nl: "Een e-bookkast ingericht als een persoonlijke bibliotheek.",
            .fr: "Une bibliothèque eBook organisée comme une bibliothèque personnelle.",
            .de: "Ein eBook-Regal, organisiert wie eine persönliche Bibliothek.",
            .hi: "निजी पुस्तकालय की तरह व्यवस्थित eBook शेल्फ।",
            .id: "Rak eBook yang diatur seperti perpustakaan pribadi.",
            .ko: "개인 도서관처럼 정리한 eBook 책장입니다.",
            .pl: "Półka eBooków uporządkowana jak osobista biblioteka.",
            .pt: "Uma estante de eBooks organizada como uma biblioteca pessoal.",
            .ru: "Полка eBook, организованная как личная библиотека.",
            .es: "Una estantería de eBooks organizada como una biblioteca personal.",
            .tr: "Kişisel kütüphane gibi düzenlenmiş bir eBook rafı.",
            .uk: "Полиця eBook, упорядкована як особиста бібліотека.",
            .vi: "Tủ eBook được sắp xếp như thư viện cá nhân."
        ],
        "shelves_unit": [.en: "shelves", .th: "ชั้น", .cn: "层", .it: "ripiani", .jp: "段"],
        "books_unit": [.en: "books", .th: "เล่ม", .cn: "本", .it: "libri", .jp: "冊"],
        "add": [.en: "Add", .th: "เพิ่ม", .cn: "添加", .it: "Aggiungi", .jp: "追加"],
        "save": [.en: "Save", .th: "บันทึก", .cn: "保存", .it: "Salva", .jp: "保存"],
        "delete_from_shelf": [.en: "Remove from shelf", .th: "ลบออกจากชั้น", .cn: "从书架移除", .it: "Rimuovi dallo scaffale", .jp: "棚から削除"],
        "rename_book": [.en: "Rename book", .th: "เปลี่ยนชื่อหนังสือ", .cn: "重命名书籍", .it: "Rinomina libro", .jp: "本の名前を変更"],
        "book_title": [.en: "Book title", .th: "ชื่อหนังสือ", .cn: "书名", .it: "Titolo del libro", .jp: "本のタイトル"],
        "reset_reading_progress": [.en: "Reset reading progress", .th: "รีเซ็ตความคืบหน้าการอ่าน", .cn: "重置阅读进度", .it: "Reimposta avanzamento", .jp: "読書進捗をリセット"],
        "show_in_finder": [.en: "Show in Finder", .th: "แสดงใน Finder", .cn: "在 Finder 中显示", .it: "Mostra nel Finder", .jp: "Finder に表示"],
        "copy_file_path": [.en: "Copy file path", .th: "คัดลอก path ไฟล์", .cn: "复制文件路径", .it: "Copia percorso file", .jp: "ファイルパスをコピー"],
        "delete_confirm": [.en: "Remove this book from the shelf?", .th: "ลบหนังสือเล่มนี้ออกจากชั้น?", .cn: "要从书架移除这本书吗？", .it: "Rimuovere questo libro dallo scaffale?", .jp: "この本を棚から削除しますか？"],
        "cancel": [.en: "Cancel", .th: "ยกเลิก", .cn: "取消", .it: "Annulla", .jp: "キャンセル"],
        "no_file_title": [.en: "No book file", .th: "ยังไม่มีไฟล์หนังสือ", .cn: "没有书籍文件", .it: "Nessun file libro", .jp: "本のファイルがありません"],
        "no_file_description": [.en: "Import an EPUB, PDF, or CBZ using the add book cover on a shelf.", .th: "นำเข้าไฟล์ EPUB, PDF หรือ CBZ ด้วยปกเพิ่มหนังสือบนชั้นหนังสือ", .cn: "使用书架上的添加封面导入 EPUB、PDF 或 CBZ。", .it: "Importa EPUB, PDF o CBZ usando la copertina di aggiunta sullo scaffale.", .jp: "棚の追加カバーから EPUB、PDF、CBZ を読み込んでください。"],
        "library_search": [.en: "Search books", .th: "ค้นหาหนังสือ", .cn: "搜索书籍", .it: "Cerca libri", .jp: "本を検索"],
        "search_results": [.en: "%d/%t found", .th: "พบ %d/%t", .cn: "找到 %d/%t", .it: "Trovati %d/%t", .jp: "%d/%t 件"],
        "sort_by": [.en: "Sort by", .th: "เรียงตาม", .cn: "排序", .it: "Ordina per", .jp: "並び替え"],
        "sort_title": [.en: "Title", .th: "ชื่อหนังสือ", .cn: "标题", .it: "Titolo", .jp: "タイトル"],
        "sort_format": [.en: "Format", .th: "ฟอร์แมต", .cn: "格式", .it: "Formato", .jp: "形式"],
        "sort_progress": [.en: "Progress", .th: "ความคืบหน้า", .cn: "进度", .it: "Avanzamento", .jp: "進捗"],
        "sort_ascending": [.en: "Ascending", .th: "น้อยไปมาก", .cn: "升序", .it: "Crescente", .jp: "昇順"],
        "sort_descending": [.en: "Descending", .th: "มากไปน้อย", .cn: "降序", .it: "Decrescente", .jp: "降順"],
        "cbz_open_failed": [.en: "Could not open CBZ", .th: "เปิด CBZ ไม่ได้", .cn: "无法打开 CBZ", .it: "Impossibile aprire CBZ", .jp: "CBZ を開けません"],
        "loading_cbz": [.en: "Opening CBZ...", .th: "กำลังเปิด CBZ...", .cn: "正在打开 CBZ...", .it: "Apertura CBZ...", .jp: "CBZ を開いています..."],
        "no_images_cbz": [.en: "No images found in CBZ", .th: "ไม่พบไฟล์รูปภาพใน CBZ", .cn: "CBZ 中未找到图片", .it: "Nessuna immagine trovata nel CBZ", .jp: "CBZ 内に画像が見つかりません"],
        "epub_open_failed": [.en: "Could not open EPUB", .th: "เปิด EPUB ไม่ได้", .cn: "无法打开 EPUB", .it: "Impossibile aprire EPUB", .jp: "EPUB を開けません"],
        "loading_epub": [.en: "Opening EPUB...", .th: "กำลังเปิด EPUB...", .cn: "正在打开 EPUB...", .it: "Apertura EPUB...", .jp: "EPUB を開いています..."],
        "no_spine_epub": [.en: "No readable spine found in EPUB", .th: "ไม่พบ spine/หน้าอ่านใน EPUB", .cn: "EPUB 中未找到可阅读的 spine", .it: "Nessuno spine leggibile trovato nell'EPUB", .jp: "EPUB 内に読み取り可能な spine が見つかりません"],
        "previous": [.en: "Previous", .th: "ก่อนหน้า", .cn: "上一页", .it: "Precedente", .jp: "前へ"],
        "next": [.en: "Next", .th: "ถัดไป", .cn: "下一页", .it: "Avanti", .jp: "次へ"],
        "translate_selection": [.en: "Translate Selection", .th: "แปลข้อความที่เลือก", .cn: "翻译所选文本", .it: "Traduci selezione", .jp: "選択範囲を翻訳"],
        "find_previous": [.en: "Find previous", .th: "ค้นหาก่อนหน้า", .cn: "查找上一个", .it: "Trova precedente", .jp: "前を検索"],
        "find_next": [.en: "Find next", .th: "ค้นหาถัดไป", .cn: "查找下一个", .it: "Trova successivo", .jp: "次を検索"],
        "clear_search": [.en: "Clear search", .th: "ล้างการค้นหา", .cn: "清除搜索", .it: "Cancella ricerca", .jp: "検索をクリア"],
        "search": [.en: "Search", .th: "ค้นหา", .cn: "搜索", .it: "Cerca", .jp: "検索"],
        "text_tools_unavailable": [.en: "Text tools are not available for this format", .th: "เครื่องมือข้อความใช้กับไฟล์ชนิดนี้ไม่ได้", .cn: "此格式不可使用文本工具", .it: "Gli strumenti di testo non sono disponibili per questo formato", .jp: "この形式ではテキストツールを使用できません"],
        "zoom_out": [.en: "Zoom out", .th: "ซูมออก", .cn: "缩小", .it: "Riduci zoom", .jp: "縮小"],
        "zoom_in": [.en: "Zoom in", .th: "ซูมเข้า", .cn: "放大", .it: "Aumenta zoom", .jp: "拡大"],
        "reset_zoom": [.en: "Reset zoom", .th: "รีเซ็ตซูม", .cn: "重置缩放", .it: "Reimposta zoom", .jp: "ズームをリセット"],
        "bookmark": [.en: "Bookmark", .th: "บุ๊กมาร์ก", .cn: "书签", .it: "Segnalibro", .jp: "ブックマーク"],
        "bookmarks": [.en: "Bookmarks", .th: "บุ๊กมาร์ก", .cn: "书签列表", .it: "Segnalibri", .jp: "ブックマーク一覧"],
        "no_bookmarks": [.en: "No bookmarks", .th: "ยังไม่มีบุ๊กมาร์ก", .cn: "没有书签", .it: "Nessun segnalibro", .jp: "ブックマークがありません"],
        "no_pages": [.en: "No pages", .th: "ไม่มีหน้า", .cn: "没有页面", .it: "Nessuna pagina", .jp: "ページがありません"],
        "page": [.en: "Page", .th: "หน้า", .cn: "页", .it: "Pagina", .jp: "ページ"],
        "copy_selection": [.en: "Copy selection", .th: "คัดลอกข้อความที่เลือก", .cn: "复制所选文本", .it: "Copia selezione", .jp: "選択範囲をコピー"],
        "translate_to": [.en: "Translate to", .th: "แปลเป็น", .cn: "翻译为", .it: "Traduci in", .jp: "翻訳先"],
        "translation_title": [.en: "Translation", .th: "คำแปล", .cn: "翻译", .it: "Traduzione", .jp: "翻訳"],
        "selected_text": [.en: "Selected text", .th: "ข้อความที่เลือก", .cn: "所选文本", .it: "Testo selezionato", .jp: "選択したテキスト"],
        "translated_text": [.en: "Translation", .th: "คำแปล", .cn: "译文", .it: "Traduzione", .jp: "翻訳"],
        "translating": [.en: "Translating...", .th: "กำลังแปล...", .cn: "正在翻译...", .it: "Traduzione in corso...", .jp: "翻訳中..."],
        "reading_settings": [.en: "Reading settings", .th: "ตั้งค่าการอ่าน", .cn: "阅读设置", .it: "Impostazioni di lettura", .jp: "読書設定"],
        "theme": [.en: "Theme", .th: "ธีม", .cn: "主题", .it: "Tema", .jp: "テーマ"],
        "theme_system": [.en: "System", .th: "ระบบ", .cn: "系统", .it: "Sistema", .jp: "システム"],
        "theme_dark": [.en: "Dark", .th: "มืด", .cn: "深色", .it: "Scuro", .jp: "ダーク"],
        "theme_light": [.en: "Light", .th: "สว่าง", .cn: "浅色", .it: "Chiaro", .jp: "ライト"],
        "theme_sepia": [.en: "Sepia", .th: "ซีเปีย", .cn: "棕褐色", .it: "Seppia", .jp: "セピア"],
        "page_width": [.en: "Page width", .th: "ความกว้างหน้าอ่าน", .cn: "页面宽度", .it: "Larghezza pagina", .jp: "ページ幅"],
        "continue_reading": [.en: "Continue reading", .th: "อ่านต่อ", .cn: "继续阅读", .it: "Continua a leggere", .jp: "続きを読む"],

        "หมวดหมู่ภาษา": [.en: "Languages", .th: "หมวดหมู่ภาษา", .cn: "语言", .it: "Lingue", .jp: "言語"],
        "หมวดหมู่วิทยาศาสตร์": [.en: "Science", .th: "หมวดหมู่วิทยาศาสตร์", .cn: "科学", .it: "Scienze", .jp: "科学"],
        "หมวดหมู่บริหารธุรกิจ": [.en: "Business Administration", .th: "หมวดหมู่บริหารธุรกิจ", .cn: "工商管理", .it: "Amministrazione aziendale", .jp: "経営学"],
        "หมวดหมู่วิศวกรรม": [.en: "Engineering", .th: "หมวดหมู่วิศวกรรม", .cn: "工程", .it: "Ingegneria", .jp: "工学"],
        "หมวดหมู่คอมพิวเตอร์และไอที": [
            .en: "Computer & IT", .th: "หมวดหมู่คอมพิวเตอร์และไอที", .cn: "计算机与信息技术", .zhTW: "電腦與資訊科技", .it: "Computer e IT", .jp: "コンピューターとIT",
            .ar: "الحاسوب وتقنية المعلومات", .nl: "Computer en IT", .fr: "Informatique et IT", .de: "Computer und IT", .hi: "कंप्यूटर और आईटी", .id: "Komputer & TI", .ko: "컴퓨터 및 IT", .pl: "Komputery i IT", .pt: "Computador e TI", .ru: "Компьютеры и ИТ", .es: "Computación e TI", .tr: "Bilgisayar ve BT", .uk: "Комп'ютери та ІТ", .vi: "Máy tính và CNTT"
        ],
        "หมวดหมู่วรรณกรรม": [
            .en: "Literature", .th: "หมวดหมู่วรรณกรรม", .cn: "文学", .zhTW: "文學", .it: "Letteratura", .jp: "文学",
            .ar: "الأدب", .nl: "Literatuur", .fr: "Littérature", .de: "Literatur", .hi: "साहित्य", .id: "Sastra", .ko: "문학", .pl: "Literatura", .pt: "Literatura", .ru: "Литература", .es: "Literatura", .tr: "Edebiyat", .uk: "Література", .vi: "Văn học"
        ],
        "หมวดหมู่สังคมศาสตร์": [
            .en: "Social Sciences", .th: "หมวดหมู่สังคมศาสตร์", .cn: "社会科学", .zhTW: "社會科學", .it: "Scienze sociali", .jp: "社会科学",
            .ar: "العلوم الاجتماعية", .nl: "Sociale wetenschappen", .fr: "Sciences sociales", .de: "Sozialwissenschaften", .hi: "सामाजिक विज्ञान", .id: "Ilmu Sosial", .ko: "사회과학", .pl: "Nauki społeczne", .pt: "Ciências sociais", .ru: "Социальные науки", .es: "Ciencias sociales", .tr: "Sosyal Bilimler", .uk: "Соціальні науки", .vi: "Khoa học xã hội"
        ],
        "หมวดหมู่ศิลปะและสื่อ": [
            .en: "Arts & Media", .th: "หมวดหมู่ศิลปะและสื่อ", .cn: "艺术与媒体", .zhTW: "藝術與媒體", .it: "Arti e media", .jp: "芸術とメディア",
            .ar: "الفنون والإعلام", .nl: "Kunst en media", .fr: "Arts et médias", .de: "Kunst und Medien", .hi: "कला और मीडिया", .id: "Seni & Media", .ko: "예술 및 미디어", .pl: "Sztuka i media", .pt: "Artes e mídia", .ru: "Искусство и медиа", .es: "Artes y medios", .tr: "Sanat ve Medya", .uk: "Мистецтво та медіа", .vi: "Nghệ thuật và truyền thông"
        ],
        "หมวดหมู่สุขภาพและการแพทย์": [
            .en: "Health & Medicine", .th: "หมวดหมู่สุขภาพและการแพทย์", .cn: "健康与医学", .zhTW: "健康與醫學", .it: "Salute e medicina", .jp: "健康と医学",
            .ar: "الصحة والطب", .nl: "Gezondheid en geneeskunde", .fr: "Santé et médecine", .de: "Gesundheit und Medizin", .hi: "स्वास्थ्य और चिकित्सा", .id: "Kesehatan & Kedokteran", .ko: "건강 및 의학", .pl: "Zdrowie i medycyna", .pt: "Saúde e medicina", .ru: "Здоровье и медицина", .es: "Salud y medicina", .tr: "Sağlık ve Tıp", .uk: "Здоров'я та медицина", .vi: "Sức khỏe và y học"
        ],
        "หมวดหมู่ประวัติศาสตร์และภูมิศาสตร์": [
            .en: "History & Geography", .th: "หมวดหมู่ประวัติศาสตร์และภูมิศาสตร์", .cn: "历史与地理", .zhTW: "歷史與地理", .it: "Storia e geografia", .jp: "歴史と地理",
            .ar: "التاريخ والجغرافيا", .nl: "Geschiedenis en geografie", .fr: "Histoire et géographie", .de: "Geschichte und Geografie", .hi: "इतिहास और भूगोल", .id: "Sejarah & Geografi", .ko: "역사 및 지리", .pl: "Historia i geografia", .pt: "História e geografia", .ru: "История и география", .es: "Historia y geografía", .tr: "Tarih ve Coğrafya", .uk: "Історія та географія", .vi: "Lịch sử và địa lý"
        ],
        "วิศวกรรม": [.en: "Engineering", .th: "วิศวกรรม", .cn: "工程", .it: "Ingegneria", .jp: "工学"],
        "บริหารธุรกิจ": [.en: "Business", .th: "บริหารธุรกิจ", .cn: "商业", .it: "Business", .jp: "ビジネス"],

        "ไทย": [.en: "Thai", .th: "ไทย", .cn: "泰语", .it: "Thai", .jp: "タイ語"],
        "อังกฤษ": [.en: "English", .th: "อังกฤษ", .cn: "英语", .it: "Inglese", .jp: "英語"],
        "จีน": [.en: "Chinese", .th: "จีน", .cn: "中文", .it: "Cinese", .jp: "中国語"],
        "ญี่ปุ่น": [.en: "Japanese", .th: "ญี่ปุ่น", .cn: "日语", .it: "Giapponese", .jp: "日本語"],
        "อิตาลี": [.en: "Italian", .th: "อิตาลี", .cn: "意大利语", .it: "Italiano", .jp: "イタリア語"],
        "เยอรมัน": [.en: "German", .th: "เยอรมัน", .cn: "德语", .it: "Tedesco", .jp: "ドイツ語"],
        "ฝรั่งเศส": [.en: "French", .th: "ฝรั่งเศส", .cn: "法语", .it: "Francese", .jp: "フランス語"],
        "ฟิสิกส์": [.en: "Physics", .th: "ฟิสิกส์", .cn: "物理", .it: "Fisica", .jp: "物理"],
        "เคมี": [.en: "Chemistry", .th: "เคมี", .cn: "化学", .it: "Chimica", .jp: "化学"],
        "ชีวะ": [.en: "Biology", .th: "ชีวะ", .cn: "生物", .it: "Biologia", .jp: "生物"],
        "บัญชี": [.en: "Accounting", .th: "บัญชี", .cn: "会计", .it: "Contabilità", .jp: "会計"],
        "การเงิน": [.en: "Finance", .th: "การเงิน", .cn: "金融", .it: "Finanza", .jp: "金融"],
        "การตลาด": [.en: "Marketing", .th: "การตลาด", .cn: "市场营销", .it: "Marketing", .jp: "マーケティング"],
        "เศรษฐศาสตร์": [.en: "Economics", .th: "เศรษฐศาสตร์", .cn: "经济学", .it: "Economia", .jp: "経済学"],
        "เครื่องกล": [.en: "Mechanical", .th: "เครื่องกล", .cn: "机械", .it: "Meccanica", .jp: "機械"],
        "ไฟฟ้าอิเล็กทรอนิกส์": [.en: "Electrical & Electronics", .th: "ไฟฟ้าอิเล็กทรอนิกส์", .cn: "电气与电子", .it: "Elettrica ed elettronica", .jp: "電気電子"],
        "วิศวกรรมเคมี": [.en: "Chemical Engineering", .th: "วิศวกรรมเคมี", .cn: "化学工程", .it: "Ingegneria chimica", .jp: "化学工学"],
        "วิศวกรรมพันธุกรรม": [.en: "Genetic Engineering", .th: "วิศวกรรมพันธุกรรม", .cn: "基因工程", .it: "Ingegneria genetica", .jp: "遺伝子工学"],
        "ไฟฟ้า": [.en: "Electrical", .th: "ไฟฟ้า", .cn: "电气", .it: "Elettrica", .jp: "電気"],
        "คอมพิวเตอร์": [.en: "Computer", .th: "คอมพิวเตอร์", .cn: "计算机", .it: "Computer", .jp: "コンピューター"],
        "พื้นฐานคอมพิวเตอร์": [.en: "Computer Basics", .th: "พื้นฐานคอมพิวเตอร์", .cn: "计算机基础", .zhTW: "電腦基礎", .it: "Basi di computer", .jp: "コンピューター基礎", .fr: "Bases informatiques", .de: "Computergrundlagen", .es: "Fundamentos de computación", .ko: "컴퓨터 기초", .vi: "Cơ bản máy tính"],
        "โปรแกรมมิ่ง": [.en: "Programming", .th: "โปรแกรมมิ่ง", .cn: "编程", .zhTW: "程式設計", .it: "Programmazione", .jp: "プログラミング", .fr: "Programmation", .de: "Programmierung", .es: "Programación", .ko: "프로그래밍", .vi: "Lập trình"],
        "ปัญญาประดิษฐ์": [.en: "Artificial Intelligence", .th: "ปัญญาประดิษฐ์", .cn: "人工智能", .zhTW: "人工智慧", .it: "Intelligenza artificiale", .jp: "人工知能", .fr: "Intelligence artificielle", .de: "Künstliche Intelligenz", .es: "Inteligencia artificial", .ko: "인공지능", .vi: "Trí tuệ nhân tạo"],
        "ความปลอดภัยไซเบอร์": [.en: "Cybersecurity", .th: "ความปลอดภัยไซเบอร์", .cn: "网络安全", .zhTW: "網路安全", .it: "Sicurezza informatica", .jp: "サイバーセキュリティ", .fr: "Cybersécurité", .de: "Cybersicherheit", .es: "Ciberseguridad", .ko: "사이버 보안", .vi: "An ninh mạng"],
        "ฐานข้อมูล": [.en: "Databases", .th: "ฐานข้อมูล", .cn: "数据库", .zhTW: "資料庫", .it: "Database", .jp: "データベース", .fr: "Bases de données", .de: "Datenbanken", .es: "Bases de datos", .ko: "데이터베이스", .vi: "Cơ sở dữ liệu"],
        "เครือข่าย": [.en: "Networks", .th: "เครือข่าย", .cn: "网络", .zhTW: "網路", .it: "Reti", .jp: "ネットワーク", .fr: "Réseaux", .de: "Netzwerke", .es: "Redes", .ko: "네트워크", .vi: "Mạng"],
        "นิยาย": [.en: "Novels", .th: "นิยาย", .cn: "小说", .zhTW: "小說", .it: "Romanzi", .jp: "小説", .fr: "Romans", .de: "Romane", .es: "Novelas", .ko: "소설", .vi: "Tiểu thuyết"],
        "เรื่องสั้น": [.en: "Short Stories", .th: "เรื่องสั้น", .cn: "短篇小说", .zhTW: "短篇小說", .it: "Racconti", .jp: "短編", .fr: "Nouvelles", .de: "Kurzgeschichten", .es: "Cuentos", .ko: "단편", .vi: "Truyện ngắn"],
        "บทกวี": [.en: "Poetry", .th: "บทกวี", .cn: "诗歌", .zhTW: "詩歌", .it: "Poesia", .jp: "詩", .fr: "Poésie", .de: "Lyrik", .es: "Poesía", .ko: "시", .vi: "Thơ"],
        "วรรณคดี": [.en: "Classics", .th: "วรรณคดี", .cn: "经典文学", .zhTW: "古典文學", .it: "Classici", .jp: "古典文学", .fr: "Classiques", .de: "Klassiker", .es: "Clásicos", .ko: "고전문학", .vi: "Văn học cổ điển"],
        "การเขียน": [.en: "Writing", .th: "การเขียน", .cn: "写作", .zhTW: "寫作", .it: "Scrittura", .jp: "執筆", .fr: "Écriture", .de: "Schreiben", .es: "Escritura", .ko: "글쓰기", .vi: "Viết"],
        "การเมือง": [.en: "Politics", .th: "การเมือง", .cn: "政治", .zhTW: "政治", .it: "Politica", .jp: "政治", .fr: "Politique", .de: "Politik", .es: "Política", .ko: "정치", .vi: "Chính trị"],
        "กฎหมาย": [.en: "Law", .th: "กฎหมาย", .cn: "法律", .zhTW: "法律", .it: "Diritto", .jp: "法律", .fr: "Droit", .de: "Recht", .es: "Derecho", .ko: "법", .vi: "Luật"],
        "การศึกษา": [.en: "Education", .th: "การศึกษา", .cn: "教育", .zhTW: "教育", .it: "Istruzione", .jp: "教育", .fr: "Éducation", .de: "Bildung", .es: "Educación", .ko: "교육", .vi: "Giáo dục"],
        "วัฒนธรรม": [.en: "Culture", .th: "วัฒนธรรม", .cn: "文化", .zhTW: "文化", .it: "Cultura", .jp: "文化", .fr: "Culture", .de: "Kultur", .es: "Cultura", .ko: "문화", .vi: "Văn hóa"],
        "จิตวิทยา": [.en: "Psychology", .th: "จิตวิทยา", .cn: "心理学", .zhTW: "心理學", .it: "Psicologia", .jp: "心理学", .fr: "Psychologie", .de: "Psychologie", .es: "Psicología", .ko: "심리학", .vi: "Tâm lý học"],
        "ศิลปะ": [.en: "Art", .th: "ศิลปะ", .cn: "艺术", .zhTW: "藝術", .it: "Arte", .jp: "アート", .fr: "Art", .de: "Kunst", .es: "Arte", .ko: "예술", .vi: "Nghệ thuật"],
        "ดนตรี": [.en: "Music", .th: "ดนตรี", .cn: "音乐", .zhTW: "音樂", .it: "Musica", .jp: "音楽", .fr: "Musique", .de: "Musik", .es: "Música", .ko: "음악", .vi: "Âm nhạc"],
        "ภาพยนตร์": [.en: "Film", .th: "ภาพยนตร์", .cn: "电影", .zhTW: "電影", .it: "Cinema", .jp: "映画", .fr: "Cinéma", .de: "Film", .es: "Cine", .ko: "영화", .vi: "Điện ảnh"],
        "การออกแบบ": [.en: "Design", .th: "การออกแบบ", .cn: "设计", .zhTW: "設計", .it: "Design", .jp: "デザイン", .fr: "Design", .de: "Design", .es: "Diseño", .ko: "디자인", .vi: "Thiết kế"],
        "การถ่ายภาพ": [.en: "Photography", .th: "การถ่ายภาพ", .cn: "摄影", .zhTW: "攝影", .it: "Fotografia", .jp: "写真", .fr: "Photographie", .de: "Fotografie", .es: "Fotografía", .ko: "사진", .vi: "Nhiếp ảnh"],
        "สุขภาพ": [.en: "Health", .th: "สุขภาพ", .cn: "健康", .zhTW: "健康", .it: "Salute", .jp: "健康", .fr: "Santé", .de: "Gesundheit", .es: "Salud", .ko: "건강", .vi: "Sức khỏe"],
        "แพทยศาสตร์": [.en: "Medicine", .th: "แพทยศาสตร์", .cn: "医学", .zhTW: "醫學", .it: "Medicina", .jp: "医学", .fr: "Médecine", .de: "Medizin", .es: "Medicina", .ko: "의학", .vi: "Y học"],
        "โภชนาการ": [.en: "Nutrition", .th: "โภชนาการ", .cn: "营养", .zhTW: "營養", .it: "Nutrizione", .jp: "栄養", .fr: "Nutrition", .de: "Ernährung", .es: "Nutrición", .ko: "영양", .vi: "Dinh dưỡng"],
        "ออกกำลังกาย": [.en: "Fitness", .th: "ออกกำลังกาย", .cn: "健身", .zhTW: "健身", .it: "Fitness", .jp: "フィットネス", .fr: "Fitness", .de: "Fitness", .es: "Fitness", .ko: "피트니스", .vi: "Thể dục"],
        "จิตใจ": [.en: "Mental Wellness", .th: "จิตใจ", .cn: "心理健康", .zhTW: "心理健康", .it: "Benessere mentale", .jp: "メンタルヘルス", .fr: "Bien-être mental", .de: "Mentales Wohlbefinden", .es: "Bienestar mental", .ko: "마음 건강", .vi: "Sức khỏe tinh thần"],
        "ประวัติศาสตร์": [.en: "History", .th: "ประวัติศาสตร์", .cn: "历史", .zhTW: "歷史", .it: "Storia", .jp: "歴史", .fr: "Histoire", .de: "Geschichte", .es: "Historia", .ko: "역사", .vi: "Lịch sử"],
        "ภูมิศาสตร์": [.en: "Geography", .th: "ภูมิศาสตร์", .cn: "地理", .zhTW: "地理", .it: "Geografia", .jp: "地理", .fr: "Géographie", .de: "Geografie", .es: "Geografía", .ko: "지리", .vi: "Địa lý"],
        "ชีวประวัติ": [.en: "Biography", .th: "ชีวประวัติ", .cn: "传记", .zhTW: "傳記", .it: "Biografia", .jp: "伝記", .fr: "Biographie", .de: "Biografie", .es: "Biografía", .ko: "전기", .vi: "Tiểu sử"],
        "การเดินทาง": [.en: "Travel", .th: "การเดินทาง", .cn: "旅行", .zhTW: "旅行", .it: "Viaggi", .jp: "旅行", .fr: "Voyage", .de: "Reisen", .es: "Viajes", .ko: "여행", .vi: "Du lịch"],
        "แผนที่": [.en: "Maps", .th: "แผนที่", .cn: "地图", .zhTW: "地圖", .it: "Mappe", .jp: "地図", .fr: "Cartes", .de: "Karten", .es: "Mapas", .ko: "지도", .vi: "Bản đồ"]
    ]

    private static let extraTranslations: [SystemLanguage: [String: String]] = [
        .zhTW: [
            "import_help": "將 EPUB、PDF 或 CBZ 匯入 %@",
            "app_subtitle": "依語言、科學、商業與工程分類的電子書架。",
            "shelves_unit": "層", "books_unit": "本", "add": "新增",
            "delete_from_shelf": "從書架移除", "delete_confirm": "要從書架移除這本書嗎？", "cancel": "取消",
            "no_file_title": "沒有書籍檔案", "no_file_description": "使用書架上的新增封面匯入 EPUB、PDF 或 CBZ。",
            "cbz_open_failed": "無法開啟 CBZ", "loading_cbz": "正在開啟 CBZ...", "no_images_cbz": "CBZ 中找不到圖片",
            "epub_open_failed": "無法開啟 EPUB", "loading_epub": "正在開啟 EPUB...", "no_spine_epub": "EPUB 中找不到可閱讀的 spine",
            "previous": "上一頁", "next": "下一頁", "translate_selection": "翻譯所選文字",
            "translation_title": "翻譯", "selected_text": "所選文字", "translated_text": "譯文", "translating": "正在翻譯...",
            "หมวดหมู่ภาษา": "語言", "หมวดหมู่วิทยาศาสตร์": "科學", "หมวดหมู่บริหารธุรกิจ": "工商管理", "หมวดหมู่วิศวกรรม": "工程",
            "วิศวกรรม": "工程", "บริหารธุรกิจ": "商業",
            "ไทย": "泰語", "อังกฤษ": "英語", "จีน": "中文", "ญี่ปุ่น": "日語", "อิตาลี": "義大利語", "เยอรมัน": "德語", "ฝรั่งเศส": "法語",
            "ฟิสิกส์": "物理", "เคมี": "化學", "ชีวะ": "生物", "บัญชี": "會計", "การเงิน": "金融", "การตลาด": "行銷", "เศรษฐศาสตร์": "經濟學",
            "เครื่องกล": "機械", "ไฟฟ้าอิเล็กทรอนิกส์": "電氣與電子", "วิศวกรรมเคมี": "化學工程", "วิศวกรรมพันธุกรรม": "基因工程", "ไฟฟ้า": "電氣", "คอมพิวเตอร์": "電腦"
        ],
        .ar: [
            "import_help": "استيراد EPUB أو PDF أو CBZ إلى %@",
            "app_subtitle": "رف كتب إلكترونية منظم حسب اللغة والعلوم والأعمال والهندسة.",
            "shelves_unit": "رفوف", "books_unit": "كتب", "add": "إضافة",
            "delete_from_shelf": "إزالة من الرف", "delete_confirm": "إزالة هذا الكتاب من الرف؟", "cancel": "إلغاء",
            "no_file_title": "لا يوجد ملف كتاب", "no_file_description": "استورد EPUB أو PDF أو CBZ باستخدام غلاف الإضافة على الرف.",
            "cbz_open_failed": "تعذر فتح CBZ", "loading_cbz": "جار فتح CBZ...", "no_images_cbz": "لم يتم العثور على صور في CBZ",
            "epub_open_failed": "تعذر فتح EPUB", "loading_epub": "جار فتح EPUB...", "no_spine_epub": "لم يتم العثور على صفحات قابلة للقراءة في EPUB",
            "previous": "السابق", "next": "التالي", "translate_selection": "ترجمة التحديد",
            "translation_title": "الترجمة", "selected_text": "النص المحدد", "translated_text": "الترجمة", "translating": "جار الترجمة...",
            "หมวดหมู่ภาษา": "اللغات", "หมวดหมู่วิทยาศาสตร์": "العلوم", "หมวดหมู่บริหารธุรกิจ": "إدارة الأعمال", "หมวดหมู่วิศวกรรม": "الهندسة",
            "วิศวกรรม": "الهندسة", "บริหารธุรกิจ": "الأعمال",
            "ไทย": "التايلاندية", "อังกฤษ": "الإنجليزية", "จีน": "الصينية", "ญี่ปุ่น": "اليابانية", "อิตาลี": "الإيطالية", "เยอรมัน": "الألمانية", "ฝรั่งเศส": "الفرنسية",
            "ฟิสิกส์": "الفيزياء", "เคมี": "الكيمياء", "ชีวะ": "الأحياء", "บัญชี": "المحاسبة", "การเงิน": "المالية", "การตลาด": "التسويق", "เศรษฐศาสตร์": "الاقتصاد",
            "เครื่องกล": "الميكانيكا", "ไฟฟ้าอิเล็กทรอนิกส์": "الكهرباء والإلكترونيات", "วิศวกรรมเคมี": "الهندسة الكيميائية", "วิศวกรรมพันธุกรรม": "الهندسة الوراثية", "ไฟฟ้า": "الكهرباء", "คอมพิวเตอร์": "الحاسوب"
        ],
        .nl: [
            "import_help": "Importeer EPUB, PDF of CBZ naar %@",
            "app_subtitle": "Een e-bookkast geordend op taal, wetenschap, business en techniek.",
            "shelves_unit": "planken", "books_unit": "boeken", "add": "Toevoegen",
            "delete_from_shelf": "Verwijderen van plank", "delete_confirm": "Dit boek van de plank verwijderen?", "cancel": "Annuleren",
            "no_file_title": "Geen boekbestand", "no_file_description": "Importeer een EPUB, PDF of CBZ met de toevoegcover op een plank.",
            "cbz_open_failed": "Kan CBZ niet openen", "loading_cbz": "CBZ openen...", "no_images_cbz": "Geen afbeeldingen gevonden in CBZ",
            "epub_open_failed": "Kan EPUB niet openen", "loading_epub": "EPUB openen...", "no_spine_epub": "Geen leesbare spine gevonden in EPUB",
            "previous": "Vorige", "next": "Volgende", "translate_selection": "Selectie vertalen",
            "translation_title": "Vertaling", "selected_text": "Geselecteerde tekst", "translated_text": "Vertaling", "translating": "Vertalen...",
            "หมวดหมู่ภาษา": "Talen", "หมวดหมู่วิทยาศาสตร์": "Wetenschap", "หมวดหมู่บริหารธุรกิจ": "Bedrijfskunde", "หมวดหมู่วิศวกรรม": "Techniek",
            "วิศวกรรม": "Techniek", "บริหารธุรกิจ": "Business",
            "ไทย": "Thai", "อังกฤษ": "Engels", "จีน": "Chinees", "ญี่ปุ่น": "Japans", "อิตาลี": "Italiaans", "เยอรมัน": "Duits", "ฝรั่งเศส": "Frans",
            "ฟิสิกส์": "Natuurkunde", "เคมี": "Scheikunde", "ชีวะ": "Biologie", "บัญชี": "Boekhouding", "การเงิน": "Financiën", "การตลาด": "Marketing", "เศรษฐศาสตร์": "Economie",
            "เครื่องกล": "Werktuigbouw", "ไฟฟ้าอิเล็กทรอนิกส์": "Elektro en elektronica", "วิศวกรรมเคมี": "Chemische technologie", "วิศวกรรมพันธุกรรม": "Genetische technologie", "ไฟฟ้า": "Elektro", "คอมพิวเตอร์": "Computer"
        ],
        .fr: [
            "import_help": "Importer EPUB, PDF ou CBZ dans %@",
            "app_subtitle": "Une bibliothèque eBook organisée par langue, science, commerce et ingénierie.",
            "shelves_unit": "étagères", "books_unit": "livres", "add": "Ajouter",
            "delete_from_shelf": "Retirer de l'étagère", "delete_confirm": "Retirer ce livre de l'étagère ?", "cancel": "Annuler",
            "no_file_title": "Aucun fichier livre", "no_file_description": "Importez un EPUB, PDF ou CBZ avec la couverture d'ajout sur une étagère.",
            "cbz_open_failed": "Impossible d'ouvrir le CBZ", "loading_cbz": "Ouverture du CBZ...", "no_images_cbz": "Aucune image trouvée dans le CBZ",
            "epub_open_failed": "Impossible d'ouvrir l'EPUB", "loading_epub": "Ouverture de l'EPUB...", "no_spine_epub": "Aucun spine lisible trouvé dans l'EPUB",
            "previous": "Précédent", "next": "Suivant", "translate_selection": "Traduire la sélection",
            "translation_title": "Traduction", "selected_text": "Texte sélectionné", "translated_text": "Traduction", "translating": "Traduction...",
            "หมวดหมู่ภาษา": "Langues", "หมวดหมู่วิทยาศาสตร์": "Sciences", "หมวดหมู่บริหารธุรกิจ": "Administration des affaires", "หมวดหมู่วิศวกรรม": "Ingénierie",
            "วิศวกรรม": "Ingénierie", "บริหารธุรกิจ": "Affaires",
            "ไทย": "Thaï", "อังกฤษ": "Anglais", "จีน": "Chinois", "ญี่ปุ่น": "Japonais", "อิตาลี": "Italien", "เยอรมัน": "Allemand", "ฝรั่งเศส": "Français",
            "ฟิสิกส์": "Physique", "เคมี": "Chimie", "ชีวะ": "Biologie", "บัญชี": "Comptabilité", "การเงิน": "Finance", "การตลาด": "Marketing", "เศรษฐศาสตร์": "Économie",
            "เครื่องกล": "Mécanique", "ไฟฟ้าอิเล็กทรอนิกส์": "Électrique et électronique", "วิศวกรรมเคมี": "Génie chimique", "วิศวกรรมพันธุกรรม": "Génie génétique", "ไฟฟ้า": "Électrique", "คอมพิวเตอร์": "Informatique"
        ],
        .de: [
            "import_help": "EPUB, PDF oder CBZ in %@ importieren",
            "app_subtitle": "Ein eBook-Regal nach Sprache, Wissenschaft, Wirtschaft und Technik.",
            "shelves_unit": "Regale", "books_unit": "Bücher", "add": "Hinzufügen",
            "delete_from_shelf": "Aus Regal entfernen", "delete_confirm": "Dieses Buch aus dem Regal entfernen?", "cancel": "Abbrechen",
            "no_file_title": "Keine Buchdatei", "no_file_description": "Importiere EPUB, PDF oder CBZ über das Hinzufügen-Cover im Regal.",
            "cbz_open_failed": "CBZ konnte nicht geöffnet werden", "loading_cbz": "CBZ wird geöffnet...", "no_images_cbz": "Keine Bilder in CBZ gefunden",
            "epub_open_failed": "EPUB konnte nicht geöffnet werden", "loading_epub": "EPUB wird geöffnet...", "no_spine_epub": "Kein lesbarer Spine in EPUB gefunden",
            "previous": "Zurück", "next": "Weiter", "translate_selection": "Auswahl übersetzen",
            "translation_title": "Übersetzung", "selected_text": "Ausgewählter Text", "translated_text": "Übersetzung", "translating": "Übersetzen...",
            "หมวดหมู่ภาษา": "Sprachen", "หมวดหมู่วิทยาศาสตร์": "Wissenschaft", "หมวดหมู่บริหารธุรกิจ": "Betriebswirtschaft", "หมวดหมู่วิศวกรรม": "Ingenieurwesen",
            "วิศวกรรม": "Ingenieurwesen", "บริหารธุรกิจ": "Wirtschaft",
            "ไทย": "Thai", "อังกฤษ": "Englisch", "จีน": "Chinesisch", "ญี่ปุ่น": "Japanisch", "อิตาลี": "Italienisch", "เยอรมัน": "Deutsch", "ฝรั่งเศส": "Französisch",
            "ฟิสิกส์": "Physik", "เคมี": "Chemie", "ชีวะ": "Biologie", "บัญชี": "Buchhaltung", "การเงิน": "Finanzen", "การตลาด": "Marketing", "เศรษฐศาสตร์": "Volkswirtschaft",
            "เครื่องกล": "Maschinenbau", "ไฟฟ้าอิเล็กทรอนิกส์": "Elektro und Elektronik", "วิศวกรรมเคมี": "Chemieingenieurwesen", "วิศวกรรมพันธุกรรม": "Gentechnik", "ไฟฟ้า": "Elektro", "คอมพิวเตอร์": "Computer"
        ],
        .hi: [
            "import_help": "%@ में EPUB, PDF या CBZ आयात करें",
            "app_subtitle": "भाषा, विज्ञान, व्यवसाय और इंजीनियरिंग के अनुसार व्यवस्थित eBook शेल्फ।",
            "shelves_unit": "शेल्फ", "books_unit": "किताबें", "add": "जोड़ें",
            "delete_from_shelf": "शेल्फ से हटाएँ", "delete_confirm": "इस किताब को शेल्फ से हटाएँ?", "cancel": "रद्द करें",
            "no_file_title": "कोई पुस्तक फ़ाइल नहीं", "no_file_description": "शेल्फ पर जोड़ें कवर से EPUB, PDF या CBZ आयात करें।",
            "cbz_open_failed": "CBZ नहीं खुल सका", "loading_cbz": "CBZ खोला जा रहा है...", "no_images_cbz": "CBZ में कोई चित्र नहीं मिला",
            "epub_open_failed": "EPUB नहीं खुल सका", "loading_epub": "EPUB खोला जा रहा है...", "no_spine_epub": "EPUB में पढ़ने योग्य spine नहीं मिला",
            "previous": "पिछला", "next": "अगला", "translate_selection": "चयन का अनुवाद करें",
            "translation_title": "अनुवाद", "selected_text": "चयनित पाठ", "translated_text": "अनुवाद", "translating": "अनुवाद हो रहा है...",
            "หมวดหมู่ภาษา": "भाषाएँ", "หมวดหมู่วิทยาศาสตร์": "विज्ञान", "หมวดหมู่บริหารธุรกิจ": "व्यवसाय प्रशासन", "หมวดหมู่วิศวกรรม": "इंजीनियरिंग",
            "วิศวกรรม": "इंजीनियरिंग", "บริหารธุรกิจ": "व्यवसाय",
            "ไทย": "थाई", "อังกฤษ": "अंग्रेज़ी", "จีน": "चीनी", "ญี่ปุ่น": "जापानी", "อิตาลี": "इतालवी", "เยอรมัน": "जर्मन", "ฝรั่งเศส": "फ़्रेंच",
            "ฟิสิกส์": "भौतिकी", "เคมี": "रसायन", "ชีวะ": "जीवविज्ञान", "บัญชี": "लेखा", "การเงิน": "वित्त", "การตลาด": "मार्केटिंग", "เศรษฐศาสตร์": "अर्थशास्त्र",
            "เครื่องกล": "मैकेनिकल", "ไฟฟ้าอิเล็กทรอนิกส์": "इलेक्ट्रिकल और इलेक्ट्रॉनिक्स", "วิศวกรรมเคมี": "केमिकल इंजीनियरिंग", "วิศวกรรมพันธุกรรม": "जेनेटिक इंजीनियरिंग", "ไฟฟ้า": "इलेक्ट्रिकल", "คอมพิวเตอร์": "कंप्यूटर"
        ],
        .id: [
            "import_help": "Impor EPUB, PDF, atau CBZ ke %@",
            "app_subtitle": "Rak eBook yang diatur menurut bahasa, sains, bisnis, dan teknik.",
            "shelves_unit": "rak", "books_unit": "buku", "add": "Tambah",
            "delete_from_shelf": "Hapus dari rak", "delete_confirm": "Hapus buku ini dari rak?", "cancel": "Batal",
            "no_file_title": "Tidak ada file buku", "no_file_description": "Impor EPUB, PDF, atau CBZ memakai sampul tambah di rak.",
            "cbz_open_failed": "Tidak dapat membuka CBZ", "loading_cbz": "Membuka CBZ...", "no_images_cbz": "Tidak ada gambar di CBZ",
            "epub_open_failed": "Tidak dapat membuka EPUB", "loading_epub": "Membuka EPUB...", "no_spine_epub": "Tidak ada spine yang bisa dibaca di EPUB",
            "previous": "Sebelumnya", "next": "Berikutnya", "translate_selection": "Terjemahkan pilihan",
            "translation_title": "Terjemahan", "selected_text": "Teks dipilih", "translated_text": "Terjemahan", "translating": "Menerjemahkan...",
            "หมวดหมู่ภาษา": "Bahasa", "หมวดหมู่วิทยาศาสตร์": "Sains", "หมวดหมู่บริหารธุรกิจ": "Administrasi Bisnis", "หมวดหมู่วิศวกรรม": "Teknik",
            "วิศวกรรม": "Teknik", "บริหารธุรกิจ": "Bisnis",
            "ไทย": "Thai", "อังกฤษ": "Inggris", "จีน": "Tionghoa", "ญี่ปุ่น": "Jepang", "อิตาลี": "Italia", "เยอรมัน": "Jerman", "ฝรั่งเศส": "Prancis",
            "ฟิสิกส์": "Fisika", "เคมี": "Kimia", "ชีวะ": "Biologi", "บัญชี": "Akuntansi", "การเงิน": "Keuangan", "การตลาด": "Pemasaran", "เศรษฐศาสตร์": "Ekonomi",
            "เครื่องกล": "Mesin", "ไฟฟ้าอิเล็กทรอนิกส์": "Listrik dan Elektronik", "วิศวกรรมเคมี": "Teknik Kimia", "วิศวกรรมพันธุกรรม": "Rekayasa Genetika", "ไฟฟ้า": "Listrik", "คอมพิวเตอร์": "Komputer"
        ],
        .ko: [
            "import_help": "%@에 EPUB, PDF 또는 CBZ 가져오기",
            "app_subtitle": "언어, 과학, 비즈니스, 공학으로 정리한 eBook 책장입니다.",
            "shelves_unit": "칸", "books_unit": "권", "add": "추가",
            "delete_from_shelf": "책장에서 제거", "delete_confirm": "이 책을 책장에서 제거할까요?", "cancel": "취소",
            "no_file_title": "책 파일 없음", "no_file_description": "책장의 추가 표지를 사용해 EPUB, PDF 또는 CBZ를 가져오세요.",
            "cbz_open_failed": "CBZ를 열 수 없음", "loading_cbz": "CBZ 여는 중...", "no_images_cbz": "CBZ에서 이미지를 찾을 수 없음",
            "epub_open_failed": "EPUB를 열 수 없음", "loading_epub": "EPUB 여는 중...", "no_spine_epub": "EPUB에서 읽을 수 있는 spine을 찾을 수 없음",
            "previous": "이전", "next": "다음", "translate_selection": "선택 영역 번역",
            "translation_title": "번역", "selected_text": "선택한 텍스트", "translated_text": "번역", "translating": "번역 중...",
            "หมวดหมู่ภาษา": "언어", "หมวดหมู่วิทยาศาสตร์": "과학", "หมวดหมู่บริหารธุรกิจ": "경영학", "หมวดหมู่วิศวกรรม": "공학",
            "วิศวกรรม": "공학", "บริหารธุรกิจ": "비즈니스",
            "ไทย": "태국어", "อังกฤษ": "영어", "จีน": "중국어", "ญี่ปุ่น": "일본어", "อิตาลี": "이탈리아어", "เยอรมัน": "독일어", "ฝรั่งเศส": "프랑스어",
            "ฟิสิกส์": "물리", "เคมี": "화학", "ชีวะ": "생물", "บัญชี": "회계", "การเงิน": "금융", "การตลาด": "마케팅", "เศรษฐศาสตร์": "경제학",
            "เครื่องกล": "기계", "ไฟฟ้าอิเล็กทรอนิกส์": "전기 전자", "วิศวกรรมเคมี": "화학공학", "วิศวกรรมพันธุกรรม": "유전공학", "ไฟฟ้า": "전기", "คอมพิวเตอร์": "컴퓨터"
        ],
        .pl: [
            "import_help": "Importuj EPUB, PDF lub CBZ do %@",
            "app_subtitle": "Półka eBooków uporządkowana według języka, nauki, biznesu i inżynierii.",
            "shelves_unit": "półki", "books_unit": "książki", "add": "Dodaj",
            "delete_from_shelf": "Usuń z półki", "delete_confirm": "Usunąć tę książkę z półki?", "cancel": "Anuluj",
            "no_file_title": "Brak pliku książki", "no_file_description": "Importuj EPUB, PDF lub CBZ za pomocą okładki dodawania na półce.",
            "cbz_open_failed": "Nie można otworzyć CBZ", "loading_cbz": "Otwieranie CBZ...", "no_images_cbz": "Nie znaleziono obrazów w CBZ",
            "epub_open_failed": "Nie można otworzyć EPUB", "loading_epub": "Otwieranie EPUB...", "no_spine_epub": "Nie znaleziono czytelnego spine w EPUB",
            "previous": "Poprzednia", "next": "Następna", "translate_selection": "Przetłumacz zaznaczenie",
            "translation_title": "Tłumaczenie", "selected_text": "Zaznaczony tekst", "translated_text": "Tłumaczenie", "translating": "Tłumaczenie...",
            "หมวดหมู่ภาษา": "Języki", "หมวดหมู่วิทยาศาสตร์": "Nauka", "หมวดหมู่บริหารธุรกิจ": "Zarządzanie biznesem", "หมวดหมู่วิศวกรรม": "Inżynieria",
            "วิศวกรรม": "Inżynieria", "บริหารธุรกิจ": "Biznes",
            "ไทย": "Tajski", "อังกฤษ": "Angielski", "จีน": "Chiński", "ญี่ปุ่น": "Japoński", "อิตาลี": "Włoski", "เยอรมัน": "Niemiecki", "ฝรั่งเศส": "Francuski",
            "ฟิสิกส์": "Fizyka", "เคมี": "Chemia", "ชีวะ": "Biologia", "บัญชี": "Rachunkowość", "การเงิน": "Finanse", "การตลาด": "Marketing", "เศรษฐศาสตร์": "Ekonomia",
            "เครื่องกล": "Mechanika", "ไฟฟ้าอิเล็กทรอนิกส์": "Elektryka i elektronika", "วิศวกรรมเคมี": "Inżynieria chemiczna", "วิศวกรรมพันธุกรรม": "Inżynieria genetyczna", "ไฟฟ้า": "Elektryka", "คอมพิวเตอร์": "Komputer"
        ],
        .pt: [
            "import_help": "Importar EPUB, PDF ou CBZ para %@",
            "app_subtitle": "Uma estante de eBooks organizada por idioma, ciência, negócios e engenharia.",
            "shelves_unit": "prateleiras", "books_unit": "livros", "add": "Adicionar",
            "delete_from_shelf": "Remover da prateleira", "delete_confirm": "Remover este livro da prateleira?", "cancel": "Cancelar",
            "no_file_title": "Nenhum arquivo de livro", "no_file_description": "Importe EPUB, PDF ou CBZ usando a capa de adicionar na prateleira.",
            "cbz_open_failed": "Não foi possível abrir o CBZ", "loading_cbz": "Abrindo CBZ...", "no_images_cbz": "Nenhuma imagem encontrada no CBZ",
            "epub_open_failed": "Não foi possível abrir o EPUB", "loading_epub": "Abrindo EPUB...", "no_spine_epub": "Nenhum spine legível encontrado no EPUB",
            "previous": "Anterior", "next": "Próxima", "translate_selection": "Traduzir seleção",
            "translation_title": "Tradução", "selected_text": "Texto selecionado", "translated_text": "Tradução", "translating": "Traduzindo...",
            "หมวดหมู่ภาษา": "Idiomas", "หมวดหมู่วิทยาศาสตร์": "Ciência", "หมวดหมู่บริหารธุรกิจ": "Administração de Empresas", "หมวดหมู่วิศวกรรม": "Engenharia",
            "วิศวกรรม": "Engenharia", "บริหารธุรกิจ": "Negócios",
            "ไทย": "Tailandês", "อังกฤษ": "Inglês", "จีน": "Chinês", "ญี่ปุ่น": "Japonês", "อิตาลี": "Italiano", "เยอรมัน": "Alemão", "ฝรั่งเศส": "Francês",
            "ฟิสิกส์": "Física", "เคมี": "Química", "ชีวะ": "Biologia", "บัญชี": "Contabilidade", "การเงิน": "Finanças", "การตลาด": "Marketing", "เศรษฐศาสตร์": "Economia",
            "เครื่องกล": "Mecânica", "ไฟฟ้าอิเล็กทรอนิกส์": "Elétrica e eletrônica", "วิศวกรรมเคมี": "Engenharia química", "วิศวกรรมพันธุกรรม": "Engenharia genética", "ไฟฟ้า": "Elétrica", "คอมพิวเตอร์": "Computador"
        ],
        .ru: [
            "import_help": "Импортировать EPUB, PDF или CBZ в %@",
            "app_subtitle": "Полка eBook, организованная по языкам, науке, бизнесу и инженерии.",
            "shelves_unit": "полки", "books_unit": "книги", "add": "Добавить",
            "delete_from_shelf": "Удалить с полки", "delete_confirm": "Удалить эту книгу с полки?", "cancel": "Отмена",
            "no_file_title": "Нет файла книги", "no_file_description": "Импортируйте EPUB, PDF или CBZ с помощью обложки добавления на полке.",
            "cbz_open_failed": "Не удалось открыть CBZ", "loading_cbz": "Открытие CBZ...", "no_images_cbz": "В CBZ не найдены изображения",
            "epub_open_failed": "Не удалось открыть EPUB", "loading_epub": "Открытие EPUB...", "no_spine_epub": "В EPUB не найден читаемый spine",
            "previous": "Назад", "next": "Далее", "translate_selection": "Перевести выделение",
            "translation_title": "Перевод", "selected_text": "Выделенный текст", "translated_text": "Перевод", "translating": "Перевод...",
            "หมวดหมู่ภาษา": "Языки", "หมวดหมู่วิทยาศาสตร์": "Наука", "หมวดหมู่บริหารธุรกิจ": "Деловое администрирование", "หมวดหมู่วิศวกรรม": "Инженерия",
            "วิศวกรรม": "Инженерия", "บริหารธุรกิจ": "Бизнес",
            "ไทย": "Тайский", "อังกฤษ": "Английский", "จีน": "Китайский", "ญี่ปุ่น": "Японский", "อิตาลี": "Итальянский", "เยอรมัน": "Немецкий", "ฝรั่งเศส": "Французский",
            "ฟิสิกส์": "Физика", "เคมี": "Химия", "ชีวะ": "Биология", "บัญชี": "Бухгалтерия", "การเงิน": "Финансы", "การตลาด": "Маркетинг", "เศรษฐศาสตร์": "Экономика",
            "เครื่องกล": "Механика", "ไฟฟ้าอิเล็กทรอนิกส์": "Электрика и электроника", "วิศวกรรมเคมี": "Химическая инженерия", "วิศวกรรมพันธุกรรม": "Генная инженерия", "ไฟฟ้า": "Электрика", "คอมพิวเตอร์": "Компьютер"
        ],
        .es: [
            "import_help": "Importar EPUB, PDF o CBZ a %@",
            "app_subtitle": "Una estantería de eBooks organizada por idioma, ciencia, negocios e ingeniería.",
            "shelves_unit": "estantes", "books_unit": "libros", "add": "Añadir",
            "delete_from_shelf": "Quitar del estante", "delete_confirm": "¿Quitar este libro del estante?", "cancel": "Cancelar",
            "no_file_title": "Sin archivo de libro", "no_file_description": "Importa EPUB, PDF o CBZ usando la cubierta de añadir en un estante.",
            "cbz_open_failed": "No se pudo abrir CBZ", "loading_cbz": "Abriendo CBZ...", "no_images_cbz": "No se encontraron imágenes en CBZ",
            "epub_open_failed": "No se pudo abrir EPUB", "loading_epub": "Abriendo EPUB...", "no_spine_epub": "No se encontró un spine legible en EPUB",
            "previous": "Anterior", "next": "Siguiente", "translate_selection": "Traducir selección",
            "translation_title": "Traducción", "selected_text": "Texto seleccionado", "translated_text": "Traducción", "translating": "Traduciendo...",
            "หมวดหมู่ภาษา": "Idiomas", "หมวดหมู่วิทยาศาสตร์": "Ciencia", "หมวดหมู่บริหารธุรกิจ": "Administración de empresas", "หมวดหมู่วิศวกรรม": "Ingeniería",
            "วิศวกรรม": "Ingeniería", "บริหารธุรกิจ": "Negocios",
            "ไทย": "Tailandés", "อังกฤษ": "Inglés", "จีน": "Chino", "ญี่ปุ่น": "Japonés", "อิตาลี": "Italiano", "เยอรมัน": "Alemán", "ฝรั่งเศส": "Francés",
            "ฟิสิกส์": "Física", "เคมี": "Química", "ชีวะ": "Biología", "บัญชี": "Contabilidad", "การเงิน": "Finanzas", "การตลาด": "Marketing", "เศรษฐศาสตร์": "Economía",
            "เครื่องกล": "Mecánica", "ไฟฟ้าอิเล็กทรอนิกส์": "Eléctrica y electrónica", "วิศวกรรมเคมี": "Ingeniería química", "วิศวกรรมพันธุกรรม": "Ingeniería genética", "ไฟฟ้า": "Eléctrica", "คอมพิวเตอร์": "Computadora"
        ],
        .tr: [
            "import_help": "%@ içine EPUB, PDF veya CBZ aktar",
            "app_subtitle": "Dil, bilim, işletme ve mühendisliğe göre düzenlenmiş bir eBook rafı.",
            "shelves_unit": "raf", "books_unit": "kitap", "add": "Ekle",
            "delete_from_shelf": "Raftan kaldır", "delete_confirm": "Bu kitabı raftan kaldır?", "cancel": "İptal",
            "no_file_title": "Kitap dosyası yok", "no_file_description": "Raftaki ekleme kapağını kullanarak EPUB, PDF veya CBZ içe aktarın.",
            "cbz_open_failed": "CBZ açılamadı", "loading_cbz": "CBZ açılıyor...", "no_images_cbz": "CBZ içinde resim bulunamadı",
            "epub_open_failed": "EPUB açılamadı", "loading_epub": "EPUB açılıyor...", "no_spine_epub": "EPUB içinde okunabilir spine bulunamadı",
            "previous": "Önceki", "next": "Sonraki", "translate_selection": "Seçimi çevir",
            "translation_title": "Çeviri", "selected_text": "Seçili metin", "translated_text": "Çeviri", "translating": "Çevriliyor...",
            "หมวดหมู่ภาษา": "Diller", "หมวดหมู่วิทยาศาสตร์": "Bilim", "หมวดหมู่บริหารธุรกิจ": "İşletme Yönetimi", "หมวดหมู่วิศวกรรม": "Mühendislik",
            "วิศวกรรม": "Mühendislik", "บริหารธุรกิจ": "İşletme",
            "ไทย": "Tayca", "อังกฤษ": "İngilizce", "จีน": "Çince", "ญี่ปุ่น": "Japonca", "อิตาลี": "İtalyanca", "เยอรมัน": "Almanca", "ฝรั่งเศส": "Fransızca",
            "ฟิสิกส์": "Fizik", "เคมี": "Kimya", "ชีวะ": "Biyoloji", "บัญชี": "Muhasebe", "การเงิน": "Finans", "การตลาด": "Pazarlama", "เศรษฐศาสตร์": "Ekonomi",
            "เครื่องกล": "Makine", "ไฟฟ้าอิเล็กทรอนิกส์": "Elektrik ve elektronik", "วิศวกรรมเคมี": "Kimya mühendisliği", "วิศวกรรมพันธุกรรม": "Genetik mühendisliği", "ไฟฟ้า": "Elektrik", "คอมพิวเตอร์": "Bilgisayar"
        ],
        .uk: [
            "import_help": "Імпортувати EPUB, PDF або CBZ до %@",
            "app_subtitle": "Полиця eBook, упорядкована за мовою, наукою, бізнесом та інженерією.",
            "shelves_unit": "полиці", "books_unit": "книги", "add": "Додати",
            "delete_from_shelf": "Прибрати з полиці", "delete_confirm": "Прибрати цю книгу з полиці?", "cancel": "Скасувати",
            "no_file_title": "Немає файлу книги", "no_file_description": "Імпортуйте EPUB, PDF або CBZ за допомогою обкладинки додавання на полиці.",
            "cbz_open_failed": "Не вдалося відкрити CBZ", "loading_cbz": "Відкриття CBZ...", "no_images_cbz": "У CBZ не знайдено зображень",
            "epub_open_failed": "Не вдалося відкрити EPUB", "loading_epub": "Відкриття EPUB...", "no_spine_epub": "В EPUB не знайдено читабельний spine",
            "previous": "Назад", "next": "Далі", "translate_selection": "Перекласти виділення",
            "translation_title": "Переклад", "selected_text": "Виділений текст", "translated_text": "Переклад", "translating": "Переклад...",
            "หมวดหมู่ภาษา": "Мови", "หมวดหมู่วิทยาศาสตร์": "Наука", "หมวดหมู่บริหารธุรกิจ": "Бізнес-адміністрування", "หมวดหมู่วิศวกรรม": "Інженерія",
            "วิศวกรรม": "Інженерія", "บริหารธุรกิจ": "Бізнес",
            "ไทย": "Тайська", "อังกฤษ": "Англійська", "จีน": "Китайська", "ญี่ปุ่น": "Японська", "อิตาลี": "Італійська", "เยอรมัน": "Німецька", "ฝรั่งเศส": "Французька",
            "ฟิสิกส์": "Фізика", "เคมี": "Хімія", "ชีวะ": "Біологія", "บัญชี": "Бухгалтерія", "การเงิน": "Фінанси", "การตลาด": "Маркетинг", "เศรษฐศาสตร์": "Економіка",
            "เครื่องกล": "Механіка", "ไฟฟ้าอิเล็กทรอนิกส์": "Електрика та електроніка", "วิศวกรรมเคมี": "Хімічна інженерія", "วิศวกรรมพันธุกรรม": "Генна інженерія", "ไฟฟ้า": "Електрика", "คอมพิวเตอร์": "Комп'ютер"
        ],
        .vi: [
            "import_help": "Nhập EPUB, PDF hoặc CBZ vào %@",
            "app_subtitle": "Tủ eBook được sắp xếp theo ngôn ngữ, khoa học, kinh doanh và kỹ thuật.",
            "shelves_unit": "kệ", "books_unit": "sách", "add": "Thêm",
            "delete_from_shelf": "Xóa khỏi kệ", "delete_confirm": "Xóa sách này khỏi kệ?", "cancel": "Hủy",
            "no_file_title": "Chưa có tệp sách", "no_file_description": "Nhập EPUB, PDF hoặc CBZ bằng bìa thêm sách trên kệ.",
            "cbz_open_failed": "Không thể mở CBZ", "loading_cbz": "Đang mở CBZ...", "no_images_cbz": "Không tìm thấy hình ảnh trong CBZ",
            "epub_open_failed": "Không thể mở EPUB", "loading_epub": "Đang mở EPUB...", "no_spine_epub": "Không tìm thấy spine đọc được trong EPUB",
            "previous": "Trước", "next": "Tiếp", "translate_selection": "Dịch phần chọn",
            "translation_title": "Bản dịch", "selected_text": "Văn bản đã chọn", "translated_text": "Bản dịch", "translating": "Đang dịch...",
            "หมวดหมู่ภาษา": "Ngôn ngữ", "หมวดหมู่วิทยาศาสตร์": "Khoa học", "หมวดหมู่บริหารธุรกิจ": "Quản trị kinh doanh", "หมวดหมู่วิศวกรรม": "Kỹ thuật",
            "วิศวกรรม": "Kỹ thuật", "บริหารธุรกิจ": "Kinh doanh",
            "ไทย": "Tiếng Thái", "อังกฤษ": "Tiếng Anh", "จีน": "Tiếng Trung", "ญี่ปุ่น": "Tiếng Nhật", "อิตาลี": "Tiếng Ý", "เยอรมัน": "Tiếng Đức", "ฝรั่งเศส": "Tiếng Pháp",
            "ฟิสิกส์": "Vật lý", "เคมี": "Hóa học", "ชีวะ": "Sinh học", "บัญชี": "Kế toán", "การเงิน": "Tài chính", "การตลาด": "Tiếp thị", "เศรษฐศาสตร์": "Kinh tế học",
            "เครื่องกล": "Cơ khí", "ไฟฟ้าอิเล็กทรอนิกส์": "Điện và điện tử", "วิศวกรรมเคมี": "Kỹ thuật hóa học", "วิศวกรรมพันธุกรรม": "Kỹ thuật di truyền", "ไฟฟ้า": "Điện", "คอมพิวเตอร์": "Máy tính"
        ]
    ]
}

private enum EBookFormat: String, CaseIterable {
    case epub
    case pdf
    case cbz

    init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }

    var displayName: String {
        rawValue.uppercased()
    }

    static var allowedContentTypes: [UTType] {
        [.pdf, UTType(filenameExtension: "epub") ?? .data, UTType(filenameExtension: "cbz") ?? .zip]
    }
}

private enum BookFileStore {
    static func copyIntoLibrary(_ sourceURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let libraryURL = supportURL.appendingPathComponent("CodexShelf").appendingPathComponent("Books", isDirectory: true)
        try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)

        let cleanName = sourceURL.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        var destinationURL = libraryURL.appendingPathComponent(cleanName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            let base = destinationURL.deletingPathExtension().lastPathComponent
            let ext = destinationURL.pathExtension
            destinationURL = libraryURL.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).\(ext)")
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    static func removeStoredFiles(for book: Book) {
        let fileManager = FileManager.default
        if let filePath = book.filePath, !filePath.isEmpty {
            try? fileManager.removeItem(atPath: filePath)
        }
        if let coverImagePath = book.coverImagePath, !coverImagePath.isEmpty {
            try? fileManager.removeItem(atPath: coverImagePath)
        }
    }
}

private enum CoverImageStore {
    static func createCover(for bookURL: URL, format: EBookFormat) throws -> URL? {
        let sourceImage: NSImage?

        switch format {
        case .pdf:
            sourceImage = PDFDocument(url: bookURL)?.page(at: 0)?.thumbnail(of: CGSize(width: 420, height: 620), for: .mediaBox)
        case .cbz:
            let extractedURL = try ArchiveExtractor.extract(bookURL)
            sourceImage = firstImage(in: extractedURL)
        case .epub:
            let extractedURL = try ArchiveExtractor.extract(bookURL)
            sourceImage = try epubCoverImage(in: extractedURL) ?? firstImage(in: extractedURL)
        }

        guard let sourceImage else { return nil }
        return try saveCover(sourceImage, named: bookURL.deletingPathExtension().lastPathComponent)
    }

    private static func epubCoverImage(in extractedURL: URL) throws -> NSImage? {
        let containerURL = extractedURL.appendingPathComponent("META-INF").appendingPathComponent("container.xml")
        let opfPath = try EPUBContainerParser.rootFilePath(from: containerURL)
        let opfURL = extractedURL.appending(path: opfPath)
        let opf = try EPUBPackageParser.package(from: opfURL)

        guard let coverHref = opf.coverHref else { return nil }
        let coverURL = opfURL.deletingLastPathComponent().appending(path: coverHref)
        return NSImage(contentsOf: coverURL)
    }

    private static func firstImage(in directoryURL: URL) -> NSImage? {
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: directoryURL.path) else { return nil }

        return paths
            .map { directoryURL.appendingPathComponent($0) }
            .filter { ["jpg", "jpeg", "png", "webp", "gif"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .lazy
            .compactMap { NSImage(contentsOf: $0) }
            .first
    }

    private static func saveCover(_ image: NSImage, named name: String) throws -> URL? {
        guard let data = image.jpegData(compressionFactor: 0.82) else { return nil }

        let fileManager = FileManager.default
        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let coversURL = supportURL.appendingPathComponent("CodexShelf").appendingPathComponent("Covers", isDirectory: true)
        try fileManager.createDirectory(at: coversURL, withIntermediateDirectories: true)

        let cleanName = name.replacingOccurrences(of: "/", with: "-")
        let destinationURL = coversURL.appendingPathComponent("\(cleanName)-\(UUID().uuidString.prefix(8)).jpg")
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }
}

private enum ArchiveExtractor {
    static func extract(_ archiveURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let tempURL = supportURL.appendingPathComponent("CodexShelf").appendingPathComponent("Temp", isDirectory: true)
        let destinationURL = tempURL.appendingPathComponent("CodexShelf-\(archiveURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-o", archiveURL.path, "-d", destinationURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return destinationURL
    }
}

private struct EPUBPackage {
    let spineHrefs: [String]
    let coverHref: String?
    let navHref: String?
    let ncxHref: String?
}

private final class EPUBContainerParser: NSObject, XMLParserDelegate {
    private var rootFilePath: String?

    static func rootFilePath(from url: URL) throws -> String {
        let parserDelegate = EPUBContainerParser()
        let parser = XMLParser(contentsOf: url)
        parser?.delegate = parserDelegate

        guard parser?.parse() == true, let rootFilePath = parserDelegate.rootFilePath else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return rootFilePath
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "rootfile" {
            if let fullPath = attributeDict["full-path"] {
                rootFilePath = fullPath.removingPercentEncoding ?? fullPath
            }
        }
    }
}

private final class EPUBPackageParser: NSObject, XMLParserDelegate {
    private var manifest: [String: String] = [:]
    private var properties: [String: String] = [:]
    private var mediaTypes: [String: String] = [:]
    private var spineIDs: [String] = []
    private var coverID: String?
    private var tocID: String?

    static func package(from url: URL) throws -> EPUBPackage {
        let parserDelegate = EPUBPackageParser()
        let parser = XMLParser(contentsOf: url)
        parser?.delegate = parserDelegate

        guard parser?.parse() == true else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let spineHrefs = parserDelegate.spineIDs.compactMap { parserDelegate.manifest[$0] }
        let coverImageID = parserDelegate.properties.first {
            $0.value.components(separatedBy: .whitespaces).contains("cover-image")
        }?.key
        let coverHref = parserDelegate.coverID.flatMap { parserDelegate.manifest[$0] }
            ?? coverImageID.flatMap { parserDelegate.manifest[$0] }
        let navID = parserDelegate.properties.first {
            $0.value.components(separatedBy: .whitespaces).contains("nav")
        }?.key
        let ncxID = parserDelegate.tocID
            ?? parserDelegate.mediaTypes.first { $0.value == "application/x-dtbncx+xml" }?.key
        let navHref = navID.flatMap { parserDelegate.manifest[$0] }
        let ncxHref = ncxID.flatMap { parserDelegate.manifest[$0] }

        return EPUBPackage(spineHrefs: spineHrefs, coverHref: coverHref, navHref: navHref, ncxHref: ncxHref)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "meta":
            if attributeDict["name"] == "cover" {
                coverID = attributeDict["content"]
            }
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                let pathWithoutAnchor = href.components(separatedBy: "#")[0]
                manifest[id] = pathWithoutAnchor.removingPercentEncoding ?? pathWithoutAnchor
                properties[id] = attributeDict["properties"]
                mediaTypes[id] = attributeDict["media-type"]
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spineIDs.append(idref)
            }
        case "spine":
            tocID = attributeDict["toc"]
        default:
            break
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    func firstMatch(for pattern: String) -> String? {
        matches(for: pattern).first
    }

    func matches(for pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, options: [], range: range).compactMap { result in
            let captureRange = result.numberOfRanges > 1 ? result.range(at: 1) : result.range
            guard let range = Range(captureRange, in: self) else { return nil }
            return String(self[range])
        }
    }

    func fullMatches(for pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, options: [], range: range).compactMap { result in
            guard let range = Range(result.range, in: self) else { return nil }
            return String(self[range])
        }
    }

    var decodedHTMLText: String {
        replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct BookcaseSeed {
    let name: String
    let icon: String
    let accentHex: String
    let shelves: [String]

    static let required: [BookcaseSeed] = [
        BookcaseSeed(
            name: "หมวดหมู่ภาษา",
            icon: "character.book.closed.fill",
            accentHex: "#2A9D8F",
            shelves: ["ไทย", "อังกฤษ", "จีน", "ญี่ปุ่น", "อิตาลี", "เยอรมัน", "ฝรั่งเศส"]
        ),
        BookcaseSeed(
            name: "หมวดหมู่วิทยาศาสตร์",
            icon: "atom",
            accentHex: "#577590",
            shelves: ["ฟิสิกส์", "เคมี", "ชีวะ"]
        ),
        BookcaseSeed(
            name: "หมวดหมู่บริหารธุรกิจ",
            icon: "chart.bar.doc.horizontal.fill",
            accentHex: "#C77D3B",
            shelves: ["บัญชี", "การเงิน", "การตลาด", "เศรษฐศาสตร์"]
        ),
        BookcaseSeed(
            name: "หมวดหมู่วิศวกรรม",
            icon: "gearshape.2.fill",
            accentHex: "#8E6BBE",
            shelves: ["เครื่องกล", "ไฟฟ้าอิเล็กทรอนิกส์", "วิศวกรรมเคมี", "วิศวกรรมพันธุกรรม"]
        ),
        BookcaseSeed(
            name: "หมวดหมู่คอมพิวเตอร์และไอที",
            icon: "desktopcomputer",
            accentHex: "#3B7A9E",
            shelves: ["พื้นฐานคอมพิวเตอร์", "โปรแกรมมิ่ง", "ปัญญาประดิษฐ์", "ความปลอดภัยไซเบอร์", "ฐานข้อมูล", "เครือข่าย"]
        ),
        BookcaseSeed(
            name: "หมวดหมู่วรรณกรรม",
            icon: "text.book.closed.fill",
            accentHex: "#B85C5C",
            shelves: ["นิยาย", "เรื่องสั้น", "บทกวี", "วรรณคดี", "การเขียน"]
        ),
        BookcaseSeed(
            name: "หมวดหมู่สังคมศาสตร์",
            icon: "person.3.fill",
            accentHex: "#6A7D3F",
            shelves: ["การเมือง", "กฎหมาย", "การศึกษา", "วัฒนธรรม", "จิตวิทยา"]
        ),
        BookcaseSeed(
            name: "หมวดหมู่ศิลปะและสื่อ",
            icon: "paintpalette.fill",
            accentHex: "#D67A3C",
            shelves: ["ศิลปะ", "ดนตรี", "ภาพยนตร์", "การออกแบบ", "การถ่ายภาพ"]
        ),
        BookcaseSeed(
            name: "หมวดหมู่สุขภาพและการแพทย์",
            icon: "heart.text.square.fill",
            accentHex: "#4F9D69",
            shelves: ["สุขภาพ", "แพทยศาสตร์", "โภชนาการ", "ออกกำลังกาย", "จิตใจ"]
        ),
        BookcaseSeed(
            name: "หมวดหมู่ประวัติศาสตร์และภูมิศาสตร์",
            icon: "map.fill",
            accentHex: "#8A6F3F",
            shelves: ["ประวัติศาสตร์", "ภูมิศาสตร์", "ชีวประวัติ", "การเดินทาง", "แผนที่"]
        )
    ]
}

@Model
class Bookcase {
    var name: String
    var icon: String
    var accentHex: String = "#577590"
    @Relationship(deleteRule: .cascade, inverse: \Shelf.bookcase) var shelves: [Shelf] = []

    init(name: String, icon: String, accentHex: String = "#577590", shelves: [String]) {
        self.name = name
        self.icon = icon
        self.accentHex = accentHex
        self.shelves = shelves.map { Shelf(name: $0) }
    }

    var accentColor: Color {
        Color(hex: accentHex) ?? .blue
    }
}

@Model
class Shelf {
    var name: String
    var bookcase: Bookcase?
    @Relationship(deleteRule: .cascade, inverse: \Book.shelf) var books: [Book] = []
    init(name: String) { self.name = name }

    var importedBooks: [Book] {
        books.filter { $0.isReadableImport }
    }
}

@Model
class Book {
    var title: String
    var author: String
    var colorHex: String
    var filePath: String?
    var fileFormat: String = ""
    var coverImagePath: String?
    var lastReadPage: Int = 0
    var shelf: Shelf?

    init(title: String, author: String, colorHex: String, filePath: String? = nil, fileFormat: String = "", coverImagePath: String? = nil, lastReadPage: Int = 0) {
        self.title = title
        self.author = author
        self.colorHex = colorHex
        self.filePath = filePath
        self.fileFormat = fileFormat
        self.coverImagePath = coverImagePath
        self.lastReadPage = lastReadPage
    }

    var fileURL: URL? {
        guard let filePath, !filePath.isEmpty else { return nil }
        return URL(fileURLWithPath: filePath)
    }

    var isReadableImport: Bool {
        guard let fileURL, EBookFormat(rawValue: fileFormat) != nil else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    var coverImage: NSImage? {
        guard let coverImagePath, !coverImagePath.isEmpty else { return nil }
        return NSImage(contentsOfFile: coverImagePath)
    }

    var displayFormat: String {
        EBookFormat(rawValue: fileFormat)?.displayName ?? "FILE"
    }

    var formatIconName: String {
        switch EBookFormat(rawValue: fileFormat) {
        case .pdf:
            return "doc.richtext"
        case .cbz:
            return "photo.on.rectangle"
        case .epub:
            return "text.book.closed"
        case nil:
            return "doc"
        }
    }
}

extension Color {
    init?(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}

private extension NSImage {
    func jpegData(compressionFactor: CGFloat) -> Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
    }
}

private struct ImmediatePlainButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .onTapGesture {
                configuration.trigger()
            }
            .acceptsFirstMouse()
    }
}

private struct FirstMouseAcceptingView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        FirstMouseView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FirstMouseView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }
}

private extension View {
    func acceptsFirstMouse() -> some View {
        background(FirstMouseAcceptingView())
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Bookcase.self, Shelf.self, Book.self], inMemory: true)
}
