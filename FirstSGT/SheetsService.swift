import Foundation

actor SheetsService {
    static let shared = SheetsService()
    
    let spreadsheetId = "1ugnpvlLtHRJ2qsiS4VxWjdtU8wSJEXKin1LBQdY_C2I" // from your sheet's URL
    let baseURL = "https://sheets.googleapis.com/v4/spreadsheets"
        // MARK: - Read
    
    func read(range: String) async throws -> [[String]] {
        let token = try await GoogleAuthService.shared.getAccessToken()
        let url = URL(string: "\(baseURL)/\(spreadsheetId)/values/\(range)")!
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(SheetResponse.self, from: data)
        return response.values ?? []
    }
    
    // MARK: - Write
    
    func write(range: String, values: [[String]]) async throws {
        let token = try await GoogleAuthService.shared.getAccessToken()
        let url = URL(string: "\(baseURL)/\(spreadsheetId)/values/\(range)?valueInputOption=RAW")!
        
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
        try await URLSession.shared.data(for: request)
    }
    
    // MARK: - Append
    
    func append(range: String, values: [[String]]) async throws {
        let token = try await GoogleAuthService.shared.getAccessToken()
        let url = URL(string: "\(baseURL)/\(spreadsheetId)/values/\(range):append?valueInputOption=RAW")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "range": range,
            "majorDimension": "ROWS",
            "values": values
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await URLSession.shared.data(for: request)
    }
    
    struct SheetResponse: Codable {
        let values: [[String]]?
    }
    func fetchDropdownOptions(cell: String) async throws -> [String] {
        let token = try await GoogleAuthService.shared.getAccessToken()
        let url = URL(string: "\(baseURL)/\(spreadsheetId)?ranges=\(cell)&includeGridData=true")!
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        // DEBUG - print the raw response so we can see the structure
        if let rawString = String(data: data, encoding: .utf8) {
            print("📋 SHEETS RESPONSE: \(rawString)")
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard
            let sheets = json?["sheets"] as? [[String: Any]],
            let firstSheet = sheets.first,
            let gridData = firstSheet["data"] as? [[String: Any]],
            let firstGrid = gridData.first,
            let rowData = firstGrid["rowData"] as? [[String: Any]],
            let firstRow = rowData.first,
            let values = firstRow["values"] as? [[String: Any]],
            let firstCell = values.first,
            let dataValidation = firstCell["dataValidation"] as? [String: Any],
            let condition = dataValidation["condition"] as? [String: Any],
            let conditionValues = condition["values"] as? [[String: Any]]
        else {
            throw SheetsError.noValidationFound
        }
        
        return conditionValues.compactMap { $0["userEnteredValue"] as? String }
    }

    enum SheetsError: Error {
        case noValidationFound
    }
}
