//
//  CodexShelfApp.swift
//  CodexShelf
//
//  Created by Paitoon Wannanad on 13/6/2569 BE.
//

import SwiftUI
import SwiftData

@main
struct CodexShelfApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Bookcase.self, Shelf.self, Book.self])
    }
}
