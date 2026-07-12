import Foundation
import Capacitor
import HealthKit

/**
 * Minimal HealthKit bridge for Lift.
 * JS contract (window.Capacitor.Plugins.HealthPlugin):
 *   isHealthAvailable() -> { available: Bool }
 *   requestHealthPermissions({ permissions: [String] }) -> { granted: Bool }
 *   queryWorkouts({ startDate, endDate, includeHeartRate }) ->
 *     { workouts: [{ startDate, endDate, calories, sourceName, workoutType, heartRate: [{ bpm, at }] }] }
 */
@objc(HealthPlugin)
public class HealthPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "HealthPlugin"
    public let jsName = "HealthPlugin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isHealthAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestHealthPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "queryWorkouts", returnType: CAPPluginReturnPromise)
    ]

    private let store = HKHealthStore()
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        if let d = isoFormatter.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: s)
    }

    @objc func isHealthAvailable(_ call: CAPPluginCall) {
        call.resolve(["available": HKHealthStore.isHealthDataAvailable()])
    }

    @objc func requestHealthPermissions(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.resolve(["granted": false])
            return
        }
        var readTypes: Set<HKObjectType> = [HKObjectType.workoutType()]
        if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) { readTypes.insert(hr) }
        if let en = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { readTypes.insert(en) }
        store.requestAuthorization(toShare: nil, read: readTypes) { granted, _ in
            DispatchQueue.main.async { call.resolve(["granted": granted]) }
        }
    }

    @objc func queryWorkouts(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.resolve(["workouts": []])
            return
        }
        let start = parseDate(call.getString("startDate")) ?? Date(timeIntervalSinceNow: -3600)
        let end = parseDate(call.getString("endDate")) ?? Date()
        let includeHR = call.getBool("includeHeartRate") ?? true

        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: pred,
                                  limit: 20, sortDescriptors: [sort]) { [weak self] _, samples, _ in
            guard let self = self else { return }
            let workouts = (samples as? [HKWorkout]) ?? []
            if workouts.isEmpty {
                DispatchQueue.main.async { call.resolve(["workouts": []]) }
                return
            }
            var results: [[String: Any]] = []
            let group = DispatchGroup()
            let lock = NSLock()

            for w in workouts {
                var item: [String: Any] = [
                    "startDate": self.isoFormatter.string(from: w.startDate),
                    "endDate": self.isoFormatter.string(from: w.endDate),
                    "sourceName": w.sourceRevision.source.name,
                    "workoutType": w.workoutActivityType.rawValue
                ]
                var kcal: Double = 0
                if #available(iOS 16.0, *) {
                    if let en = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                       let stat = w.statistics(for: en), let sum = stat.sumQuantity() {
                        kcal = sum.doubleValue(for: .kilocalorie())
                    }
                }
                if kcal == 0, let burned = w.totalEnergyBurned {
                    kcal = burned.doubleValue(for: .kilocalorie())
                }
                item["calories"] = kcal

                if includeHR, let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
                    group.enter()
                    let hrPred = HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate, options: [])
                    let hrQuery = HKSampleQuery(sampleType: hrType, predicate: hrPred,
                                                limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, hrSamples, _ in
                        let unit = HKUnit.count().unitDivided(by: .minute())
                        let beats: [[String: Any]] = (hrSamples as? [HKQuantitySample])?.map {
                            ["bpm": $0.quantity.doubleValue(for: unit),
                             "at": self.isoFormatter.string(from: $0.startDate)]
                        } ?? []
                        item["heartRate"] = beats
                        lock.lock(); results.append(item); lock.unlock()
                        group.leave()
                    }
                    self.store.execute(hrQuery)
                } else {
                    item["heartRate"] = []
                    lock.lock(); results.append(item); lock.unlock()
                }
            }
            group.notify(queue: .main) {
                call.resolve(["workouts": results])
            }
        }
        store.execute(query)
    }
}
