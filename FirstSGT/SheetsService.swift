import Foundation

actor SheetsService {
    static let shared = SheetsService()
    
    let spreadsheetId = "1ugnpvlLtHRJ2qsiS4VxWjdtU8wSJEXKin1LBQdY_C2I"
    let baseURL = "https://sheets.googleapis.com/v4/spreadsheets"
    
    // MARK: - Existing Methods
    
    func read(range: String) async throws -> [[String]] {
        let token = try await GoogleAuthService.shared.getAccessToken()
        
        // Create a character set that does NOT include "/" so slashes get encoded as %2F
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove("/")
        
        guard let encodedRange = range.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            print("❌ [read] Failed to encode range: \(range)")
            throw SheetsError.noValidationFound
        }
        
        let urlString = "\(baseURL)/\(spreadsheetId)/values/\(encodedRange)"
        guard let url = URL(string: urlString) else {
            print("❌ [read] Failed to create URL from: \(urlString)")
            throw SheetsError.noValidationFound
        }
        
        print("📖 [read] URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            print("📖 [read] HTTP Status: \(httpResponse.statusCode)")
        }
        
        if let rawString = String(data: data, encoding: .utf8) {
            print("📖 [read] Raw response: \(rawString.prefix(500))...")
        }
        
        do {
            let decoded = try JSONDecoder().decode(SheetResponse.self, from: data)
            print("✅ [read] Decoded \(decoded.values?.count ?? 0) rows")
            return decoded.values ?? []
        } catch {
            print("❌ [read] Decode error: \(error)")
            throw error
        }
    }
    
    func write(range: String, values: [[String]]) async throws {
        let token = try await GoogleAuthService.shared.getAccessToken()
        
        // Encode slashes in the range
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove("/")
        
        guard let encodedRange = range.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            throw SheetsError.noValidationFound
        }
        
        let urlString = "\(baseURL)/\(spreadsheetId)/values/\(encodedRange)?valueInputOption=RAW"
        guard let url = URL(string: urlString) else {
            throw SheetsError.noValidationFound
        }
        
        print("✏️ [write] URL: \(url.absoluteString)")
        
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
        
        if let httpResponse = response as? HTTPURLResponse {
            print("✏️ [write] HTTP Status: \(httpResponse.statusCode)")
            if httpResponse.statusCode >= 400 {
                if let rawString = String(data: data, encoding: .utf8) {
                    print("❌ [write] Error response: \(rawString)")
                }
                throw SheetsError.noValidationFound
            }
        }
        
        print("✅ [write] Success")
    }
    
    // MARK: - New Methods
    
    /// Fetch all sheet tab names from the spreadsheet
    func fetchSheetNames() async throws -> [String] {
        let token = try await GoogleAuthService.shared.getAccessToken()
        let url = URL(string: "\(baseURL)/\(spreadsheetId)")!
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        // DEBUG: Print raw response
        if let rawString = String(data: data, encoding: .utf8) {
            print("🔵 [fetchSheetNames] Raw response:")
            print(rawString)
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        print("🔵 [fetchSheetNames] JSON keys: \(json?.keys.joined(separator: ", ") ?? "none")")
        
        guard let sheets = json?["sheets"] as? [[String: Any]] else {
            print("❌ [fetchSheetNames] Failed to parse 'sheets' array")
            throw SheetsError.noValidationFound
        }
        
        let sheetNames = sheets.compactMap { sheet in
            (sheet["properties"] as? [String: Any])?["title"] as? String
        }
        
        print("✅ [fetchSheetNames] Found sheets: \(sheetNames)")
        
        return sheetNames
    }

    /// Fetch rows 1-3 of a given sheet to build the column map
    func fetchHeaderRows(sheet: String) async throws -> [[String]] {
        print("🟡 [fetchHeaderRows] Fetching headers for sheet: '\(sheet)'")
        
        let range = "\(sheet)!A1:ZZ3"
        print("🟡 [fetchHeaderRows] Full range: '\(range)'")
        
        do {
            let result = try await read(range: range)
            print("✅ [fetchHeaderRows] Got \(result.count) rows")
            for (idx, row) in result.enumerated() {
                print("   Row \(idx + 1): \(row.count) columns - \(row.prefix(10))")
            }
            return result
        } catch {
            print("❌ [fetchHeaderRows] Error: \(error)")
            throw error
        }
    }
    /// Fetch all names (column A, rows 4+) and values for a given column, stopping at "Present"
    func fetchNamesAndValues(sheet: String, columnIndex: Int) async throws -> [(name: String, value: String, row: Int)] {
        print("🟢 [fetchNamesAndValues] Sheet: '\(sheet)', Column: \(columnIndex)")
    
        let colLetter = columnLetter(for: columnIndex)
        print("🟢 [fetchNamesAndValues] Column letter: \(colLetter)")
        
        let range = "\(sheet)!A4:\(colLetter)500"
        print("🟢 [fetchNamesAndValues] Range: '\(range)'")
        
        do {
            let rows = try await read(range: range)
            print("✅ [fetchNamesAndValues] Got \(rows.count) rows")
            
            var results: [(name: String, value: String, row: Int)] = []
            
            for (index, row) in rows.enumerated() {
                guard !row.isEmpty, !row[0].isEmpty else {
                    print("   Row \(index + 4): Empty, skipping")
                    continue
                }
                
                let name = row[0]
                
                // Stop scanning when we hit "Present"
                if name.lowercased().contains("present") {
                    print("   Row \(index + 4): Found 'Present', stopping scan")
                    break
                }
                
                let value: String
                if columnIndex < row.count {
                    value = row[columnIndex]
                } else {
                    value = "TBD"
                }
                
                let actualRow = index + 4
                results.append((name: name, value: value, row: actualRow))
                
                print("   Row \(actualRow): '\(name)' = '\(value)'")
            }
            
            print("✅ [fetchNamesAndValues] Returning \(results.count) soldiers")
            return results
            
        } catch {
            print("❌ [fetchNamesAndValues] Error: \(error)")
            throw error
        }
    }
    
    /// Convert 0-based column index to letter (0=A, 1=B, ..., 26=AA, etc.)
    func columnLetter(for index: Int) -> String {
        var result = ""
        var idx = index
        
        while idx >= 0 {
            result = String(Character(UnicodeScalar(65 + (idx % 26))!)) + result
            idx = idx / 26 - 1
        }
        
        return result
    }
    
    // MARK: - Types
    
    struct SheetResponse: Codable {
        let values: [[String]]?
    }
    
    enum SheetsError: Error, LocalizedError {
        case parseError
        case writeFailed
        case noValidationFound
        
        var errorDescription: String? {
            switch self {
            case .parseError: return "Failed to parse sheet data"
            case .writeFailed: return "Failed to write to sheet"
            case .noValidationFound: return "No validation found"
            }
        }
    }
    /// Fetch names, values, AND background colors for a given column
    func fetchNamesValuesAndColors(sheet: String, columnIndex: Int) async throws -> [(name: String, value: String, row: Int, bgColor: CellColor)] {
        let token = try await GoogleAuthService.shared.getAccessToken()
        
        // Encode sheet name
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove("/")
        guard let encodedSheet = sheet.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            throw SheetsError.noValidationFound
        }
        
        let colLetter = columnLetter(for: columnIndex)
        let range = "\(encodedSheet)!A4:\(colLetter)500"
        
        let urlString = "\(baseURL)/\(spreadsheetId)?ranges=\(range)&includeGridData=true"
        guard let url = URL(string: urlString) else {
            throw SheetsError.noValidationFound
        }
        
        print("🎨 [fetchColors] URL: \(url.absoluteString)")
        
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
            print("❌ [fetchColors] Failed to parse grid data")
            throw SheetsError.noValidationFound
        }
        
        var results: [(name: String, value: String, row: Int, bgColor: CellColor)] = []
        
        for (index, row) in rowData.enumerated() {
            guard let values = row["values"] as? [[String: Any]],
                !values.isEmpty
            else { continue }
            
            // Column A = name
            let nameCell = values[0]
            guard let name = extractCellValue(from: nameCell), !name.isEmpty else { continue }
            
            // Stop at "Present"
            if name.lowercased().contains("present") {
                break
            }
            
            // Get the value cell (at columnIndex)
            let valueCell = columnIndex < values.count ? values[columnIndex] : [:]
            let value = extractCellValue(from: valueCell) ?? "TBD"
            
            // Get background color from the value cell
            let bgColor = extractBackgroundColor(from: valueCell)
            
            let actualRow = index + 4
            
            print("   Row \(actualRow): '\(name)' = '\(value)' bg=\(bgColor)")
            
            results.append((name: name, value: value, row: actualRow, bgColor: bgColor))
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

    private func extractBackgroundColor(from cell: [String: Any]) -> CellColor {
        guard let effectiveFormat = cell["effectiveFormat"] as? [String: Any],
            let bgColor = effectiveFormat["backgroundColor"] as? [String: Any]
        else {
            return .gray
        }
        
        let red = bgColor["red"] as? Double ?? 1.0
        let green = bgColor["green"] as? Double ?? 1.0
        let blue = bgColor["blue"] as? Double ?? 1.0
        
        print("      RGB: \(red), \(green), \(blue)")
        
        // Dark gray (skip these people)
        if red < 0.4 && green < 0.4 && blue < 0.4 {
            return .darkGray
        }
        
        // Yellow-ish
        if red > 0.9 && green > 0.8 && blue < 0.5 {
            return .yellow
        }
        
        // Purple-ish
        if red > 0.6 && green < 0.5 && blue > 0.6 {
            return .purple
        }
        
        // Blue-ish
        if blue > 0.7 && red < 0.5 && green < 0.8 {
            return .blue
        }
        
        // Light gray or white = gray
        return .gray
    }

    enum CellColor {
        case gray
        case yellow
        case purple
        case blue
        case darkGray // skip these
    }
}