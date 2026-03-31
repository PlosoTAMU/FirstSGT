import Foundation

actor SheetsService {
    static let shared = SheetsService()
    
    let spreadsheetId = "1ugnpvlLtHRJ2qsiS4VxWjdtU8wSJEXKin1LBQdY_C2I"
    let baseURL = "https://sheets.googleapis.com/v4/spreadsheets"
    
    // MARK: - Existing Methods
    
    func read(range: String) async throws -> [[String]] {
        let token = try await GoogleAuthService.shared.getAccessToken()
        let encodedRange = range.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? range
        let url = URL(string: "\(baseURL)/\(spreadsheetId)/values/\(encodedRange)")!
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(SheetResponse.self, from: data)
        return response.values ?? []
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
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let sheets = json?["sheets"] as? [[String: Any]] else {
            throw SheetsError.parseError
        }
        
        return sheets.compactMap { sheet in
            (sheet["properties"] as? [String: Any])?["title"] as? String
        }
    }
    
    /// Fetch rows 1-3 of a given sheet to build the column map
    func fetchHeaderRows(sheet: String) async throws -> [[String]] {
        let range = "\(sheet)!A1:ZZ3"
        return try await read(range: range)
    }
    
    /// Fetch all names (column A, rows 4+) and their values for a given column
    func fetchNamesAndValues(sheet: String, columnIndex: Int) async throws -> [(name: String, value: String, row: Int)] {
        let colLetter = columnLetter(for: columnIndex)
        let range = "\(sheet)!A4:\(colLetter)1000"
        let rows = try await read(range: range)
        
        var results: [(name: String, value: String, row: Int)] = []
        
        for (index, row) in rows.enumerated() {
            guard !row.isEmpty, !row[0].isEmpty else { continue }
            
            let name = row[0]
            let value: String
            if columnIndex < row.count {
                value = row[columnIndex]
            } else {
                value = "TBD"
            }
            
            let actualRow = index + 4 // Row 4 is the first name row
            results.append((name: name, value: value, row: actualRow))
        }
        
        return results
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