//
//  Item.swift
//  CodexShelf
//
//  Created by Paitoon Wannanad on 13/6/2569 BE.
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
