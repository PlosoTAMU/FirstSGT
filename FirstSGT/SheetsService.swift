import Foundation

actor SheetsService {
    static let shared = SheetsService()
    
    // old id: let spreadsheetId = "1ugnpvlLtHRJ2qsiS4VxWjdtU8wSJEXKin1LBQdY_C2I"
    let spreadSheetId = "1Dypmism-aeFhn-gpgnvlewHoIN0W-ajUbtqzHVW7cTE"
    let baseURL = "https://sheets.googleapis.com/v4/spreadsheets"
    
    // MARK: - Read
    
    func read(range: String) async throws -> [[String]] {
        let token = try await GoogleAuthService.shared.getAccessToken()
        
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove("/")
        
        guard let encodedRange = range.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            throw SheetsError.parseError
        }
        
        let urlString = "\(baseURL)/\(spreadsheetId)/values/\(encodedRange)"
        guard let url = URL(string: urlString) else {
            throw SheetsError.parseError
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(SheetResponse.self, from: data)
        return decoded.values ?? []
    }
    
    // MARK: - Write
    
    func write(range: String, values: [[String]]) async throws {
        let token = try await GoogleAuthService.shared.getAccessToken()
        
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove("/")
        
        guard let encodedRange = range.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            throw SheetsError.parseError
        }
        
        let urlString = "\(baseURL)/\(spreadsheetId)/values/\(encodedRange)?valueInputOption=RAW"
        guard let url = URL(string: urlString) else {
            throw SheetsError.parseError
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "range": range,
            "majorDimension": "ROWS",
            "values": values
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            if let rawString = String(data: data, encoding: .utf8) {
                print("❌ [write] Error response: \(rawString)")
            }
            throw SheetsError.writeFailed
        }
    }
    
    // MARK: - Fetch Sheet Names with IDs
    
    func fetchSheetNamesWithIds() async throws -> [(name: String, sheetId: Int)] {
        let token = try await GoogleAuthService.shared.getAccessToken()
        let url = URL(string: "\(baseURL)/\(spreadsheetId)")!
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let sheets = json?["sheets"] as? [[String: Any]] else {
            throw SheetsError.parseError
        }
        
        return sheets.compactMap { sheet in
            guard let props = sheet["properties"] as? [String: Any],
                  let title = props["title"] as? String,
                  let sheetId = props["sheetId"] as? Int
            else { return nil }
            return (name: title, sheetId: sheetId)
        }
    }
    
    func fetchSheetNames() async throws -> [String] {
        let sheetsWithIds = try await fetchSheetNamesWithIds()
        return sheetsWithIds.map { $0.name }
    }
    
    // MARK: - Copy Sheet
    
    func copySheet(sourceSheetId: Int, newTitle: String, insertAtIndex: Int) async throws {
        let token = try await GoogleAuthService.shared.getAccessToken()
        let url = URL(string: "\(baseURL)/\(spreadsheetId):batchUpdate")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "requests": [[
                "duplicateSheet": [
                    "sourceSheetId": sourceSheetId,
                    "insertSheetIndex": insertAtIndex,
                    "newSheetName": newTitle
                ]
            ]]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw SheetsError.writeFailed
        }
    }
    
    // MARK: - Fetch Header Rows
    
    func fetchHeaderRows(sheet: String) async throws -> [[String]] {
        let range = "\(sheet)!A1:ZZ3"
        return try await read(range: range)
    }
    
    // MARK: - Fetch Names, Values, Colors, AND Statistics
    
    func fetchNamesValuesColorsAndStats(sheet: String, columnIndex: Int) async throws -> (
        cadets: [(name: String, value: String, row: Int, groupColor: GroupColor)],
        stats: [(label: String, value: String)]
    ) {
        let token = try await GoogleAuthService.shared.getAccessToken()
        
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove("/")
        guard let encodedSheet = sheet.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            throw SheetsError.parseError
        }
        
        let colLetter = columnLetter(for: columnIndex)
        let range = "\(encodedSheet)!A4:\(colLetter)600"
        
        let urlString = "\(baseURL)/\(spreadsheetId)?ranges=\(range)&includeGridData=true"
        guard let url = URL(string: urlString) else {
            throw SheetsError.parseError
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let sheets = json?["sheets"] as? [[String: Any]],
              let firstSheet = sheets.first,
              let dataArray = firstSheet["data"] as? [[String: Any]],
              let gridData = dataArray.first,
              let rowData = gridData["rowData"] as? [[String: Any]]
        else {
            throw SheetsError.parseError
        }
        
        var cadets: [(name: String, value: String, row: Int, groupColor: GroupColor)] = []
        var stats: [(label: String, value: String)] = []
        var foundPresent = false
        var foundTotalOutfit = false
        
        // Labels that indicate we've hit statistics section
        let statLabels = ["present", "ua", "excused", "total absent", "predicted present", 
                          "duncan reported", "total outfit", "total zip"]
        
        for (index, row) in rowData.enumerated() {
            guard let values = row["values"] as? [[String: Any]],
                  !values.isEmpty
            else { continue }
            
            let nameCell = values[0]
            guard let label = extractCellValue(from: nameCell), !label.isEmpty else { continue }
            
            let labelLower = label.lowercased()
            
            // Check if we've hit "present" - start of stats section
            if labelLower == "present" {
                foundPresent = true
            }
            
            // If we're in the stats section
            if foundPresent {
                // Check if we've hit "total outfit" - switch to column B
                if labelLower.contains("total outfit") {
                    foundTotalOutfit = true
                }
                
                // Get the value from the appropriate column
                let statValue: String
                if foundTotalOutfit {
                    // Column B (index 1)
                    if values.count > 1 {
                        statValue = extractCellValue(from: values[1]) ?? "0"
                    } else {
                        statValue = "0"
                    }
                } else {
                    // Slot column
                    if columnIndex < values.count {
                        statValue = extractCellValue(from: values[columnIndex]) ?? "0"
                    } else {
                        statValue = "0"
                    }
                }
                
                stats.append((label: label, value: statValue))
                continue
            }
            
            // Regular cadet row (before "present")
            let groupColor = extractGroupColor(from: nameCell)
            
            if groupColor == .hidden {
                continue
            }
            
            let valueCell = columnIndex < values.count ? values[columnIndex] : [:]
            let value = extractCellValue(from: valueCell) ?? "TBD"
            
            let actualRow = index + 4
            
            cadets.append((name: label, value: value, row: actualRow, groupColor: groupColor))
        }
        
        return (cadets: cadets, stats: stats)
    }
    
    private func extractCellValue(from cell: [String: Any]) -> String? {
        if let formatted = cell["formattedValue"] as? String {
            return formatted
        }
        if let effectiveValue = cell["effectiveValue"] as? [String: Any] {
            if let str = effectiveValue["stringValue"] as? String { return str }
            if let num = effectiveValue["numberValue"] as? Double { return String(Int(num)) }
        }
        return nil
    }
    
    private func extractGroupColor(from cell: [String: Any]) -> GroupColor {
        guard let effectiveFormat = cell["effectiveFormat"] as? [String: Any],
            let bgColor = effectiveFormat["backgroundColor"] as? [String: Any]
        else {
            return .white
        }
        
        let red = bgColor["red"] as? Double ?? 1.0
        let green = bgColor["green"] as? Double ?? 1.0
        let blue = bgColor["blue"] as? Double ?? 1.0
        
        // Debug: Print RGB values to console
        print("🎨 RGB: r=\(String(format: "%.2f", red)), g=\(String(format: "%.2f", green)), b=\(String(format: "%.2f", blue))")
        
        // Dark gray = hidden (skip these people entirely)
        if red < 0.5 && green < 0.5 && blue < 0.5 {
            return .hidden
        }
        
        // Pure white or near-white (default/no background)
        if red > 0.99 && green > 0.99 && blue > 0.99 {
            return .white
        }
        
        // Light Yellow 2 - typically RGB(255, 242, 204) = (1.0, 0.95, 0.8)
        if red > 0.95 && green > 0.90 && blue > 0.75 && blue < 0.85 {
            return .yellowGroup
        }
        
        // Light Cornflower Blue 2 - typically RGB(207, 226, 243) = (0.81, 0.89, 0.95)
        if blue > 0.90 && green > 0.85 && red > 0.75 && red < 0.85 {
            return .blueGroup
        }
        
        // Light Red 3 - typically RGB(244, 204, 204) = (0.96, 0.8, 0.8)
        if red > 0.90 && green > 0.75 && green < 0.85 && blue > 0.75 && blue < 0.85 {
            return .purpleGroup  // Using purpleGroup for red background
        }
        
        // Light Blue 3 - typically RGB(217, 234, 211) = (0.85, 0.92, 0.83)
        if green > 0.88 && red > 0.80 && red < 0.88 && blue > 0.78 && blue < 0.88 {
            return .greenGroup
        }
        
        // Light gray background
        if red > 0.8 && green > 0.8 && blue > 0.8 && red < 0.95 {
            return .grayGroup
        }
        
        // Fallback
        print("⚠️ Unrecognized color - defaulting to white")
        return .white
    }
    
    func columnLetter(for index: Int) -> String {
        var result = ""
        var idx = index
        
        repeat {
            result = String(Character(UnicodeScalar(65 + (idx % 26))!)) + result
            idx = idx / 26 - 1
        } while idx >= 0
        
        return result
    }
    
    // MARK: - Types
    
    struct SheetResponse: Codable {
        let values: [[String]]?
    }
    
    enum SheetsError: Error {
        case parseError
        case writeFailed
    }
    
    enum GroupColor: Int, Comparable {
        case hidden = -1
        case white = 0
        case grayGroup = 1
        case blueGroup = 2
        case greenGroup = 3
        case yellowGroup = 4
        case purpleGroup = 5
        
        static func < (lhs: GroupColor, rhs: GroupColor) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}