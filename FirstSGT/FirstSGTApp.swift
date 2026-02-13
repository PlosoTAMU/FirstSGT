//
//  FirstSGTApp.swift
//  FirstSGT
//
//  Created by TP on 2/13/26.
//

import SwiftUI
import CoreData

@main
struct FirstSGTApp: App {
    
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext,
                              persistenceController.container.viewContext)
        }
    }
}
