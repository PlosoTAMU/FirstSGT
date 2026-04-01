import SwiftUI

// MARK: - Data Models

struct Cadet: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let lastName: String
    let searchableNames: [String]
    let value: String
    let row: Int
    let statusColor: StatusColor
    let groupColor: SheetsService.GroupColor
    
    static func == (lhs: Cadet, rhs: Cadet) -> Bool {
        lhs.row == rhs.row && lhs.name == rhs.name
    }
}

enum StatusColor: Int, Comparable {
    case gray = 0
    case blue = 1
    case yellow = 2
    case purple = 3
    
    static func < (lhs: StatusColor, rhs: StatusColor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var color: Color {
        switch self {
        case .gray: return Color(.systemGray4)
        case .blue: return .blue
        case .yellow: return .yellow
        case .purple: return .purple
        }
    }
    
    var borderColor: Color {
        switch self {
        case .gray: return Color(.systemGray3)
        case .blue: return .blue
        case .yellow: return .orange
        case .purple: return .purple
        }
    }
    
    static func from(value: String) -> StatusColor? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        
        if trimmed == "P" || trimmed == "UA" { return nil }
        if trimmed == "ROTC" { return .purple }
        
        let lower = trimmed.lowercased()
        if lower.hasPrefix("e (t-") || lower.hasPrefix("e (tut") {
            return .yellow
        }
        if lower.hasPrefix("e (") {
            return .blue
        }
        
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

struct StatItem: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

enum UndoAction {
    case markPresent(cadet: Cadet, previousValue: String)
    case markAllUA(cadets: [Cadet], previousValues: [String])
}

// MARK: - Main View

struct ContentView: View {
    @State private var allSheetNames: [String] = []
    @State private var sheetsWithIds: [(name: String, sheetId: Int)] = []
    @State private var selectedSheet: String = ""
    @State private var showSheetPicker = false
    
    @State private var allSlots: [ColumnSlot] = []
    @State private var todaySlots: [ColumnSlot] = []
    @State private var selectedSlot: ColumnSlot?
    @State private var showSlotPicker = false
    
    @State private var cadets: [Cadet] = []
    @State private var stats: [StatItem] = []
    
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var toastMessage: String?
    
    @State private var showUAConfirmation = false
    @State private var isMarkingUA = false
    
    @State private var undoStack: [UndoAction] = []
    @State private var isUndoing = false
    
    @State private var showSheetCreatedAlert = false
    @State private var createdSheetName = ""
    
    @State private var showStatsSheet = false
    
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
            
            inputFieldView
            
            if let toast = toastMessage {
                Text(toast)
                    .font(.caption)
                    .padding(8)
                    .background(toast.contains("✅") || toast.contains("↩️") ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .cornerRadius(8)
                    .padding(.bottom, 8)
            }
        }
        .task {
            await loadData()
        }
        .confirmationDialog("Mark All as UA?", isPresented: $showUAConfirmation, titleVisibility: .visible) {
            Button("Mark \(cadets.count) cadets as UA", role: .destructive) {
                Task { await markAllAsUA() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will mark all remaining \(cadets.count) cadets as Unexcused Absence (UA). This cannot be undone from the app.")
        }
        .alert("New Sheet Created", isPresented: $showSheetCreatedAlert) {
            Button("OK") { }
        } message: {
            Text("Created sheet: \(createdSheetName)")
        }
        .sheet(isPresented: $showStatsSheet) {
            statsView
        }
    }
    
    // MARK: - Header View
    
    private var headerView: some View {
        HStack {
            Button(action: { Task { await performUndo() } }) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.title2)
                    .foregroundColor(undoStack.isEmpty ? .gray : .blue)
            }
            .disabled(undoStack.isEmpty || isUndoing)
            
            Spacer()
            
            VStack(spacing: 4) {
                Button(action: { showSheetPicker = true }) {
                    HStack {
                        Text("Week: \(selectedSheet)")
                            .font(.headline)
                        Image(systemName: "chevron.down").font(.caption)
                    }
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
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                    .confirmationDialog("Select Slot", isPresented: $showSlotPicker) {
                        ForEach(allSlots) { slot in
                            Button(slot.displayName) {
                                selectedSlot = slot
                                Task { await loadCadets() }
                            }
                        }
                    }
                }
            }
            
            Spacer()
            
            Button(action: { showStatsSheet = true }) {
                Image(systemName: "info.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
            .disabled(stats.isEmpty)
            
            Button(action: { showUAConfirmation = true }) {
                if isMarkingUA {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundColor(.orange)
                }
            }
            .disabled(cadets.isEmpty || isMarkingUA)
        }
        .padding()
    }
    
    // MARK: - Stats View
    
    private var statsView: some View {
        NavigationView {
            List {
                ForEach(stats) { stat in
                    HStack {
                        Text(stat.label)
                        Spacer()
                        Text(stat.value)
                            .foregroundColor(.secondary)
                            .bold()
                    }
                }
            }
            .navigationTitle("Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showStatsSheet = false }
                }
            }
        }
    }
    
    // MARK: - Name Grid View
    
    private var nameGridView: some View {
        ScrollView {
            FlowLayout(spacing: 8) {
                ForEach(sortedCadets) { cadet in
                    cadetBubble(cadet)
                }
            }
            .padding()
        }
    }
    
    private var sortedCadets: [Cadet] {
        cadets.sorted { lhs, rhs in
            if lhs.statusColor != rhs.statusColor {
                return lhs.statusColor < rhs.statusColor
            }
            if lhs.groupColor != rhs.groupColor {
                return lhs.groupColor < rhs.groupColor
            }
            return lhs.lastName.localizedCaseInsensitiveCompare(rhs.lastName) == .orderedAscending
        }
    }
    
    private func cadetBubble(_ cadet: Cadet) -> some View {
        HStack(spacing: 4) {
            Text(cadet.lastName)
                .font(.system(size: 14, weight: .medium))
            
            if let excuseCode = getExcuseCode(from: cadet.value, color: cadet.statusColor) {
                Text(excuseCode)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(cadet.statusColor.color)
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(cadet.statusColor.color.opacity(cadet.statusColor == .gray ? 1 : 0.3))
        .foregroundColor(cadet.statusColor == .gray ? .primary : (cadet.statusColor == .yellow ? .black : cadet.statusColor.color))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(cadet.statusColor.borderColor, lineWidth: cadet.statusColor == .gray ? 0 : 1.5)
        )
    }

    private func getExcuseCode(from value: String, color: StatusColor) -> String? {
        let lower = value.lowercased()
        
        switch color {
        case .purple:
            return "R" // ROTC
            
        case .blue:
            // E (Class) -> C, E (Sick) -> S, E (Work) -> W, E (religious) -> R, etc.
            if lower.contains("class") { return "C" }
            if lower.contains("sick") { return "S" }
            if lower.contains("work") { return "W" }
            if lower.contains("religious") { return "R" }
            if lower.contains("special") { return "T" } // Special uniT
            return nil // E (other) shows nothing
            
        case .yellow:
            // E (t-other) -> nothing, E (Event) -> E, E (bag/refocus) -> B
            if lower.contains("event") { return "E" }
            if lower.contains("bag") || lower.contains("refocus") { return "B" }
            if lower.contains("sick") { return "S" }
            if lower.contains("out of town") || lower.contains("out-of-town") { return "O" }
            return nil // E (t-other) shows nothing
            
        case .gray:
            return nil
        }
    }
    
    // MARK: - Input Field
    
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
    
    // MARK: - Input Handling
    
    private func handleInput(_ text: String) {
        guard text.hasSuffix(" ") else { return }
        
        let token = text.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .last ?? ""
        
        guard !token.isEmpty else {
            inputText = ""
            return
        }
        
        let exactMatches = cadets.filter { cadet in
            cadet.searchableNames.contains { $0.lowercased() == token.lowercased() }
        }
        
        if exactMatches.count == 1 {
            markPresent(exactMatches[0])
            inputText = ""
            return
        }
        
        let prefixMatches = cadets.filter { cadet in
            cadet.searchableNames.contains { $0.lowercased().hasPrefix(token.lowercased()) }
        }
        
        if prefixMatches.count == 1 {
            markPresent(prefixMatches[0])
            inputText = ""
            return
        }
        
        let fuzzyMatches = cadets.filter { cadet in
            cadet.searchableNames.contains { levenshteinDistance($0.lowercased(), token.lowercased()) == 1 }
        }
        
        if fuzzyMatches.count == 1 {
            markPresent(fuzzyMatches[0])
            inputText = ""
            return
        }
        
        if fuzzyMatches.count > 1 {
            showToast("⚠️ Ambiguous: \(fuzzyMatches.map { $0.lastName }.joined(separator: ", "))")
        }
        
        inputText = ""
    }
    
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
                    dp[i][j] = min(dp[i - 1][j] + 1,
                                   dp[i][j - 1] + 1,
                                   dp[i - 1][j - 1] + 1)
                }
            }
        }
        
        return dp[m][n]
    }
    
    private func markPresent(_ cadet: Cadet) {
        guard let slot = selectedSlot else { return }
        
        undoStack.append(.markPresent(cadet: cadet, previousValue: cadet.value))
        
        cadets.removeAll { $0 == cadet }
        showToast("✅ Marked \(cadet.lastName) present")
        
        Task {
            do {
                let colLetter = await SheetsService.shared.columnLetter(for: slot.columnIndex)
                let range = "\(selectedSheet)!\(colLetter)\(cadet.row)"
                try await SheetsService.shared.write(range: range, values: [["P"]])
            } catch {
                await MainActor.run {
                    undoStack.removeLast()
                    cadets.append(cadet)
                    showToast("❌ Failed to mark \(cadet.lastName)")
                }
            }
        }
    }
    
    // MARK: - Mark All UA
    
    private func markAllAsUA() async {
        guard let slot = selectedSlot else { return }
        isMarkingUA = true
        
        let cadetsToMark = cadets
        let previousValues = cadetsToMark.map { $0.value }
        
        undoStack.append(.markAllUA(cadets: cadetsToMark, previousValues: previousValues))
        
        for cadet in cadetsToMark {
            do {
                let colLetter = await SheetsService.shared.columnLetter(for: slot.columnIndex)
                let range = "\(selectedSheet)!\(colLetter)\(cadet.row)"
                try await SheetsService.shared.write(range: range, values: [["UA"]])
                await MainActor.run { cadets.removeAll { $0 == cadet } }
            } catch {
                continue
            }
        }
        
        await MainActor.run {
            isMarkingUA = false
            showToast("✅ Marked \(cadetsToMark.count) as UA")
        }
    }
    
    // MARK: - Undo
    
    private func performUndo() async {
        guard let lastAction = undoStack.popLast(), let slot = selectedSlot else { return }
        isUndoing = true
        
        do {
            switch lastAction {
            case .markPresent(let cadet, let previousValue):
                let colLetter = await SheetsService.shared.columnLetter(for: slot.columnIndex)
                let range = "\(selectedSheet)!\(colLetter)\(cadet.row)"
                try await SheetsService.shared.write(range: range, values: [[previousValue]])
                await MainActor.run {
                    cadets.append(cadet)
                    showToast("↩️ Restored \(cadet.lastName)")
                }
                
            case .markAllUA(let cadetList, let previousValues):
                for (index, cadet) in cadetList.enumerated() {
                    let colLetter = await SheetsService.shared.columnLetter(for: slot.columnIndex)
                    let range = "\(selectedSheet)!\(colLetter)\(cadet.row)"
                    let prevValue = index < previousValues.count ? previousValues[index] : "TBD"
                    try await SheetsService.shared.write(range: range, values: [[prevValue]])
                    await MainActor.run {
                        cadets.append(cadet)
                    }
                }
                await MainActor.run {
                    showToast("↩️ Restored \(cadetList.count) cadets")
                }
            }
        } catch {
            await MainActor.run {
                showToast("❌ Undo failed")
            }
        }
        
        await MainActor.run {
            isUndoing = false
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
            sheetsWithIds = try await SheetsService.shared.fetchSheetNamesWithIds()
            allSheetNames = sheetsWithIds
                .map { $0.name }
                .filter { $0.contains("-") && $0.contains("/") }
            
            let (selected, needsCreation) = autoSelectSheetOrCreate()
            
            if needsCreation, let templateId = findTemplateSheetId() {
                let newSheetName = generateNewSheetName()
                try await SheetsService.shared.copySheet(
                    sourceSheetId: templateId,
                    newTitle: newSheetName,
                    insertAtIndex: 1
                )
                await MainActor.run {
                    createdSheetName = newSheetName
                    showSheetCreatedAlert = true
                }
                
                sheetsWithIds = try await SheetsService.shared.fetchSheetNamesWithIds()
                allSheetNames = sheetsWithIds.map { $0.name }.filter { $0.contains("-") && $0.contains("/") }
                selectedSheet = newSheetName
            } else {
                selectedSheet = selected ?? allSheetNames.first ?? ""
            }
            
            guard !selectedSheet.isEmpty else {
                throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "No sheets found"])
            }
            
            await loadSlots()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
        
        await MainActor.run {
            isLoading = false
        }
    }
    
    private func loadSlots() async {
        do {
            let headers = try await SheetsService.shared.fetchHeaderRows(sheet: selectedSheet)
            
            let row2 = headers.count > 1 ? headers[1] : []
            let row3 = headers.count > 2 ? headers[2] : []
            
            await MainActor.run {
                allSlots = buildColumnMap(dayRow: row2, slotRow: row3)
                todaySlots = filterTodaySlots()
                selectedSlot = autoSelectSlot()
            }
            
            await loadCadets()
            
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func loadCadets() async {
        guard let slot = selectedSlot else {
            await MainActor.run {
                cadets = []
                stats = []
            }
            return
        }
        
        do {
            let result = try await SheetsService.shared.fetchNamesValuesColorsAndStats(
                sheet: selectedSheet,
                columnIndex: slot.columnIndex
            )
            
            let parsedCadets = result.cadets.compactMap { item -> Cadet? in
                guard let statusColor = StatusColor.from(value: item.value) else {
                    return nil
                }
                
                let fullName = item.name
                let lastName = fullName.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? fullName
                
                var searchableNames: [String] = []
                let nameParts = lastName.components(separatedBy: "/")
                for part in nameParts {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        searchableNames.append(trimmed)
                    }
                }
                
                let displayName = searchableNames.first ?? lastName
                
                return Cadet(
                    name: fullName,
                    lastName: displayName,
                    searchableNames: searchableNames,
                    value: item.value,
                    row: item.row,
                    statusColor: statusColor,
                    groupColor: item.groupColor
                )
            }
            
            let parsedStats = result.stats.map { StatItem(label: $0.label, value: $0.value) }
            
            await MainActor.run {
                cadets = parsedCadets
                stats = parsedStats
                isInputFocused = true
            }
            
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func autoSelectSheetOrCreate() -> (String?, Bool) {
        let today = Date()
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: today)
        
        for sheetName in allSheetNames {
            guard let (startDate, endDate) = parseDateRange(sheetName) else { continue }
            
            switch weekday {
            case 1:
                if calendar.isDate(startDate, inSameDayAs: today) { return (sheetName, false) }
            case 7:
                if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
                   calendar.isDate(startDate, inSameDayAs: tomorrow) { return (sheetName, false) }
            default:
                if today >= startDate && today <= endDate { return (sheetName, false) }
            }
        }
        
        return (nil, true)
    }
    
    private func findTemplateSheetId() -> Int? {
        // Use the baseline template sheet (first non-date sheet)
        let templateName = sheetsWithIds
            .map { $0.name }
            .first { !$0.contains("-") && !$0.contains("/") && $0.uppercased().contains("TEMPLATE") }
        
        if let template = templateName,
        let match = sheetsWithIds.first(where: { $0.name == template }) {
            return match.sheetId
        }
        return nil
    }
    
    private func generateNewSheetName() -> String {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        
        let daysToSubtract = weekday == 1 ? 0 : weekday - 1
        guard let sunday = calendar.date(byAdding: .day, value: -daysToSubtract, to: today),
              let friday = calendar.date(byAdding: .day, value: 5, to: sunday)
        else { return "" }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        
        return "\(formatter.string(from: sunday))-\(formatter.string(from: friday))"
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

// MARK: - Flow Layout

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

#Preview {
    ContentView()
}