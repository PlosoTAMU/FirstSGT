import Foundation

actor SheetsService {
    static let shared = SheetsService()
    
    let spreadsheetId = "1ugnpvlLtHRJ2qsiS4VxWjdtU8wSJEXKin1LBQdY_C2I"
    let baseURL = "https://sheets.googleapis.com/v4/spreadsheets"
    
    // MARK: - Existing Methods
    
    func read(range: String) async throws -> [[String]] {
        let token = try await GoogleAuthService.shared.getAccessToken()
        
        // Properly encode the range (this will encode slashes as %2F)
        guard let encodedRange = range.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else {
            throw SheetsError.parseError
        }
        
        let urlString = "\(baseURL)/\(spreadsheetId)/values/\(encodedRange)"
        guard let url = URL(string: urlString) else {
            print("❌ [read] Failed to create URL from: \(urlString)")
            throw SheetsError.parseError
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
        let encodedRange = range.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? range
        let url = URL(string: "\(baseURL)/\(spreadsheetId)/values/\(encodedRange)?valueInputOption=RAW")!
        
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
        let (_, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw SheetsError.writeFailed
        }
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
}