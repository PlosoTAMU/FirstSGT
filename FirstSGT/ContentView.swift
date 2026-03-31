import SwiftUI

// MARK: - Data Models

struct Soldier: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let value: String
    let row: Int
    let color: SoldierColor
    
    static func == (lhs: Soldier, rhs: Soldier) -> Bool {
        lhs.row == rhs.row && lhs.name == rhs.name
    }
}

enum SoldierColor: Int, Comparable {
    case purple = 0  // ROTC
    case blue = 1    // E (something)
    case yellow = 2  // E (t-something)
    case gray = 3    // TBD or unknown
    
    static func < (lhs: SoldierColor, rhs: SoldierColor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var color: Color {
        switch self {
        case .purple: return .purple
        case .blue: return .blue
        case .yellow: return .yellow
        case .gray: return .gray
        }
    }
    
    static func from(value: String) -> SoldierColor? {
        // P = hidden (return nil)
        if value == "P" { return nil }
        
        // ROTC = purple
        if value == "ROTC" { return .purple }
        
        // E (t-...) = yellow (check before blue)
        if value.hasPrefix("E (t-") { return .yellow }
        
        // E (...) = blue
        if value.hasPrefix("E (") { return .blue }
        
        // TBD or anything else = gray
        return .gray
    }
}

struct ColumnSlot: Identifiable, Hashable {
    let id = UUID()
    let day: String
    let slot: String
    let columnIndex: Int
}

// MARK: - Main View

struct ContentView: View {
    // Sheet selection
    @State private var allSheetNames: [String] = []
    @State private var selectedSheet: String = ""
    @State private var showSheetPicker = false
    
    // Slot selection
    @State private var allSlots: [ColumnSlot] = []
    @State private var todaySlots: [ColumnSlot] = []
    @State private var selectedSlot: ColumnSlot?
    @State private var showSlotPicker = false
    
    // Name list
    @State private var soldiers: [Soldier] = []
    
    // Input
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    
    // Status
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var toastMessage: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Content
            if isLoading {
                Spacer()
                ProgressView("Loading...")
                Spacer()
            } else if let error = errorMessage {
                Spacer()
                VStack(spacing: 16) {
                    Text("❌ \(error)")
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await loadData() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                Spacer()
            } else if selectedSlot == nil {
                Spacer()
                Text("No active time slot")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                nameListView
            }
            
            // Hidden input field
            hiddenInputField
            
            // Toast
            if let toast = toastMessage {
                Text(toast)
                    .font(.caption)
                    .padding(8)
                    .background(toast.contains("✅") ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .cornerRadius(8)
                    .padding(.bottom, 8)
            }
        }
        .task {
            await loadData()
        }
    }
    
    // MARK: - Header View
    
    private var headerView: some View {
        VStack(spacing: 8) {
            // Sheet selector
            Button(action: { showSheetPicker = true }) {
                HStack {
                    Text("Week: \(selectedSheet)")
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .foregroundColor(.primary)
            }
            .confirmationDialog("Select Week", isPresented: $showSheetPicker) {
                ForEach(allSheetNames, id: \.self) { name in
                    Button(name) {
                        selectedSheet = name
                        Task { await loadSlots() }
                    }
                }
            }
            
            // Slot selector
            if !todaySlots.isEmpty {
                Button(action: { showSlotPicker = true }) {
                    HStack {
                        Text("Slot: \(selectedSlot?.slot ?? "None")")
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
                .confirmationDialog("Select Slot", isPresented: $showSlotPicker) {
                    ForEach(todaySlots) { slot in
                        Button(slot.slot) {
                            selectedSlot = slot
                            Task { await loadSoldiers() }
                        }
                    }
                }
            }
        }
        .padding()
    }
    
    // MARK: - Name List View
    
    private var nameListView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(sortedSoldiers) { soldier in
                    soldierRow(soldier)
                }
            }
            .padding(.horizontal)
        }
    }
    
    private var sortedSoldiers: [Soldier] {
        soldiers.sorted { lhs, rhs in
            if lhs.color != rhs.color {
                return lhs.color < rhs.color
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
    
    private func soldierRow(_ soldier: Soldier) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(soldier.color.color)
                .frame(width: 12, height: 12)
            
            Text(soldier.name)
                .font(.body)
            
            Spacer()
            
            if soldier.color != .gray {
                Text(soldier.value)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
    
    // MARK: - Hidden Input Field
    
    private var hiddenInputField: some View {
        TextField("", text: $inputText)
            .focused($isInputFocused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .frame(height: 1)
            .opacity(0.01)
            .onChange(of: inputText) { newValue in
                handleInput(newValue)
            }
            .onAppear {
                isInputFocused = true
            }
    }
    
    // MARK: - Input Handling
    
    private func handleInput(_ text: String) {
        guard text.hasSuffix(" ") else { return }
        
        let tokens = text.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
        
        guard let lastToken = tokens.last else {
            inputText = ""
            return
        }
        
        // Find matching soldier (case-insensitive prefix/contains match on last name)
        let matches = soldiers.filter { soldier in
            let lastName = soldier.name.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? soldier.name
            return lastName.localizedCaseInsensitiveContains(lastToken) ||
                   lastName.lowercased().hasPrefix(lastToken.lowercased())
        }
        
        if matches.count == 1, let match = matches.first {
            markPresent(match)
        }
        
        // Clear input after processing
        inputText = ""
    }
    
    private func markPresent(_ soldier: Soldier) {
        guard let slot = selectedSlot else { return }
        
        // Optimistic UI: remove immediately
        soldiers.removeAll { $0 == soldier }
        
        Task {
            do {
                let colLetter = await SheetsService.shared.columnLetter(for: slot.columnIndex)
                let range = "\(selectedSheet)!\(colLetter)\(soldier.row)"
                try await SheetsService.shared.write(range: range, values: [["P"]])
                
                await MainActor.run {
                    showToast("✅ Marked \(soldier.name) present")
                }
            } catch {
                // Restore on failure
                await MainActor.run {
                    soldiers.append(soldier)
                    showToast("❌ Failed to mark \(soldier.name)")
                }
            }
        }
    }
    
    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }
    
    // MARK: - Data Loading
    
    private func loadData() async {
        isLoading = true
        errorMessage = nil
        
        do {
            // 1. Fetch all sheet names
            allSheetNames = try await SheetsService.shared.fetchSheetNames()
                .filter { $0.contains("-") } // Only date-range sheets
            
            // 2. Auto-select sheet based on today's date
            selectedSheet = autoSelectSheet() ?? allSheetNames.first ?? ""
            
            guard !selectedSheet.isEmpty else {
                throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "No sheets found"])
            }
            
            // 3. Load slots and soldiers
            await loadSlots()
            
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func loadSlots() async {
        do {
            // Fetch header rows
            let headers = try await SheetsService.shared.fetchHeaderRows(sheet: selectedSheet)
            
            guard headers.count >= 3 else {
                errorMessage = "Invalid sheet format"
                return
            }
            
            let row2 = headers.count > 1 ? headers[1] : [] // Days
            let row3 = headers.count > 2 ? headers[2] : [] // Slots
            
            // Build column map
            allSlots = buildColumnMap(dayRow: row2, slotRow: row3)
            
            // Filter to today's slots
            todaySlots = filterTodaySlots()
            
            // Auto-select slot based on time
            selectedSlot = autoSelectSlot()
            
            // Load soldiers
            await loadSoldiers()
            
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func loadSoldiers() async {
        guard let slot = selectedSlot else {
            soldiers = []
            return
        }
        
        do {
            let data = try await SheetsService.shared.fetchNamesAndValues(
                sheet: selectedSheet,
                columnIndex: slot.columnIndex
            )
            
            soldiers = data.compactMap { item in
                guard let color = SoldierColor.from(value: item.value) else {
                    return nil // P = hidden
                }
                return Soldier(name: item.name, value: item.value, row: item.row, color: color)
            }
            
            // Refocus input
            isInputFocused = true
            
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    // MARK: - Auto-Selection Logic
    
    private func autoSelectSheet() -> String? {
        let today = Date()
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: today)
        
        for sheetName in allSheetNames {
            guard let (startDate, endDate) = parseDateRange(sheetName) else { continue }
            
            switch weekday {
            case 1: // Sunday - use sheet starting today
                if calendar.isDate(startDate, inSameDayAs: today) {
                    return sheetName
                }
            case 7: // Saturday - use sheet starting tomorrow
                if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
                   calendar.isDate(startDate, inSameDayAs: tomorrow) {
                    return sheetName
                }
            default: // Monday-Friday - use sheet containing today
                if today >= startDate && today <= endDate {
                    return sheetName
                }
            }
        }
        
        return allSheetNames.first
    }
    
        private func parseDateRange(_ sheetName: String) -> (Date, Date)? {
            // Format: "M/DD-M/DD" e.g. "3/22-3/27"
            let parts = sheetName.components(separatedBy: "-")
            guard parts.count == 2 else { return nil }
            
            let formatter = DateFormatter()
            formatter.dateFormat = "M/dd"
            
            let calendar = Calendar.current
            let currentYear = calendar.component(.year, from: Date())
            
            guard let startMonthDay = formatter.date(from: parts[0].trimmingCharacters(in: .whitespaces)),
                let endMonthDay = formatter.date(from: parts[1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            
            var startComponents = calendar.dateComponents([.month, .day], from: startMonthDay)
            var endComponents = calendar.dateComponents([.month, .day], from: endMonthDay)
            
            startComponents.year = currentYear
            endComponents.year = currentYear
            
            guard let startDate = calendar.date(from: startComponents),
                let endDate = calendar.date(from: endComponents)
            else { return nil }
            
            return (startDate, endDate)
        }
        
        private func buildColumnMap(dayRow: [String], slotRow: [String]) -> [ColumnSlot] {
            var slots: [ColumnSlot] = []
            var currentDay = ""
            
            for (index, _) in slotRow.enumerated() {
                // Carry forward the last non-empty day (handles merged cells)
                if index < dayRow.count && !dayRow[index].isEmpty {
                    currentDay = dayRow[index]
                }
                
                let slotName = index < slotRow.count ? slotRow[index] : ""
                
                // Skip columns without a slot name or day
                guard !slotName.isEmpty, !currentDay.isEmpty else { continue }
                
                slots.append(ColumnSlot(day: currentDay, slot: slotName, columnIndex: index))
            }
            
            return slots
        }
        
        private func filterTodaySlots() -> [ColumnSlot] {
            let calendar = Calendar.current
            let weekday = calendar.component(.weekday, from: Date())
            
            let dayName: String
            switch weekday {
            case 1: dayName = "Sunday"
            case 2: dayName = "Monday"
            case 3: dayName = "Tuesday"
            case 4: dayName = "Wednesday"
            case 5: dayName = "Thursday"
            case 6: dayName = "Friday"
            case 7: dayName = "Saturday"
            default: dayName = ""
            }
            
            return allSlots.filter { $0.day.lowercased() == dayName.lowercased() }
        }
        
        private func autoSelectSlot() -> ColumnSlot? {
            guard !todaySlots.isEmpty else { return nil }
            
            let calendar = Calendar.current
            let now = Date()
            let hour = calendar.component(.hour, from: now)
            let minute = calendar.component(.minute, from: now)
            let totalMinutes = hour * 60 + minute
            
            // Time ranges per spec [5]:
            // Before 4:00 AM (240 min) → None
            // 4:00 AM – 6:24 AM (240-384) → MTT
            // 6:25 AM – 2:59 PM (385-899) → M Formo
            // 3:00 PM – 5:29 PM (900-1049) → ATT
            // 5:30 PM – 5:59 PM (1050-1079) → E Formo
            // Sunday 6:00 PM+ (1080+) → EST
            
            let targetSlot: String
            
            if totalMinutes < 240 {
                return nil // Before 4 AM, no slot
            } else if totalMinutes < 385 {
                targetSlot = "MTT"
            } else if totalMinutes < 900 {
                targetSlot = "M Formo"
            } else if totalMinutes < 1050 {
                targetSlot = "ATT"
            } else if totalMinutes < 1080 {
                targetSlot = "E Formo"
            } else {
                // 6:00 PM or later
                let weekday = calendar.component(.weekday, from: now)
                if weekday == 1 { // Sunday
                    targetSlot = "EST"
                } else {
                    targetSlot = "E Formo"
                }
            }
            
            // Find the target slot in today's valid slots
            if let slot = todaySlots.first(where: { $0.slot == targetSlot }) {
                return slot
            }
            
            // Fallback: find the previous slot that exists
            let slotOrder = ["EST", "MTT", "M Formo", "ATT", "E Formo"]
            if let targetIndex = slotOrder.firstIndex(of: targetSlot) {
                for i in stride(from: targetIndex, through: 0, by: -1) {
                    if let slot = todaySlots.first(where: { $0.slot == slotOrder[i] }) {
                        return slot
                    }
                }
            }
            
            // Last resort: first available slot
            return todaySlots.first
        }
    }

    // MARK: - Preview

    #Preview {
        ContentView()
    }