import SwiftUI

// MARK: - Data Models

struct Cadet: Identifiable, Equatable {
    /// Row number is unique per cadet and stable across refreshes. A fresh UUID
    /// per parse made every auto-refresh replace the whole grid's view identity,
    /// which tore down bubbles mid-tap.
    var id: Int { row }
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
    case red = 4  // NEW: for UA
    
    static func < (lhs: StatusColor, rhs: StatusColor) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var color: Color {
        switch self {
        case .gray: return Color(.systemGray4)
        case .blue: return .blue
        case .yellow: return .yellow
        case .purple: return .purple
        case .red: return .red  // NEW
        }
    }
    
    var borderColor: Color {
        switch self {
        case .gray: return Color(.systemGray3)
        case .blue: return .blue
        case .yellow: return .orange
        case .purple: return .purple
        case .red: return .red  // NEW
        }
    }
    
    static func from(value: String) -> StatusColor? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        
        // P is the only one that gets filtered out (they're done)
        if trimmed == "P" { return nil }
        
        // UA shows as red
        if trimmed == "UA" { return .red }
        
        // ROTC shows as purple
        if trimmed.uppercased() == "ROTC" { return .purple }
        
        let lower = trimmed.lowercased()
        
        // Check if it's an E (...) excuse
        if lower.hasPrefix("e (") {
            // YELLOW excuses (explicitly listed)
            if lower.contains("t-other") ||
            lower.contains("event") ||
            lower.contains("bag") ||
            lower.contains("refocus") ||
            lower.contains("sick") ||
            lower.contains("out of town") {
                return .yellow
            }
            // BLUE excuses (everything else)
            return .blue
        }
        
        // TBD and anything else shows as gray
        return .gray
    }
}

struct ColumnSlot: Identifiable, Hashable {
    let id = UUID()
    let day: String
    let slot: String
    let columnIndex: Int
    
    var displayName: String {
        day.isEmpty ? slot : "\(day) \(slot)"
    }
}

struct StatItem: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

enum UndoAction {
    case markPresent(cadet: Cadet, previousValue: String)
}

// MARK: - Main View

struct ContentView: View {
    @State private var refreshTimer: Timer?
    @State private var selectedCadetForStatus: Cadet?

    @State private var allSheetNames: [String] = []
    @State private var weekSheetNames: [String] = []
    @State private var otherSheetNames: [String] = []
    @State private var sheetsWithIds: [(name: String, sheetId: Int)] = []
    @State private var selectedSheet: String = ""
    
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
    
    @State private var showNewSheetConfirmation = false
    @State private var isCreatingSheet = false
    
    @State private var undoStack: [UndoAction] = []
    @State private var isUndoing = false
    
    @State private var showSheetCreatedAlert = false
    @State private var createdSheetName = ""
    
    @State private var showStatsSheet = false
    @State private var selectedCadetForComment: Cadet?
    @State private var commentText: String?
    @State private var showCommentAlert = false

    private func cadetBubble(_ cadet: Cadet) -> some View {
        HStack(spacing: 4) {
            Text(cadet.lastName)
                .font(.system(size: 14, weight: .medium))
            
            if let excuseCode = getExcuseCode(from: cadet.value, color: cadet.statusColor) {
                Text(excuseCode)
                    .font(.system(size: 10, weight: .bold))
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
        .foregroundColor(
            cadet.statusColor == .gray ? .primary :
            cadet.statusColor == .yellow ? .black :
            cadet.statusColor.color
        )
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(cadet.statusColor.borderColor, lineWidth: cadet.statusColor == .gray ? 0 : 1.5)
        )
        .onTapGesture {
            selectedCadetForStatus = cadet
        }
        .onLongPressGesture {
            Task {
                await fetchCommentForCadet(cadet)
            }
        }
    }

    private func fetchCommentForCadet(_ cadet: Cadet) async {
        guard let slot = selectedSlot else { return }
        
        do {
            let comment = try await SheetsService.shared.fetchCellComment(
                sheet: selectedSheet,
                column: slot.columnIndex,
                row: cadet.row
            )
            
            await MainActor.run {
                selectedCadetForComment = cadet
                commentText = comment ?? "No comment"
                showCommentAlert = true
            }
        } catch {
            await MainActor.run {
                selectedCadetForComment = cadet
                commentText = "Failed to load comment"
                showCommentAlert = true
            }
        }
    }
    
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
        .contentShape(Rectangle())
        .onTapGesture {
            isInputFocused = false
        }
        .task {
            await loadData()
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .confirmationDialog(newSheetDialogTitle, isPresented: $showNewSheetConfirmation, titleVisibility: .visible) {
            Button(newSheetConfirmButtonTitle) {
                Task { await createNewSheetManually() }
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("New Sheet Created", isPresented: $showSheetCreatedAlert) {
            Button("OK") { }
        } message: {
            Text("Created sheet: \(createdSheetName)")
        }
        .sheet(isPresented: $showStatsSheet) {
            statsView
        }
        .sheet(item: $selectedCadetForStatus) { cadet in
            StatusPickerView(
                cadet: cadet,
                onSelect: { status in
                    markWithStatus(cadet, status: status)
                    selectedCadetForStatus = nil
                },
                onCancel: {
                    selectedCadetForStatus = nil
                }
            )
            .presentationDetents([.medium, .large])
        }
        .alert("\(selectedCadetForComment?.lastName ?? "Cadet")", isPresented: $showCommentAlert) {
            Button("OK") { }
        } message: {
            Text(commentText ?? "No comment")
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
        
            // Open in Google Sheets button
            Button(action: openInGoogleSheets) {
                Image(systemName: "arrow.up.right.square")
                    .font(.title2)
                    .foregroundColor(.green)
            }
            
            // NEW: Refresh button
            Button(action: {
                Task { await fullRefresh() }
            }) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
            .disabled(isLoading)
            
            Spacer()
            
            VStack(spacing: 4) {
                Menu {
                    if !weekSheetNames.isEmpty {
                        Section("Weeks") {
                            ForEach(weekSheetNames, id: \.self) { name in
                                Button(name) { selectSheet(name) }
                            }
                        }
                    }
                    if !otherSheetNames.isEmpty {
                        Section("Other") {
                            ForEach(otherSheetNames, id: \.self) { name in
                                Button(name) { selectSheet(name) }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Week: \(selectedSheet)")
                            .font(.headline)
                        Image(systemName: "chevron.down").font(.caption)
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
                                Task {
                                    await MainActor.run {
                                        selectedSlot = slot
                                    }
                                    await loadCadets()
                                }
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
            
            Button(action: { showNewSheetConfirmation = true }) {
                if isCreatingSheet {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "doc.badge.plus")
                        .font(.title2)
                        .foregroundColor(.orange)
                }
            }
            .disabled(isCreatingSheet || isLoading)
        }
        .padding()
    }

    private func openInGoogleSheets() {
        let spreadsheetId = SheetsService.spreadsheetId
        
        // Find the gid for the currently selected sheet
        if let sheetInfo = sheetsWithIds.first(where: { $0.name == selectedSheet }) {
            let sheetURL = "https://docs.google.com/spreadsheets/d/\(spreadsheetId)/edit#gid=\(sheetInfo.sheetId)"
            if let url = URL(string: sheetURL) {
                UIApplication.shared.open(url)
            }
        } else {
            // Fallback to just opening the spreadsheet
            let sheetURL = "https://docs.google.com/spreadsheets/d/\(spreadsheetId)/edit"
            if let url = URL(string: sheetURL) {
                UIApplication.shared.open(url)
            }
        }
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
    
    private func markWithStatus(_ cadet: Cadet, status: String) {
        guard let slot = selectedSlot else { return }
        
        undoStack.append(.markPresent(cadet: cadet, previousValue: cadet.value))
        
        // Get the new status color
        let newStatusColor = StatusColor.from(value: status)
        
        // Remove old cadet first (forces SwiftUI to see the change)
        cadets.removeAll { $0.row == cadet.row }
        
        // If not P (which returns nil), add back with new status
        if let newColor = newStatusColor {
            let updatedCadet = Cadet(
                name: cadet.name,
                lastName: cadet.lastName,
                searchableNames: cadet.searchableNames,
                value: status,
                row: cadet.row,
                statusColor: newColor,
                groupColor: cadet.groupColor
            )
            cadets.append(updatedCadet)
        }
        
        let statusEmoji: String
        switch status {
        case "P": statusEmoji = "✅"
        case "UA": statusEmoji = "❌"
        case "TBD": statusEmoji = "⬜"
        case "ROTC": statusEmoji = "🟣"
        default: statusEmoji = "📝"
        }
        
        showToast("\(statusEmoji) Marked \(cadet.lastName) as \(status)")
        
        Task {
            do {
                let colLetter = await SheetsService.shared.columnLetter(for: slot.columnIndex)
                let range = "\(selectedSheet)!\(colLetter)\(cadet.row)"
                try await SheetsService.shared.write(range: range, values: [[status]])
            } catch {
                await MainActor.run {
                    undoStack.removeLast()
                    // Restore original cadet on failure
                    cadets.removeAll { $0.row == cadet.row }
                    cadets.append(cadet)
                    showToast("❌ Failed to mark \(cadet.lastName)")
                }
            }
        }
    }

    // MARK: - Full Refresh

    private func fullRefresh() async {
        // Stop auto-refresh during reload
        stopAutoRefresh()
        
        // Clear all state
        await MainActor.run {
            isLoading = true
            errorMessage = nil
            cadets = []
            stats = []
        }
        
        do {
            guard let slot = selectedSlot, !selectedSheet.isEmpty else {
                throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "No slot selected"])
            }
            
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
                showToast("✅ Refreshed")
            }
            
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
        
        await MainActor.run {
            isLoading = false
        }
        
        // Restart auto-refresh
        startAutoRefresh()
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { _ in
            Task {
                await refreshCadetsQuietly()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshCadetsQuietly() async {
        guard let slot = selectedSlot, !selectedSheet.isEmpty else { return }
        // Never mutate the roster while a picker/sheet is open on top of it.
        guard selectedCadetForStatus == nil, !showStatsSheet, !showCommentAlert else { return }
        
        do {
            let data = try await SheetsService.shared.fetchNamesValuesColorsAndStats(
                sheet: selectedSheet,
                columnIndex: slot.columnIndex
            )
            
            let newCadets = data.cadets.compactMap { item -> Cadet? in
                guard let statusColor = StatusColor.from(value: item.value) else { return nil }
                
                let fullName = item.name
                let lastName = fullName.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? fullName
                
                var searchableNames: [String] = []
                let nameParts = lastName.components(separatedBy: "/")
                for part in nameParts {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { searchableNames.append(trimmed) }
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
            
            let newStats = data.stats.map { StatItem(label: $0.label, value: $0.value) }
            
            await MainActor.run {
                // Update if data changed
                if newCadets.map({ $0.row }) != cadets.map({ $0.row }) ||
                newCadets.map({ $0.value }) != cadets.map({ $0.value }) {
                    cadets = newCadets
                }
                // Also refresh stats
                if newStats.map({ $0.value }) != stats.map({ $0.value }) {
                    stats = newStats
                }
            }
        } catch {
            // Silent fail for background refresh
        }
    }

    private var sortedCadets: [Cadet] {
        cadets.sorted { lhs, rhs in
            // 1. Sort by STATUS color first (gray TBD → blue E → yellow E → purple ROTC)
            if lhs.statusColor != rhs.statusColor {
                return lhs.statusColor < rhs.statusColor
            }
            // 2. Then by GROUP color (background color - keeps visual groups together)
            if lhs.groupColor != rhs.groupColor {
                return lhs.groupColor < rhs.groupColor
            }
            // 3. Finally alphabetical by last name
            return lhs.lastName.localizedCaseInsensitiveCompare(rhs.lastName) == .orderedAscending
        }
    }
    

    private func getExcuseCode(from value: String, color: StatusColor) -> String? {
        let lower = value.lowercased()
        
        switch color {
        case .red:
            return "UA"
            
        case .purple:
            return nil
            
        case .blue:
            if lower.contains("special") { return "U" }
            if lower.contains("class") { return "C" }
            if lower.contains("work") { return "W" }
            if lower.contains("religious") { return "R" }
            if lower.contains("tutoring") { return "T" }
            return nil
            
        case .yellow:
            if lower.contains("event") { return "E" }
            if lower.contains("bag") || lower.contains("refocus") { return "B/R" }
            if lower.contains("sick") { return "S" }
            if lower.contains("out") { return "O" }
            return nil
            
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
    
    // MARK: - New Sheet

    private func selectSheet(_ name: String) {
        selectedSheet = name
        Task { await loadSlots() }
    }

    /// The New Sheet button builds NEXT week - this week's tab already exists
    /// by the time anyone needs it, and next week is what has to be set up ahead.
    private var nextWeekSheetName: String {
        weekSheetName(weeksAhead: 1)
    }
    
    private var existingNextWeekSheet: String? {
        if let start = sunday(weeksAhead: 1), let match = weekSheetCovering(start) { return match }
        return weekSheetNames.contains(nextWeekSheetName) ? nextWeekSheetName : nil
    }

    private var newSheetDialogTitle: String {
        "Create new sheet for \(nextWeekSheetName)?"
    }

    private var newSheetConfirmButtonTitle: String {
        "Yes, create it"
    }

    /// Manual version of the auto-create that runs on launch. Switches to the
    /// week's sheet if it already exists instead of duplicating it.
    private func createNewSheetManually() async {
        await MainActor.run { isCreatingSheet = true }
        await performNewSheetCreation()
        await MainActor.run { isCreatingSheet = false }
    }

    private func performNewSheetCreation() async {
        let newSheetName = nextWeekSheetName
        guard !newSheetName.isEmpty else {
            await MainActor.run { showToast("❌ Could not determine week") }
            return
        }

        do {
            // Refresh first so a sheet someone else just made counts as existing.
            let refreshed = try await SheetsService.shared.fetchSheetNamesWithIds(forceRefresh: true)
            await MainActor.run { applySheetList(refreshed) }

            if let existing = await MainActor.run(body: { existingNextWeekSheet }) {
                await MainActor.run {
                    selectedSheet = existing
                    showToast("ℹ️ \(existing) already exists")
                }
                await loadSlots()
                return
            }

            guard let templateId = findTemplateSheetId() else {
                await MainActor.run { showToast("❌ No template sheet found") }
                return
            }

            try await SheetsService.shared.copySheet(
                sourceSheetId: templateId,
                newTitle: newSheetName,
                insertAtIndex: 1
            )

            let updated = try await SheetsService.shared.fetchSheetNamesWithIds(forceRefresh: true)
            await MainActor.run {
                applySheetList(updated)
                selectedSheet = newSheetName
                createdSheetName = newSheetName
                showSheetCreatedAlert = true
            }
            await loadSlots()
        } catch {
            await MainActor.run { showToast("❌ Failed to create sheet") }
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
            let fetched = try await SheetsService.shared.fetchSheetNamesWithIds()
            applySheetList(fetched)
            
            let (selected, needsCreation) = autoSelectSheetOrCreate()
            
            if let selected = selected {
                // Found a matching sheet for today
                selectedSheet = selected
            } else if needsCreation, let templateId = findTemplateSheetId() {
                // Try to create a new sheet, but don't fail if it doesn't work
                let newSheetName = generateNewSheetName()
                do {
                    try await SheetsService.shared.copySheet(
                        sourceSheetId: templateId,
                        newTitle: newSheetName,
                        insertAtIndex: 1
                    )
                    await MainActor.run {
                        createdSheetName = newSheetName
                        showSheetCreatedAlert = true
                    }
                    
                    // Refresh sheet list after creation
                    let refreshed = try await SheetsService.shared.fetchSheetNamesWithIds(forceRefresh: true)
                    applySheetList(refreshed)
                    selectedSheet = newSheetName
                } catch {
                    // Sheet creation failed (probably already exists) - just use first available
                    print("⚠️ Sheet creation failed: \(error.localizedDescription)")
                    selectedSheet = weekSheetNames.first ?? allSheetNames.first ?? ""
                }
            } else {
                // No auto-selection and no template - use first available
                selectedSheet = weekSheetNames.first ?? allSheetNames.first ?? ""
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
            
            // Row 1 = day names, row 2 = slot names, cadets start at row 3.
            let dayRow = headers.count > 0 ? headers[0] : []
            let slotRow = headers.count > 1 ? headers[1] : []
            
            await MainActor.run {
                allSlots = buildColumnMap(dayRow: dayRow, slotRow: slotRow)
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
    
    /// Splits the spreadsheet's tabs into date-range weeks and everything else
    /// (task/event tabs like "Football"), hiding the baseline templates.
    private func applySheetList(_ sheets: [(name: String, sheetId: Int)]) {
        sheetsWithIds = sheets
        
        let visible = sheets.map { $0.name }.filter { name in
            let upper = name.uppercased()
            return !(upper.contains("TEMPLATE") || upper.contains("BASELINE"))
        }
        
        weekSheetNames = visible.filter { isWeekSheetName($0) }
        otherSheetNames = visible.filter { !isWeekSheetName($0) }
        allSheetNames = weekSheetNames + otherSheetNames
    }
    
    private func isWeekSheetName(_ name: String) -> Bool {
        name.contains("-") && name.contains("/")
    }
    
    private func autoSelectSheetOrCreate() -> (String?, Bool) {
        let today = Date()
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: today)
        
        for sheetName in weekSheetNames {
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
    
    private enum Semester: String {
        case fall = "FALL"
        case spring = "SPRING"
    }
    
    /// Fall runs Aug 1 - Dec 9; spring runs Dec 10 - Jul 31.
    private func currentSemester(for date: Date = Date()) -> Semester {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        
        if month == 12 {
            return day >= 10 ? .spring : .fall
        }
        return month >= 8 ? .fall : .spring
    }
    
    private func findTemplateSheetId() -> Int? {
        // Baseline template tabs, e.g. "FALL '26 - BASELINE TEMPLATE DO NOT CHANGE"
        let templates = sheetsWithIds.filter { sheet in
            let name = sheet.name.uppercased()
            return name.contains("TEMPLATE") && name.contains("BASELINE")
        }
        
        let semester = currentSemester()
        
        // Prefer the template for the current semester.
        if let match = templates.first(where: { $0.name.uppercased().contains(semester.rawValue) }) {
            print("📋 Using \(semester.rawValue) template: \(match.name) (ID: \(match.sheetId))")
            return match.sheetId
        }
        
        // No semester-specific template - use any baseline template rather than failing.
        if let template = templates.first {
            print("⚠️ No \(semester.rawValue) template found; falling back to: \(template.name) (ID: \(template.sheetId))")
            return template.sheetId
        }
        
        // Fallback: use first non-date sheet
        let fallback = sheetsWithIds.first { 
            !$0.name.contains("-") && !$0.name.contains("/") 
        }
        
        if let fb = fallback {
            print("📋 Using fallback template: \(fb.name) (ID: \(fb.sheetId))")
            return fb.sheetId
        }
        
        print("❌ No template sheet found")
        return nil
    }
    
    private func generateNewSheetName() -> String {
        weekSheetName(weeksAhead: 0)
    }
    
    /// Sunday of the week `weeksAhead` from today.
    private func sunday(weeksAhead: Int) -> Date? {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        
        let daysToSubtract = weekday == 1 ? 0 : weekday - 1
        guard let thisSunday = calendar.date(byAdding: .day, value: -daysToSubtract, to: today)
        else { return nil }
        
        return calendar.date(byAdding: .day, value: 7 * weeksAhead, to: thisSunday)
    }
    
    private func weekSheetName(weeksAhead: Int) -> String {
        let calendar = Calendar.current
        guard let start = sunday(weeksAhead: weeksAhead),
              let friday = calendar.date(byAdding: .day, value: 5, to: start)
        else { return "" }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        
        return "\(formatter.string(from: start))-\(formatter.string(from: friday))"
    }
    
    /// Existing week tab whose date range contains `date`. Matched by range
    /// rather than by name because tabs aren't consistently Sunday-based
    /// (8/31-9/4 alongside 8/23-8/28), so a name comparison would miss.
    private func weekSheetCovering(_ date: Date) -> String? {
        weekSheetNames.first { name in
            guard let (start, end) = parseDateRange(name) else { return false }
            return date >= start && date <= end
        }
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
        
        // Set start to beginning of day (00:00:00)
        startComponents.hour = 0
        startComponents.minute = 0
        startComponents.second = 0
        
        // Set end to END of day (23:59:59) so today at any time still matches
        endComponents.hour = 23
        endComponents.minute = 59
        endComponents.second = 59
        
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
            
            guard !slotName.isEmpty else { continue }
            
            // Task/event tabs (Football, Spring 26 Tasks) have a blank day row -
            // the column name alone is the slot.
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
        } else if totalMinutes < 390 {
            targetSlot = "MTT"
        } else if totalMinutes < 840 {
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

// MARK: - Custom Status Picker

struct StatusPickerView: View {
    let cadet: Cadet
    let onSelect: (String) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationView {
            List {
                // Present
                Section {
                    StatusRow(
                        title: "Present",
                        code: "P",
                        color: .green,
                        onTap: { onSelect("P") }
                    )
                }
                
                // TBD (gray)
                Section(header: Text("Reset")) {
                    StatusRow(
                        title: "TBD",
                        code: nil,
                        color: Color(.systemGray4),
                        onTap: { onSelect("TBD") }
                    )
                }
                
                // UA (red)
                Section(header: Text("Unexcused")) {
                    StatusRow(
                        title: "Unexcused Absence",
                        code: "UA",
                        color: .red,
                        onTap: { onSelect("UA") }
                    )
                }
                
                // Blue excuses
                Section(header: Text("Excused (Blue)")) {
                    StatusRow(title: "E (other)", code: nil, color: .blue) { onSelect("E (other)") }
                    StatusRow(title: "E (Special Unit)", code: "U", color: .blue) { onSelect("E (Special Unit)") }
                    StatusRow(title: "E (Class)", code: "C", color: .blue) { onSelect("E (Class)") }
                    StatusRow(title: "E (Work)", code: "W", color: .blue) { onSelect("E (Work)") }
                    StatusRow(title: "E (religious)", code: "R", color: .blue) { onSelect("E (religious)") }
                    StatusRow(title: "E (Tutoring/SI)", code: "T", color: .blue) { onSelect("E (Tutoring/SI)") }
                }
                
                // Yellow excuses
                Section(header: Text("Excused (Yellow)")) {
                    StatusRow(title: "E (t-other)", code: nil, color: .yellow, textColor: .black) { onSelect("E (t-other)") }
                    StatusRow(title: "E (Event)", code: "E", color: .yellow, textColor: .black) { onSelect("E (Event)") }
                    StatusRow(title: "E (bag/refocus)", code: "B/R", color: .yellow, textColor: .black) { onSelect("E (bag/refocus)") }
                    StatusRow(title: "E (Sick)", code: "S", color: .yellow, textColor: .black) { onSelect("E (Sick)") }
                    StatusRow(title: "E (out of town)", code: "O", color: .yellow, textColor: .black) { onSelect("E (out of town)") }
                }
                
                // Purple (ROTC)
                Section(header: Text("Other")) {
                    StatusRow(title: "ROTC", code: nil, color: .purple) { onSelect("ROTC") }
                }
            }
            .navigationTitle("Mark \(cadet.lastName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}

struct StatusRow: View {
    let title: String
    let code: String?
    let color: Color
    var textColor: Color = .white
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                // Color indicator bubble
                HStack(spacing: 4) {
                    Text(code ?? "")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(textColor)
                }
                .frame(width: 36, height: 24)
                .background(color.opacity(0.8))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(color, lineWidth: 1.5)
                )
                
                Text(title)
                    .foregroundColor(.primary)
                
                Spacer()
            }
        }
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