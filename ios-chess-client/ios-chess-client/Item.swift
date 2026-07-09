//
//  Item.swift
//  ios-chess-client
//
//  Created by Y K on 09.07.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
