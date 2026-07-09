//
//  ios_chess_clientApp.swift
//  ios-chess-client
//
//  Created by Y K on 09.07.26.
//

import SwiftUI
import SwiftData

@main
struct ios_chess_clientApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SavedGame.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(sharedModelContainer)
    }
}
