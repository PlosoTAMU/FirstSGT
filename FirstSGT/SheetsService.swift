import Foundation

actor SheetsService {
    static let shared = SheetsService()
    
    let spreadsheetId = "1ugnpvlLtHRJ2qsiS4VxWjdtU8wSJEXKin1LBQdY_C2I"
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
    
    // MARK: - Copy Sheet (Create New Week)
    
    func copySheet(sourceSheetId: Int, newTitle: String, insertAtIndex: Int) async throws {
        let token = try await GoogleAuthService.shared.getAccessToken()
        let url = URL(string: "\(baseURL)/\(spreadsheetId):batchUpdate")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Step 1: Duplicate the sheet
        let duplicateRequest: [String: Any] = [
            "requests": [
                [
                    "duplicateSheet": [
                        "sourceSheetId": sourceSheetId,
                        "insertSheetIndex": insertAtIndex,
                        "newSheetName": newTitle
                    ]
                ]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: duplicateRequest)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            print("📋 [copySheet] HTTP Status: \(httpResponse.statusCode)")
            if httpResponse.statusCode >= 400 {
                if let rawString = String(data: data, encoding: .utf8) {
                    print("❌ [copySheet] Error: \(rawString)")
                }
                throw SheetsError.writeFailed
            }
        }
        
        print("✅ [copySheet] Created new sheet: \(newTitle)")
    }
    
    // MARK: - Fetch Header Rows
    
    func fetchHeaderRows(sheet: String) async throws -> [[String]] {
        let range = "\(sheet)!A1:ZZ3"
        return try await read(range: range)
    }
    
    // MARK: - Fetch Names, Values, and Colors
    
    func fetchNamesValuesAndColors(sheet: String, columnIndex: Int) async throws -> [(name: String, value: String, row: Int, groupColor: GroupColor)] {
        let token = try await GoogleAuthService.shared.getAccessToken()
        
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove("/")
        guard let encodedSheet = sheet.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            throw SheetsError.parseError
        }
        
        let colLetter = columnLetter(for: columnIndex)
        let range = "\(encodedSheet)!A4:\(colLetter)500"
        
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
        
        var results: [(name: String, value: String, row: Int, groupColor: GroupColor)] = []
        
        for (index, row) in rowData.enumerated() {
            guard let values = row["values"] as? [[String: Any]],
                  !values.isEmpty
            else { continue }
            
            let nameCell = values[0]
            guard let name = extractCellValue(from: nameCell), !name.isEmpty else { continue }
            
            if name.lowercased().contains("present") {
                break
            }
            
            let groupColor = extractGroupColor(from: nameCell)
            
            if groupColor == .hidden {
                continue
            }
            
            let valueCell = columnIndex < values.count ? values[columnIndex] : [:]
            let value = extractCellValue(from: valueCell) ?? "TBD"
            
            let actualRow = index + 4
            
            print("   Row \(actualRow): '\(name)' = '\(value)' group=\(groupColor)")
            
            results.append((name: name, value: value, row: actualRow, groupColor: groupColor))
        }
        
        return results
    }
    
    private func extractCellValue(from cell: [String: Any]) -> String? {
        if let formatted = cell["formattedValue"] as? String {
            return formatted
        }
        if let effectiveValue = cell["effectiveValue"] as? [String: Any] {
            if let str = effectiveValue["stringValue"] as? String { return str }
            if let num = effectiveValue["numberValue"] as? Double { return String(num) }
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
        
        if red < 0.5 && green < 0.5 && blue < 0.5 {
            return .hidden
        }
        if red > 0.9 && green > 0.8 && blue < 0.6 {
            return .yellowGroup
        }
        if blue > 0.7 && red < 0.7 {
            return .blueGroup
        }
        if green > 0.7 && red < 0.7 && blue < 0.7 {
            return .greenGroup
        }
        if red > 0.6 && blue > 0.6 && green < 0.6 {
            return .purpleGroup
        }
        if red > 0.8 && green > 0.8 && blue > 0.8 && red < 0.95 {
            return .grayGroup
        }
        
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
    func fetchSheetNamesWithIds() async throws -> [(name: String, sheetId: Int)] {
        let token = try await GoogleAuthService.shared.getAccessToken()
        let url = URL(string: "\(baseURL)/\(spreadsheetId)")!
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let sheets = json?["sheets"] as? [[String: Any]] else {
            throw SheetsError.noValidationFound
        }
        
        return sheets.compactMap { sheet in
            guard let props = sheet["properties"] as? [String: Any],
                let title = props["title"] as? String,
                let sheetId = props["sheetId"] as? Int
            else { return nil }
            return (name: title, sheetId: sheetId)
        }
    }

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
            throw SheetsError.noValidationFound
        }
    }
}