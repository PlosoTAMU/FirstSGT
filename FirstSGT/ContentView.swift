import SwiftUI

// MARK: - Data Models

struct Soldier: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let lastName: String
    let value: String
    let row: Int
    let color: SoldierColor
    
    static func == (lhs: Soldier, rhs: Soldier) -> Bool {
        lhs.row == rhs.row && lhs.name == rhs.name
    }
}

enum SoldierColor: Int, Comparable {
    case purple = 0
    case blue = 1
    case yellow = 2
    case gray = 3
    
    static func < (lhs: SoldierColor, rhs: SoldierColor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var color: Color {
        switch self {
        case .purple: return .purple
        case .blue: return .blue
        case .yellow: return .yellow
        case .gray: return Color(.systemGray4)
        }
    }
    
    static func from(value: String) -> SoldierColor? {
        if value == "P" { return nil }
        if value == "ROTC" { return .purple }
        if value.hasPrefix("E (t-") { return .yellow }
        if value.hasPrefix("E (") { return .blue }
        return .gray
    }
}

struct ColumnSlot: Identifiable, Hashable {
    let id = UUID()
    let day: String
    let slot: String
    let columnIndex: Int
    
    var displayName: String {
        "\(day) \(slot)"
    }
}

// MARK: - Main View

struct ContentView: View {
    @State private var allSheetNames: [String] = []
    @State private var selectedSheet: String = ""
    @State private var showSheetPicker = false
    
    @State private var allSlots: [ColumnSlot] = []
    @State private var todaySlots: [ColumnSlot] = []
    @State private var selectedSlot: ColumnSlot?
    @State private var showSlotPicker = false
    
    @State private var soldiers: [Soldier] = []
    
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var toastMessage: String?
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
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
                nameGridView
            }
            
            // Visible input field
            inputFieldView
            
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
            
            if !allSlots.isEmpty {
                Button(action: { showSlotPicker = true }) {
                    HStack {
                        Text("Slot: \(selectedSlot?.displayName ?? "None")")
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
                .confirmationDialog("Select Slot", isPresented: $showSlotPicker) {
                    ForEach(allSlots) { slot in
                        Button(slot.displayName) {
                            selectedSlot = slot
                            Task { await loadSoldiers() }
                        }
                    }
                }
            }
        }
        .padding()
    }
    
    // MARK: - Name Grid View (Flowing Bubbles)
    
    private var nameGridView: some View {
        ScrollView {
            FlowLayout(spacing: 8) {
                ForEach(sortedSoldiers) { soldier in
                    soldierBubble(soldier)
                }
            }
            .padding()
        }
    }
    
    private var sortedSoldiers: [Soldier] {
        soldiers.sorted { lhs, rhs in
            if lhs.color != rhs.color {
                return lhs.color < rhs.color
            }
            return lhs.lastName.localizedCaseInsensitiveCompare(rhs.lastName) == .orderedAscending
        }
    }
    
    private func soldierBubble(_ soldier: Soldier) -> some View {
        Text(soldier.lastName)
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(soldier.color.color.opacity(soldier.color == .gray ? 1 : 0.3))
            .foregroundColor(soldier.color == .gray ? .primary : soldier.color.color == .yellow ? .black : soldier.color.color)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(soldier.color == .gray ? Color.clear : soldier.color.color, lineWidth: 1.5)
            )
    }
    
    // MARK: - Input Field (Visible)
    
    private var inputFieldView: some View {
        HStack {
            TextField("Type last name...", text: $inputText)
                .focused($isInputFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .onChange(of: inputText) { newValue in
                    handleInput(newValue)
                }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .onAppear {
            isInputFocused = true
        }
    }
    
    // MARK: - Input Handling with Fuzzy Match
    
    private func handleInput(_ text: String) {
        guard text.hasSuffix(" ") else { return }
        
        let token = text.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .last ?? ""
        
        guard !token.isEmpty else {
            inputText = ""
            return
        }
        
        // Try exact match first (case-insensitive)
        let exactMatches = soldiers.filter {
            $0.lastName.lowercased() == token.lowercased()
        }
        
        if exactMatches.count == 1 {
            markPresent(exactMatches[0])
            inputText = ""
            return
        }
        
        // Try prefix match
        let prefixMatches = soldiers.filter {
            $0.lastName.lowercased().hasPrefix(token.lowercased())
        }
        
        if prefixMatches.count == 1 {
            markPresent(prefixMatches[0])
            inputText = ""
            return
        }
        
        // Try fuzzy match (1 edit distance)
        let fuzzyMatches = soldiers.filter {
            levenshteinDistance($0.lastName.lowercased(), token.lowercased()) == 1
        }
        
        if fuzzyMatches.count == 1 {
            markPresent(fuzzyMatches[0])
            inputText = ""
            return
        }
        
        // No match or ambiguous — clear input, show feedback
        if fuzzyMatches.count > 1 {
            showToast("⚠️ Ambiguous: \(fuzzyMatches.map { $0.lastName }.joined(separator: ", "))")
        }
        
        inputText = ""
    }
    
    // Levenshtein distance for fuzzy matching
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1 = Array(s1)
        let s2 = Array(s2)
        let m = s1.count
        let n = s2.count
        
        if m == 0 { return n }
        if n == 0 { return m }
        
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        
        for i in 1...m {
            for j in 1...n {
                if s1[i - 1] == s2[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = min(dp[i - 1][j] + 1,      // deletion
                                   dp[i][j - 1] + 1,      // insertion
                                   dp[i - 1][j - 1] + 1)  // substitution
                }
            }
        }
        
        return dp[m][n]
    }
    
    private func markPresent(_ soldier: Soldier) {
        guard let slot = selectedSlot else { return }
        
        soldiers.removeAll { $0 == soldier }
        showToast("✅ Marked \(soldier.lastName) present")
        
        Task {
            do {
                let colLetter = await SheetsService.shared.columnLetter(for: slot.columnIndex)
                let range = "\(selectedSheet)!\(colLetter)\(soldier.row)"
                try await SheetsService.shared.write(range: range, values: [["P"]])
            } catch {
                await MainActor.run {
                    soldiers.append(soldier)
                    showToast("❌ Failed to mark \(soldier.lastName)")
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
            allSheetNames = try await SheetsService.shared.fetchSheetNames()
                .filter { $0.contains("-") && $0.contains("/") }
            
            selectedSheet = autoSelectSheet() ?? allSheetNames.first ?? ""
            
            guard !selectedSheet.isEmpty else {
                throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "No sheets found"])
            }
            
            await loadSlots()
            
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func loadSlots() async {
        errorMessage = nil
        
        do {
            let headers = try await SheetsService.shared.fetchHeaderRows(sheet: selectedSheet)
            
            let row2 = headers.count > 1 ? headers[1] : []
            let row3 = headers.count > 2 ? headers[2] : []
            
            allSlots = buildColumnMap(dayRow: row2, slotRow: row3)
            todaySlots = filterTodaySlots()
            selectedSlot = autoSelectSlot()
            
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
                    return nil
                }
                let lastName = item.name.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? item.name
                return Soldier(name: item.name, lastName: lastName, value: item.value, row: item.row, color: color)
            }
            
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
            case 1:
                if calendar.isDate(startDate, inSameDayAs: today) { return sheetName }
            case 7:
                if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
                   calendar.isDate(startDate, inSameDayAs: tomorrow) { return sheetName }
            default:
                if today >= startDate && today <= endDate { return sheetName }
            }
        }
        
        return allSheetNames.first
    }
    
    private func parseDateRange(_ sheetName: String) -> (Date, Date)? {
        let parts = sheetName.components(separatedBy: "-")
        guard parts.count == 2 else { return nil }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        
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
        
        let maxIndex = max(dayRow.count, slotRow.count)
        
        for index in 0..<maxIndex {
            if index < dayRow.count && !dayRow[index].isEmpty {
                currentDay = dayRow[index]
            }
            
            let slotName = index < slotRow.count ? slotRow[index] : ""
            
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
        
        return allSlots.filter { $0.day.lowercased().contains(dayName.lowercased()) }
    }
    
    private func autoSelectSlot() -> ColumnSlot? {
        guard !todaySlots.isEmpty else { return allSlots.first }
        
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let totalMinutes = hour * 60 + minute
        
        let targetSlot: String
        
        if totalMinutes < 240 {
            return todaySlots.first
        } else if totalMinutes < 385 {
            targetSlot = "MTT"
        } else if totalMinutes < 900 {
            targetSlot = "M Formo"
        } else if totalMinutes < 1050 {
            targetSlot = "ATT"
        } else if totalMinutes < 1080 {
            targetSlot = "E Formo"
        } else {
            let weekday = calendar.component(.weekday, from: now)
            targetSlot = weekday == 1 ? "EST" : "E Formo"
        }
        
        if let slot = todaySlots.first(where: { $0.slot == targetSlot }) {
            return slot
        }
        
        return todaySlots.first
    }
}

// MARK: - Flow Layout for Bubbles

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        
        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { continue }
            let position = result.positions[index]
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(subview.sizeThatFits(.unspecified))
            )
        }
    }
    
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            // Check if we need to wrap to next line
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            
            positions.append(CGPoint(x: currentX, y: currentY))
            
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }
        
        totalHeight = currentY + lineHeight
        
        return (CGSize(width: totalWidth, height: totalHeight), positions)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}