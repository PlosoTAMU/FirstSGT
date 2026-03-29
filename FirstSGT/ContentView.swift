import SwiftUI

struct ContentView: View {
    @State private var options: [String] = []
    @State private var selected = ""
    @State private var isLoading = false
    @State private var isFetching = false
    @State private var statusMessage = ""

    let targetCell = "Sheet9!C4"       // cell to update

    var body: some View {
        VStack(spacing: 24) {
            Text("Update Sheet Cell")
                .font(.headline)

            if isFetching {
                ProgressView("Loading options...")
            } else if options.isEmpty {
                Text("No options found")
                    .foregroundColor(.secondary)
            } else {
                Picker("Select value", selection: $selected) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)

                Button(action: updateSheet) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Update \(targetCell)")
                            .bold()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || selected.isEmpty)
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .foregroundColor(statusMessage.contains("✅") ? .green : .red)
                    .font(.caption)
            }
        }
        .padding()
        .task {
            await fetchOptions()
        }
    }

    func fetchOptions() async {
        isFetching = true
        statusMessage = ""
        do {
            options = try await SheetsService.shared.fetchDropdownOptions(cell: targetCell)
            selected = options.first ?? ""
        } catch {
            statusMessage = "❌ Failed to load options: \(error.localizedDescription)"
        }
        isFetching = false
    }

    func updateSheet() {
        isLoading = true
        statusMessage = ""
        Task {
            do {
                try await SheetsService.shared.write(
                    range: targetCell,
                    values: [[selected]]
                )
                statusMessage = "✅ Updated \(targetCell) to \"\(selected)\""
            } catch {
                statusMessage = "❌ Failed: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }
}
