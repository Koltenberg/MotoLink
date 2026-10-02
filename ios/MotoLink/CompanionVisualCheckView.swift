#if targetEnvironment(simulator)
import SwiftUI

/// CI opens this only on a newly created disposable simulator. Neither this
/// entry point nor its fictional records are compiled into a device build.
struct CompanionVisualCheckView: View {
    @StateObject private var store = CompanionStore()
    @ObservedObject var rides: RideRecorder
    @State private var prepared = false
    @State private var showServiceEditor = false
    @State private var showFuelEditor = false

    var body: some View {
        NavigationStack {
            CompanionView(store: store, rides: rides)
        }
        .sheet(isPresented: $showServiceEditor) {
            ServiceEditor(store: store, task: store.data.serviceTasks.last)
        }
        .sheet(isPresented: $showFuelEditor) {
            // The real new-entry defaults: full tank, no liters or price, and
            // the fixture profile's odometer. Do not manufacture form values.
            FuelEditor(store: store, rides: rides, entry: nil)
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            if ProcessInfo.processInfo.arguments.contains("--review-service-editor") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showServiceEditor = true }
            } else if ProcessInfo.processInfo.arguments.contains("--review-fuel-editor") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showFuelEditor = true }
            }
            // Even a manually invoked simulator check must preserve existing
            // records. Normal app launch never enters this view.
            guard store.data.bikeName == "Мой мотоцикл", store.data.odometerKm == nil,
                  store.data.fuelEntries.isEmpty, store.data.serviceTasks.isEmpty else { return }
            let calendar = Calendar(identifier: .gregorian)
            let day = calendar.startOfDay(for: Date())
            let earlier = calendar.date(byAdding: .day, value: -8, to: day) ?? day
            let recent = calendar.date(byAdding: .day, value: -2, to: day) ?? day
            store.save { data in
                data.bikeName = "Мой Ninja 500"
                data.odometerKm = 12_480
                data.fuelEntries = [
                    FuelEntry(date: earlier, odometerKm: 12_100, liters: 10.24, cost: 840.50, fullTank: true),
                    FuelEntry(date: recent, odometerKm: 12_420, liters: nil, cost: nil, fullTank: true)
                ]
                data.serviceTasks = [
                    ServiceTask(title: "Проверка и смазка цепи", lastDoneAt: nil,
                                lastDoneOdometerKm: 12_000, intervalKm: 500),
                    ServiceTask(title: "Масло и фильтр", lastDoneAt: earlier,
                                lastDoneOdometerKm: 9_000, intervalKm: 4_000, intervalStartKm: 3_000, intervalMonths: 12)
                ]
            }
        }
    }
}
#endif
